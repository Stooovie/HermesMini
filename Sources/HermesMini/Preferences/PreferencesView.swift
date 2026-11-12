import SwiftUI
import Carbon
import ServiceManagement

// MARK: - Launch at login (LaunchAgent)

enum LaunchAgentManager {
    static let label = "dev.hermesmini.client"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) {
        if enabled {
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [Bundle.main.executableURL?.path ?? ""],
                "RunAtLoad": true,
            ]
            do {
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: plistURL)
                // Activate immediately; bootout happens automatically on next login
                // if the plist is removed. Errors are fine (already loaded).
                _ = runProcess("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
                hmLog("LaunchAgent enabled at \(plistURL.path)")
            } catch {
                hmLog("LaunchAgent write failed: \(error.localizedDescription)")
            }
        } else {
            _ = runProcess("/bin/launchctl", ["bootout", "gui/\(getuid())", plistURL.path])
            try? FileManager.default.removeItem(at: plistURL)
            hmLog("LaunchAgent disabled")
        }
    }

    private static func runProcess(_ path: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}

// MARK: - Hotkey recording

/// Captures a key combination and reports keyCode + Carbon modifier bitmask.
struct HotKeyRecorder: View {
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    var onRecorded: () -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: startRecording) {
            Text(isRecording ? "Zmáčkni kombinaci…" : hotKeyDisplayName(code: keyCode, mods: modifiers))
                .frame(minWidth: 140)
        }
        .buttonStyle(.bordered)
        .disabled(isRecording)
        .onDisappear {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Esc cancels recording
            if event.keyCode == 53 {
                finishRecording(cancelled: true)
                return nil
            }
            var mods = 0
            if event.modifierFlags.contains(.command) { mods |= Int(cmdKey) }
            if event.modifierFlags.contains(.option) { mods |= Int(optionKey) }
            if event.modifierFlags.contains(.shift) { mods |= Int(shiftKey) }
            if event.modifierFlags.contains(.control) { mods |= Int(controlKey) }
            // Require at least one modifier so the panel can't be bound to a
            // plain letter key that would block normal typing.
            guard mods != 0 else { return nil }
            keyCode = Int(event.keyCode)
            modifiers = mods
            finishRecording(cancelled: false)
            onRecorded()
            return nil
        }
    }

    private func finishRecording(cancelled: Bool) {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
        _ = cancelled
    }
}

// MARK: - Display helpers

func hotKeyDisplayName(code: Int, mods: Int) -> String {
    var parts: [String] = []
    if mods & Int(cmdKey) != 0 { parts.append("⌘") }
    if mods & Int(optionKey) != 0 { parts.append("⌥") }
    if mods & Int(shiftKey) != 0 { parts.append("⇧") }
    if mods & Int(controlKey) != 0 { parts.append("⌃") }
    parts.append(keyName(for: code))
    return parts.joined()
}

private func keyName(for code: Int) -> String {
    let map: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space",
        50: "`", 51: "Delete", 53: "Esc", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
    return map[code] ?? "Key\(code)"
}

// MARK: - Preferences view

struct PreferencesView: View {
    @State private var launchAtLogin = LaunchAgentManager.isEnabled
    @State private var hotKeyCode = UserDefaults.standard.object(forKey: "HotKeyCode") as? Int ?? Int(kVK_Space)
    @State private var hotKeyMods = UserDefaults.standard.object(forKey: "HotKeyModifiers") as? Int ?? Int(optionKey)
    @State private var fontSize = UserDefaults.standard.object(forKey: "FontSize") as? Double ?? 15.0

    var body: some View {
        Form {
            Section("Spuštění") {
                Toggle("Spouštět při přihlášení", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        LaunchAgentManager.setEnabled(newValue)
                    }
            }

            Section("Klávesová zkratka") {
                HStack {
                    Text("Vyvolat / skrýt panel")
                    Spacer()
                    HotKeyRecorder(
                        keyCode: $hotKeyCode,
                        modifiers: $hotKeyMods,
                        onRecorded: saveHotKey
                    )
                }
                Button("Obnovit výchozí (⌥Space)") {
                    hotKeyCode = Int(kVK_Space)
                    hotKeyMods = Int(optionKey)
                    saveHotKey()
                }
            }

            Section("Vzhled") {
                HStack {
                    Text("Velikost textu")
                    Spacer()
                    Text("\(fontSize, specifier: "%.1f") pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $fontSize, in: 12...24, step: 0.5)
                    .onChange(of: fontSize) { newValue in
                        AppStore.shared.setFontSize(newValue)
                    }
                Button("Obnovit výchozí (15 pt)") {
                    fontSize = 15.0
                    AppStore.shared.setFontSize(15.0)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding(20)
        .onAppear {
            hmLog("Preferences opened")
        }
    }

    private func saveHotKey() {
        UserDefaults.standard.set(hotKeyCode, forKey: "HotKeyCode")
        UserDefaults.standard.set(hotKeyMods, forKey: "HotKeyModifiers")
        hmLog("HotKey saved code=\(hotKeyCode) mods=\(hotKeyMods)")
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            appDelegate.reloadHotKey()
        }
    }
}
