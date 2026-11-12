import Foundation

// Trimmed from the Hermex catalog (MIT, uzairansaruzi/hermex) to the session
// operations HermesMini uses: list, fetch, create, delete.

extension APIClient {
    func sessions() async throws -> SessionsResponse {
        try await sessions(includeArchived: false, archivedLimit: nil)
    }

    func sessions(includeArchived: Bool = false, archivedLimit: Int? = nil) async throws -> SessionsResponse {
        try await send(
            endpoint: .sessions(includeArchived: includeArchived, archivedLimit: archivedLimit),
            method: "GET"
        )
    }

    func searchSessions(query: String, content: Bool = true, depth: Int = 5) async throws -> SessionSearchResponse {
        try await send(
            endpoint: .sessionsSearch(query: query, content: content, depth: depth),
            method: "GET"
        )
    }

    func session(
        id: String,
        includeMessages: Bool = true,
        messageLimit: Int? = 50,
        messageBefore: Int? = nil,
        expandRenderable: Bool = false
    ) async throws -> SessionResponse {
        try await send(
            endpoint: .session(
                id: id,
                includeMessages: includeMessages,
                messageLimit: messageLimit,
                messageBefore: messageBefore,
                expandRenderable: expandRenderable
            ),
            method: "GET"
        )
    }

    func sessionStatus(id: String) async throws -> SessionStatusResponse {
        try await send(endpoint: .sessionStatus(id: id), method: "GET")
    }

    func createSession(workspace: String?, model: String?, modelProvider: String?, profile: String?) async throws -> SessionResponse {
        try await send(
            endpoint: .newSession,
            method: "POST",
            body: NewSessionRequest(
                workspace: workspace,
                model: model,
                modelProvider: modelProvider,
                profile: profile
            )
        )
    }

    func deleteSession(id: String) async throws -> SessionMutationResponse {
        try await send(
            endpoint: .deleteSession,
            method: "POST",
            body: SessionIDRequest(sessionId: id)
        )
    }
}

private struct NewSessionRequest: Encodable {
    let workspace: String?
    let model: String?
    let modelProvider: String?
    let profile: String?
}

struct SessionIDRequest: Encodable {
    let sessionId: String
}
