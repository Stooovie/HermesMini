import Foundation
import SwiftUI

/// A chat bubble as displayed in the UI. Separate from the wire `ChatMessage`
/// model because streamed tokens mutate content incrementally.
struct DisplayMessage: Identifiable, Equatable {
    let id = UUID()
    var role: String
    var content: String
    var isStreaming: Bool = false
    var isError: Bool = false

    init(role: String, content: String, isStreaming: Bool = false, isError: Bool = false) {
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
        self.isError = isError
    }

    init(chatMessage: ChatMessage) {
        role = chatMessage.role ?? "assistant"
        content = chatMessage.content ?? ""
        if content.isEmpty, role == "tool" {
            content = "🛠 tool"
        }
    }
}

/// Central application state: server connection, sessions, chat streaming,
/// approvals and clarifications. Menu-bar app, so a single shared instance.
@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()

    enum AuthState: Equatable {
        case loggedOut
        case connecting
        case connected
    }

    // MARK: - Published state

    @Published var serverURLString: String
    @Published var authState: AuthState = .loggedOut
    @Published var sessions: [SessionSummary] = []
    @Published var selectedSessionID: String?
    @Published var messages: [DisplayMessage] = []
    @Published var isStreaming = false
    @Published var canLoadOlder = false
    @Published var pendingApproval: PendingApproval?
    @Published var pendingClarification: PendingClarification?
    @Published var errorMessage: String?
    @Published var attachments: [PendingAttachment] = []
    @Published var sidebarVisible: Bool
    @Published var fontSize: Double
    /// Mirrors the panel's on-screen state (set by AppDelegate) so ChatView can
    /// grab focus in the composer when the panel is summoned.
    @Published var panelVisible: Bool = false
    /// Messages queued because steer was unavailable — sent sequentially after
    /// the current turn finishes. Never cancels the running response (server
    /// contract). Ported from Hermex's queuedSlashMessages.
    private var queuedMessages: [QueuedMessage] = []
    private var isDrainingQueuedMessage = false

    /// One queued message awaiting the end of the active turn.
    struct QueuedMessage {
        let text: String
    }

    // MARK: - Private

    private var api: APIClient?
    private let sseClient = SSEClient()
    private var streamID: String?
    private var activeAssistantMessageID: UUID?
    /// Streamed tokens are buffered and flushed every 50ms. Rendering the
    /// markdown transcript on EVERY token makes the UI freeze on long answers
    /// (MarkdownUI re-parses the whole message per change); a 20Hz flush cap
    /// keeps streaming smooth.
    private var pendingTokenText = ""
    private var tokenFlushScheduled = false

    var serverURL: URL? { URL(string: serverURLString) }

    private init() {
        serverURLString = UserDefaults.standard.string(forKey: "ServerURL") ?? "https://hermes.example.com"
        sidebarVisible = UserDefaults.standard.object(forKey: "SidebarVisible") as? Bool ?? true
        fontSize = UserDefaults.standard.object(forKey: "FontSize") as? Double ?? 15.0
    }

    func setFontSize(_ size: Double) {
        fontSize = size
        UserDefaults.standard.set(size, forKey: "FontSize")
        hmLog("FontSize set to \(size)")
    }

    func toggleSidebar() {
        sidebarVisible.toggle()
        UserDefaults.standard.set(sidebarVisible, forKey: "SidebarVisible")
    }

    // MARK: - Auth

    func restoreSession() async {
        hmLog("restoreSession: url=\(serverURLString) hasURL=\(URL(string: serverURLString) != nil)")
        guard !serverURLString.isEmpty, URL(string: serverURLString) != nil else {
            hmLog("restoreSession: bad URL, staying logged out")
            return
        }
        guard let password = CredentialStore.load("Password") else {
            hmLog("restoreSession: no stored password, staying logged out")
            return
        }
        hmLog("restoreSession: found password, connecting")
        await connect(urlString: serverURLString, password: password)
    }

    func connect(urlString: String, password: String) async {
        hmLog("connect: url=\(urlString)")
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = "Neplatná adresa serveru."
            hmLog("connect: invalid URL")
            return
        }
        authState = .connecting
        let client = APIClient(baseURL: url)
        do {
            _ = try await client.login(password: password)
            api = client
            CredentialStore.save(password, key: "Password")
            UserDefaults.standard.set(urlString.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "ServerURL")
            serverURLString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            authState = .connected
            errorMessage = nil
            hmLog("connect: login OK")
            await loadSessions()
        } catch {
            authState = .loggedOut
            errorMessage = "Připojení selhalo: \(error.localizedDescription)"
            hmLog("connect: FAILED \(error.localizedDescription)")
        }
    }

    func logout() {
        api = nil
        authState = .loggedOut
        sessions = []
        messages = []
        messagesOffset = nil
        canLoadOlder = false
        attachments = []
        selectedSessionID = nil
        pendingApproval = nil
        pendingClarification = nil
        queuedMessages.removeAll()
        isDrainingQueuedMessage = false
        sseClient.stop()
        streamID = nil
        isStreaming = false
        CredentialStore.delete("Password")
    }

    // MARK: - Sessions

    func loadSessions() async {
        guard let api else { return }
        do {
            let resp: SessionsResponse = try await api.sessions()
            sessions = resp.sessions ?? []
        } catch {
            errorMessage = "Načtení session selhalo: \(error.localizedDescription)"
        }
    }

    private var selectionGeneration = 0
    /// Server-side transcript offset for "load older" paging
    /// (msg_before index of the next window).
    private var messagesOffset: Int?

    func selectSession(_ id: String?) async {
        guard let api, let id else {
            selectedSessionID = nil
            messages = []
            messagesOffset = nil
            canLoadOlder = false
            return
        }
        // Bump the generation so stale loads (rapid ⌥↑/⌥↓ switching) can't
        // overwrite the current session's messages after the fact.
        selectionGeneration += 1
        let gen = selectionGeneration
        if isStreaming { detachFromActiveStream() }
        queuedMessages.removeAll()
        isDrainingQueuedMessage = false
        selectedSessionID = id
        let start = Date()
        do {
            let resp: SessionResponse = try await api.session(
                id: id, includeMessages: true, messageLimit: 50, messageBefore: nil
            )
            hmLog("selectSession: load took \(String(format: "%.1f", Date().timeIntervalSince(start)))s (\((resp.session?.messages ?? []).count) msgs)")
            guard gen == selectionGeneration else {
                hmLog("selectSession: stale load dropped")
                return
            }
            messages = (resp.session?.messages ?? [])
                .filter { message in
                    // Only conversational roles belong in the transcript —
                    // tool outputs, thinking rows and system rows are noise.
                    let role = message.role ?? "assistant"
                    return role != "tool" && role != "thinking" && role != "system"
                }
                .map(DisplayMessage.init(chatMessage:))
            messagesOffset = resp.session?.messagesOffset
            canLoadOlder = (messagesOffset ?? 0) > 0
            // If the agent is still working in this session, attach to the
            // live stream — the server replays the journal so far and the
            // response continues streaming in.
            if let active = resp.session?.activeStreamId, !active.isEmpty {
                hmLog("selectSession: run still active, attaching to stream \(active)")
                startStream(streamID: active, sessionID: id)
            }
            pendingApproval = nil
            pendingClarification = nil
        } catch {
            errorMessage = "Načtení session selhalo: \(error.localizedDescription)"
        }
    }

    func createNewSession() async -> String? {
        guard let api else { return nil }
        do {
            let resp: SessionResponse = try await api.createSession(workspace: nil, model: nil, modelProvider: nil, profile: nil)
            let id = resp.session?.id ?? resp.session?.sessionId
            if let id {
                selectedSessionID = id
                messages = []
                await loadSessions()
                return id
            }
        } catch {
            errorMessage = "Vytvoření session selhalo: \(error.localizedDescription)"
        }
        return nil
    }

    func newSessionAndSelect() async {
        _ = await createNewSession()
    }

    /// Move the selection by `offset` sessions (⌥↑ / ⌥↓), wrapping around the
    /// list ends.
    func selectSessionRelative(_ offset: Int) {
        guard !sessions.isEmpty else { return }
        let currentIndex = sessions.firstIndex { $0.id == selectedSessionID }
        let nextIndex: Int
        if let currentIndex {
            nextIndex = (currentIndex + offset + sessions.count) % sessions.count
        } else {
            nextIndex = offset > 0 ? 0 : sessions.count - 1
        }
        let target = sessions[nextIndex].id
        guard target != selectedSessionID else { return }
        hmLog("selectSessionRelative: \(offset) -> \(target)")
        Task { await selectSession(target) }
    }

    /// Load the next older window of messages (before the current offset) and
    /// prepend it to the transcript.
    func loadOlderMessages() async {
        guard let api, let sessionID = selectedSessionID,
              let offset = messagesOffset, offset > 0 else { return }
        selectionGeneration += 1
        let gen = selectionGeneration
        do {
            let resp: SessionResponse = try await api.session(
                id: sessionID, includeMessages: true, messageLimit: 50, messageBefore: offset
            )
            guard gen == selectionGeneration else {
                hmLog("loadOlder: stale dropped")
                return
            }
            let older = (resp.session?.messages ?? [])
                .filter { message in
                    let role = message.role ?? "assistant"
                    return role != "tool" && role != "thinking" && role != "system"
                }
                .map(DisplayMessage.init(chatMessage:))
            guard !older.isEmpty else {
                canLoadOlder = false
                return
            }
            messages.insert(contentsOf: older, at: 0)
            messagesOffset = resp.session?.messagesOffset
            canLoadOlder = (messagesOffset ?? 0) > 0
            hmLog("loadOlder: prepended \(older.count), new offset \(String(describing: messagesOffset))")
        } catch {
            errorMessage = "Načtení starších zpráv selhalo: \(error.localizedDescription)"
        }
    }

    func deleteSession(_ id: String) async {
        guard let api else { return }
        do {
            let _: EmptyDeleteResponse = try await api.send(
                endpoint: .deleteSession, method: "POST",
                body: SessionIDRequest(sessionId: id)
            )
            if selectedSessionID == id {
                // Deleting the session that is actively streaming must stop the
                // run — it no longer has a place to write into.
                if isStreaming { cancelStream() }
                selectedSessionID = nil
                messages = []
            }
            await loadSessions()
        } catch {
            errorMessage = "Smazání selhalo: \(error.localizedDescription)"
        }
    }

    // MARK: - Chat

    func send(_ draft: String) async {
        guard let api,
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
        else { return }

        let text = PendingAttachment.chatMessageText(draft: draft, attachments: attachments)
        let payloadAttachments: [JSONValue]? = attachments.isEmpty
            ? nil
            : attachments.map { $0.toJSONValue() }
        attachments = []

        let sessionID: String
        if let sid = selectedSessionID {
            sessionID = sid
        } else if let created = await createNewSession() {
            sessionID = created
        } else {
            return
        }

        if isStreaming {
            // A message sent while a response is streaming steers the running
            // agent instead of starting a second turn in parallel.
            do {
                let resp: ChatSteerResponse = try await api.steerChat(sessionID: sessionID, text: text)
                if resp.accepted == true {
                    hmLog("send: steered in-flight run")
                    messages.append(DisplayMessage(role: "user", content: text))
                    return
                }
                hmLog("send: steer not accepted (\(resp.fallback ?? "no fallback info"))")
            } catch {
                hmLog("send: steer failed \(error.localizedDescription)")
            }
            // Steer unavailable: queue the message and let the running response
            // finish — cancelling it here would kill the active answer.
            queuedMessages.append(QueuedMessage(text: text))
            messages.append(DisplayMessage(role: "user", content: text))
            hmLog("send: queued message until current turn finishes (queue=\(queuedMessages.count))")
            return
        }

        messages.append(DisplayMessage(role: "user", content: text))

        do {
            let resp: ChatStartResponse = try await api.startChat(
                sessionID: sessionID,
                message: text,
                workspace: nil,
                model: nil,
                modelProvider: nil,
                profile: nil,
                explicitModelPick: false,
                attachments: payloadAttachments
            )
            if let error = resp.error, !error.isEmpty {
                errorMessage = error
                return
            }
            guard let streamID = resp.streamId else {
                errorMessage = "Server nevrátil stream ID."
                return
            }
            startStream(streamID: streamID, sessionID: sessionID)
        } catch {
            // The server already has a run for this session (HTTP 409 with
            // active_stream_id): attach to it instead of cancelling — the
            // running response continues and streams into this chat. Ported
            // from Hermex's performChatSend reconcile branch.
            if let apiError = error as? APIError, let activeStreamID = apiError.activeStreamID {
                hmLog("send: server already running run \(activeStreamID), attaching")
                startStream(streamID: activeStreamID, sessionID: sessionID)
                return
            }
            errorMessage = "Odeslání selhalo: \(error.localizedDescription)"
        }
    }

    /// Detach the SSE listener WITHOUT cancelling the server-side run — the
    /// agent keeps working in the background. Reattaching happens in
    /// selectSession (activeStreamId) or send() (HTTP 409 reconcile).
    private func detachFromActiveStream() {
        hmLog("detach: leaving run running on server (background)")
        sseClient.stop()
        streamID = nil
        isStreaming = false
        tokenFlushScheduled = false
        flushPendingTokens()
        activeAssistantMessageID = nil
        for idx in messages.indices {
            messages[idx].isStreaming = false
        }
    }

    func cancelStream() {
        guard let api, let streamID else { return }
        Task {
            _ = try? await api.cancelChat(streamID: streamID)
        }
        sseClient.stop()
        self.streamID = nil
        isStreaming = false
        tokenFlushScheduled = false
        flushPendingTokens()
        for idx in messages.indices {
            messages[idx].isStreaming = false
        }
        activeAssistantMessageID = nil
    }

    private func startStream(streamID: String, sessionID: String) {
        guard let api else { return }
        self.streamID = streamID
        isStreaming = true
        errorMessage = nil
        hmLog("startStream: streamID=\(streamID)")
        sseClient.start(url: api.chatStreamURL(streamID: streamID)) { [weak self] event in
            self?.handleStreamEvent(event, sessionID: sessionID)
        }
    }

    private func handleStreamEvent(_ event: SSEEvent, sessionID: String) {
        switch event {
        case .token(let text):
            appendToAssistant(text)
        case .interimAssistant(let payload):
            if payload.alreadyStreamed != true, let text = payload.text, !text.isEmpty {
                appendToAssistant(text)
            }
        // Reasoning and tool-call activity are deliberately dropped from the UI:
        // the user wants only the final answer, no thinking or tool noise.
        case .reasoning, .toolStarted, .toolCompleted:
            break
        case .title:
            Task { await self.loadSessions() }
        case .approvalPending(let resp):
            pendingApproval = resp.pending
        case .clarificationPending(let resp):
            pendingClarification = resp.pending
        case .done:
            finishStream()
        case .streamEnd, .cancelled:
            finishStream()
        case .error(let message), .transportError(let message):
            errorMessage = message
            finishStream()
        case .heartbeat, .ignored, .metering, .pendingSteerLeftover:
            break
        }
    }

    private func appendToAssistant(_ text: String) {
        pendingTokenText += text
        scheduleTokenFlush()
    }

    /// Coalesce streamed tokens into ~20Hz UI updates instead of re-rendering
    /// the whole transcript on every token.
    private func scheduleTokenFlush() {
        guard !tokenFlushScheduled else { return }
        tokenFlushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            self?.tokenFlushScheduled = false
            self?.flushPendingTokens()
        }
    }

    private func flushPendingTokens() {
        let text = pendingTokenText
        pendingTokenText = ""
        guard !text.isEmpty else { return }
        if let id = activeAssistantMessageID, let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].content += text
        } else {
            let msg = DisplayMessage(role: "assistant", content: text, isStreaming: true)
            activeAssistantMessageID = msg.id
            messages.append(msg)
        }
    }

    private func finishStream() {
        hmLog("finishStream: stopping SSE")
        flushPendingTokens()
        sseClient.stop()
        streamID = nil
        isStreaming = false
        tokenFlushScheduled = false
        for idx in messages.indices {
            messages[idx].isStreaming = false
        }
        activeAssistantMessageID = nil
        let queued = !queuedMessages.isEmpty
        Task { await self.loadSessions() }
        // Send queued messages now that the turn finished (sequential drain).
        if queued {
            hmLog("finishStream: draining queued messages")
            drainQueuedMessageIfIdle()
        }
    }

    /// Sequential queue drain — one message at a time after a turn finishes.
    /// Ported from Hermex's drainQueuedSlashMessageIfIdle.
    private func drainQueuedMessageIfIdle() {
        guard !isStreaming, !isDrainingQueuedMessage, !queuedMessages.isEmpty else { return }
        let next = queuedMessages.removeFirst()
        isDrainingQueuedMessage = true
        hmLog("drain: sending queued message (\(queuedMessages.count) left)")
        Task { @MainActor in
            await send(next.text)
            isDrainingQueuedMessage = false
            drainQueuedMessageIfIdle()
        }
    }

    // MARK: - Approvals & clarifications

    func respondApproval(_ choice: ApprovalChoice) async {
        guard let api, let sessionID = selectedSessionID else { return }
        let approvalID = pendingApproval?.approvalId
        do {
            let _: ApprovalRespondResponse = try await api.send(
                endpoint: .approvalRespond, method: "POST",
                body: ApprovalRespondRequest(sessionId: sessionID, choice: choice, approvalId: approvalID)
            )
            pendingApproval = nil
        } catch {
            errorMessage = "Odpověď na schválení selhala: \(error.localizedDescription)"
        }
    }

    func respondClarification(_ text: String) async {
        guard let api, let sessionID = selectedSessionID else { return }
        let clarifyID = pendingClarification?.clarifyId
        do {
            let _: ClarificationRespondResponse = try await api.send(
                endpoint: .clarifyRespond, method: "POST",
                body: ClarificationRespondRequest(sessionId: sessionID, response: text, clarifyId: clarifyID)
            )
            pendingClarification = nil
        } catch {
            errorMessage = "Odpověď na otázku selhala: \(error.localizedDescription)"
        }
    }

    // MARK: - Attachments (drag & drop)

    func addAttachment(from url: URL) async {
        guard let api else { return }
        let sessionID: String
        if let sid = selectedSessionID {
            sessionID = sid
        } else if let created = await createNewSession() {
            sessionID = created
        } else {
            return
        }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= PendingAttachment.maximumUploadBytes else {
                errorMessage = PendingAttachment.uploadTooLargeMessage(filename: url.lastPathComponent)
                return
            }
            let resp: UploadResponse = try await api.uploadFile(
                sessionID: sessionID, data: data, filename: url.lastPathComponent
            )
            if let error = resp.error, !error.isEmpty {
                errorMessage = error
                return
            }
            let attachment = PendingAttachment(
                name: resp.filename ?? url.lastPathComponent,
                path: resp.path ?? "",
                mime: resp.mime ?? "application/octet-stream",
                size: resp.size ?? data.count,
                isImage: resp.isImage ?? false,
                thumbnailData: nil
            )
            attachments.append(attachment)
        } catch {
            errorMessage = "Nahrání přílohy selhalo: \(error.localizedDescription)"
        }
    }

    func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }
}

/// Response type for session mutations that return an empty/ack body.
struct EmptyDeleteResponse: Decodable {
    let ok: Bool?
}
