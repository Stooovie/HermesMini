import SwiftUI

struct MainView: View {
    @StateObject private var store = AppStore.shared

    var body: some View {
        HStack(spacing: 0) {
            if store.sidebarVisible {
                SessionSidebar()
                    .frame(width: 180)
                Divider()
            }
            ChatView()
        }
        // NOTE: no .animation() here — animating the sidebar width re-layouts
        // the chat ScrollView and SwiftUI drops the scroll position, jumping
        // the transcript to the top. Instant layout + restore (in ChatView)
        // is deterministic.
    }
}

struct SessionSidebar: View {
    @StateObject private var store = AppStore.shared

    private var selectedID: Binding<String?> {
        Binding(
            get: { store.selectedSessionID },
            set: { newValue in
                // SwiftUI List can emit a spurious nil selection while the data
                // refreshes after deleting ANOTHER session. Keep the current
                // selection as long as the session still exists — only a real
                // click or deletion of the selected session may change it.
                // Otherwise selectSession() would cancel the running stream and
                // kill the in-flight answer.
                if newValue == nil,
                   let current = store.selectedSessionID,
                   store.sessions.contains(where: { $0.id == current }) {
                    hmLog("selectSession: ignored spurious nil (selected session still exists)")
                    return
                }
                guard newValue != store.selectedSessionID else { return }
                hmLog("selectSession: change to \(newValue ?? "nil")")
                Task { await store.selectSession(newValue) }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Session")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            List(selection: selectedID) {
                ForEach(store.sessions) { session in
                    SessionRow(session: session)
                        .tag(session.id)
                        .contextMenu {
                            Button("Smazat", role: .destructive) {
                                Task { await store.deleteSession(session.id) }
                            }
                        }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack {
                Text(store.serverURL?.host ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    store.logout()
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                }
                .buttonStyle(.plain)
                .help("Odhlásit")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}

struct SessionRow: View {
    let session: SessionSummary

    private var dateText: String {
        let ts = session.updatedAt ?? session.lastMessageAt ?? session.createdAt ?? 0
        guard ts > 0 else { return "" }
        let date = Date(timeIntervalSince1970: ts)
        return date.formatted(.relative(presentation: .named))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                 ? session.title!.trimmingCharacters(in: .whitespacesAndNewlines)
                 : "Nová session")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if !dateText.isEmpty {
                Text(dateText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
