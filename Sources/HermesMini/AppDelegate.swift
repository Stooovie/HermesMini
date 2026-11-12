import AppKit
import Carbon
import SwiftUI

/// Application delegate for the menu-bar Hermes Mini client.
///
/// Owns the floating panel, the global hotkey (default ⌥Space), the menu-bar
/// status item and the Escape-to-dismiss behaviour. The app runs as a pure
/// accessory (LSUIElement): no Dock icon, no regular window — the panel is
/// summoned with the hotkey and dismissed with Escape.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panel: NSPanel?
    private var statusItem: NSStatusItem?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var escapeMonitor: Any?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        hmLog("didFinishLaunching")
        NSApp.setActivationPolicy(.accessory)
        setupPanel()
        setupMenuBar()
        registerHotKey()
        installEscapeMonitor()
        installMainThreadWatchdog()
        Task { @MainActor in
            await AppStore.shared.restoreSession()
        }
    }

    /// Heartbeat watchdog. The main-thread timer detects transient blocks;
    /// the background thread detects a FULL deadlock (the main timer would be
    /// frozen too and could never log). Both write to /tmp/hermesmini.log.
    private var lastHeartbeat = Date()
    private let heartbeatLock = NSLock()
    private var heartbeatTimer: Timer?
    private var watchdogThread: Thread?

    private func installMainThreadWatchdog() {
        lastHeartbeat = Date()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Date()
            self.heartbeatLock.lock()
            let gap = now.timeIntervalSince(self.lastHeartbeat)
            self.lastHeartbeat = now
            self.heartbeatLock.unlock()
            if gap > 2.0 {
                hmLog("⚠️ main thread was blocked for \(String(format: "%.1f", gap))s")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer

        // Background heartbeat — survives a full main-thread deadlock and
        // keeps reporting so the frozen window is measurable.
        let thread = Thread { [weak self] in
            while !Thread.current.isCancelled {
                Thread.sleep(forTimeInterval: 2.0)
                guard let self else { return }
                self.heartbeatLock.lock()
                let gap = Date().timeIntervalSince(self.lastHeartbeat)
                self.heartbeatLock.unlock()
                if gap > 2.0 {
                    hmLog("⚠️⚠️ MAIN THREAD DEADLOCKED for \(String(format: "%.1f", gap))s (background watchdog)")
                }
            }
        }
        thread.name = "HermesMini-watchdog"
        thread.start()
        watchdogThread = thread
    }

    func applicationWillTerminate(_ notification: Notification) {
        persistFrame()
    }

    // MARK: - Panel

    private func setupPanel() {
        let width: CGFloat = 580
        let height: CGFloat = 780
        let rect: NSRect
        if let saved = UserDefaults.standard.string(forKey: "PanelFrame") {
            rect = NSRectFromString(saved)
        } else if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            rect = NSRect(x: vf.maxX - width - 24, y: vf.maxY - height - 24, width: width, height: height)
        } else {
            rect = NSRect(x: 100, y: 100, width: width, height: height)
        }

        let panel = NSPanel(
            contentRect: rect,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.minSize = NSSize(width: 440, height: 520)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: RootView())
        panel.setFrame(rect, display: true)
        self.panel = panel
    }

    @objc func togglePanel() {
        hmLog("togglePanel")
        guard let panel else { return }
        if panel.isVisible {
            persistFrame()
            panel.orderOut(nil)
            setPanelVisible(false)
        } else {
            if let screen = NSScreen.main, !screen.visibleFrame.intersects(panel.frame) {
                let vf = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: vf.maxX - panel.frame.width - 24, y: vf.maxY - panel.frame.height - 24))
            }
            panel.makeKeyAndOrderFront(nil)
            setPanelVisible(true)
        }
    }

    @objc func showPanel() {
        guard let panel, !panel.isVisible else { return }
        panel.makeKeyAndOrderFront(nil)
        setPanelVisible(true)
    }

    private func setPanelVisible(_ visible: Bool) {
        Task { @MainActor in
            AppStore.shared.panelVisible = visible
        }
    }

    private func persistFrame() {
        guard let panel else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: "PanelFrame")
    }

    // MARK: - NSWindowDelegate — persist the frame on live resize/move so the
    // window size is remembered between launches even if the app is killed.

    func windowDidResize(_ notification: Notification) {
        persistFrame()
    }

    func windowDidMove(_ notification: Notification) {
        persistFrame()
    }

    // MARK: - Escape to dismiss

    private func installEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            // Esc = dismiss
            if event.keyCode == 53, panel.isVisible, panel.isKeyWindow {
                self.persistFrame()
                panel.orderOut(nil)
                return nil
            }
            // ⌘N = new session
            if event.modifierFlags.contains(.command), event.keyCode == 45 { // N
                Task { @MainActor in
                    await AppStore.shared.newSessionAndSelect()
                }
                return nil
            }
            // ⌥↑ / ⌥↓ = switch session (only while the panel is the key window)
            if panel.isVisible, panel.isKeyWindow, event.modifierFlags.contains(.option) {
                if event.keyCode == 126 { // up arrow
                    Task { @MainActor in AppStore.shared.selectSessionRelative(-1) }
                    return nil
                }
                if event.keyCode == 125 { // down arrow
                    Task { @MainActor in AppStore.shared.selectSessionRelative(1) }
                    return nil
                }
            }
            return event
        }
    }

    // MARK: - Menu bar

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right.fill", accessibilityDescription: "Hermes Mini")
        }
        let menu = NSMenu()

        let toggle = NSMenuItem(title: "Show / Hide Hermes", action: #selector(togglePanel), keyEquivalent: " ")
        toggle.keyEquivalentModifierMask = [.option]
        menu.addItem(toggle)

        let newSession = NSMenuItem(title: "New Session", action: #selector(newSessionAction), keyEquivalent: "n")
        menu.addItem(newSession)

        let prefs = NSMenuItem(title: "Preferences…", action: #selector(openPreferencesAction), keyEquivalent: ",")
        menu.addItem(prefs)

        let openBrowser = NSMenuItem(title: "Open in Browser", action: #selector(openInBrowserAction), keyEquivalent: "")
        menu.addItem(openBrowser)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Hermes Mini", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func newSessionAction() {
        Task { @MainActor in
            await AppStore.shared.newSessionAndSelect()
            showPanel()
        }
    }

    private var prefsWindow: NSWindow?

    @objc private func openPreferencesAction() {
        hmLog("openPreferencesAction")
        if prefsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Hermes Mini – Preferences"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: PreferencesView())
            prefsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        prefsWindow?.center()
        prefsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openInBrowserAction() {
        Task { @MainActor in
            if let url = AppStore.shared.serverURL {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Global hotkey (Carbon)

    /// Re-registers the hotkey with the current UserDefaults values. Called at
    /// launch and after a Preferences change.
    func reloadHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        registerHotKey()
    }

    private func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let handler: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            delegate.togglePanel()
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, selfPtr, &eventHandlerRef)

        // Configurable via: defaults write dev.hermesmini.client HotKeyCode -int 49
        // HotKeyModifiers is a Carbon modifier bitmask (optionKey = 0x0800).
        let code = UserDefaults.standard.object(forKey: "HotKeyCode") as? Int ?? Int(kVK_Space)
        let mods = UserDefaults.standard.object(forKey: "HotKeyModifiers") as? Int ?? Int(optionKey)
        let hotKeyID = EventHotKeyID(signature: OSType(0x484D_4E49), id: 1)
        let status = RegisterEventHotKey(UInt32(code), UInt32(mods), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        hmLog("hotkey registered code=\(code) mods=\(mods) status=\(status)")
        if status != noErr {
            NSLog("HermesMini: hotkey registration failed with status \(status)")
        }
    }
}
