import SwiftUI
import MarkdownUI
import UniformTypeIdentifiers

struct ChatView: View {
    @StateObject private var store = AppStore.shared
    @State private var draft = ""
    @State private var isDropTargeted = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messageList
            if let error = store.errorMessage {
                ErrorBanner(text: error)
            }
            if let approval = store.pendingApproval {
                ApprovalCard(approval: approval)
            }
            if let clarification = store.pendingClarification {
                ClarificationCard(clarification: clarification)
            }
            attachmentStrip
            composer
        }
        .background(dropOverlay)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .onAppear {
            focusComposer()
        }
        .onChange(of: store.selectedSessionID) { _ in
            // Session switch: put the cursor in the composer right away.
            focusComposer()
        }
        .onChange(of: store.panelVisible) { visible in
            if visible {
                focusComposer()
            }
        }
    }

    /// Move focus into the composer after the next layout pass (the panel may
    /// just have been ordered front, or the session content re-rendered).
    private func focusComposer() {
        DispatchQueue.main.async {
            composerFocused = true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            // Sidebar collapse + new-chat live in the chat header so they stay
            // reachable even when the sidebar is collapsed.
            Button {
                store.toggleSidebar()
            } label: {
                Image(systemName: store.sidebarVisible ? "sidebar.left" : "sidebar.right")
            }
            .buttonStyle(.plain)
            .help("Skrýt / zobrazit session list")

            if let title = store.sessions.first(where: { $0.id == store.selectedSessionID })?.title,
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(title.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.headline)
                    .lineLimit(1)
            } else {
                Text(store.selectedSessionID == nil ? "Nová session" : "Hermes")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            if store.isStreaming {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            Button {
                Task { await store.newSessionAndSelect() }
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.plain)
            .help("Nová session")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // textSelection applied ONCE at the transcript level (not per
                // bubble): per-bubble .textSelection(.enabled) combined with
                // flexible frames spirals into an infinite SwiftUI layout loop
                // on macOS (TextKit measurement vs SwiftUI layout oscillation).
                LazyVStack(spacing: 12) {
                    if store.canLoadOlder {
                        Button {
                            Task { await store.loadOlderMessages() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.up")
                                Text("Načíst starší")
                            }
                            .font(.callout)
                            .foregroundStyle(.tint)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .help("Načíst starší zprávy")
                    }
                    if store.messages.isEmpty {
                        Text("Zeptej se agenta na cokoli…")
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    }
                    ForEach(store.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(12)
            }
            .textSelection(.enabled)
            .onChange(of: store.messages.count) { _ in
                if let last = store.messages.last {
                    // No animation here: an animated scrollTo keeps re-laying
                    // out the transcript, which combined with textSelection
                    // can spiral into an infinite layout loop (100% CPU).
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: store.messages.last?.content) { _ in
                if let last = store.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: store.sidebarVisible) { _ in
                // Sidebar collapse re-layouts the scroll view and can drop the
                // position; nudge back to the bottom after the layout pass.
                DispatchQueue.main.async {
                    if let last = store.messages.last {
                        withAnimation(nil) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Composer

    private var composer: some View {
        // Buttons anchored to the bottom edge (original behaviour), nudged up
        // by 8pt so they sit level with the text baseline inside the box
        // instead of hugging the composer's bottom edge.
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                openFilePicker()
            } label: {
                Image(systemName: "paperclip")
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)
            .help("Přidat přílohu (nebo drag & drop)")

            TextField("Zpráva…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($composerFocused)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                .onSubmit {
                    send()
                }

            if store.isStreaming {
                Button {
                    store.cancelStream()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
                .help("Zastavit")
            } else {
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && store.attachments.isEmpty)
                .help("Odeslat")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var attachmentStrip: some View {
        Group {
            if !store.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(store.attachments) { attachment in
                            AttachmentChip(attachment: attachment) {
                                store.removeAttachment(attachment.id)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                }
            }
        }
    }

    private var dropOverlay: some View {
        Group {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(8)
                    .overlay(
                        Text("Přetáhni sem soubory")
                            .font(.headline)
                            .foregroundStyle(.tint)
                    )
            }
        }
    }

    // MARK: - Actions

    private func send() {
        let text = draft
        draft = ""
        Task {
            await store.send(text)
        }
    }

    private func openFilePicker() {
        // Accessory (LSUIElement) apps have no Dock presence; without explicit
        // activation the NSOpenPanel never appears. Activate, then show.
        hmLog("openFilePicker: activating app")
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.begin { response in
            hmLog("openFilePicker: response=\(response.rawValue)")
            guard response == .OK else { return }
            for url in panel.urls {
                Task { await store.addAttachment(from: url) }
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) ?? (item as? URL)
                    else { return }
                    Task { @MainActor in
                        await store.addAttachment(from: url)
                    }
                }
            }
        }
        return handled
    }
}

struct AttachmentChip: View {
    let attachment: PendingAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: attachment.isImage ? "photo" : "doc")
            Text(attachment.name)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

struct ErrorBanner: View {
    let text: String

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text)
                .font(.callout)
                .lineLimit(3)
            Spacer()
        }
        .foregroundStyle(.red)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.1)))
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }
}

struct MessageBubble: View {
    @StateObject private var store = AppStore.shared
    let message: DisplayMessage

    private var messageFont: Font {
        .system(size: CGFloat(store.fontSize))
    }

    var body: some View {
        HStack(alignment: .top) {
            if message.role == "user" {
                Spacer(minLength: 48)
            }
            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 3) {
                if message.role == "user" {
                    Text(message.content)
                        .font(messageFont)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.18)))
                } else {
                    Markdown(message.content)
                        .markdownTextStyle(\.text) {
                            // .font() from outside is ignored by MarkdownUI —
                            // the text style must carry the size explicitly.
                            FontSize(CGFloat(store.fontSize))
                        }
                        .markdownTextStyle(\.code) {
                            FontFamilyVariant(.monospaced)
                            FontSize(.em(0.92))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if message.isStreaming {
                        HStack(spacing: 2) {
                            Text("▍")
                                .foregroundStyle(.secondary)
                            Text("píšu…")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            if message.role != "user" {
                Spacer(minLength: 48)
            }
        }
    }
}
