import Foundation

// Subset of the Hermex endpoint catalog (MIT, uzairansaruzi/hermex), trimmed to
// the chat-first surface used by HermesMini: auth, sessions, chat streaming,
// approvals, clarifications, models and profiles.

enum Endpoint {
    case health
    case authStatus
    case login
    case logout
    case sessions(includeArchived: Bool = false, archivedLimit: Int? = nil)
    case sessionsSearch(query: String, content: Bool, depth: Int)
    case session(id: String, includeMessages: Bool, messageLimit: Int?, messageBefore: Int?, expandRenderable: Bool = false)
    case sessionStatus(id: String)
    case newSession
    case renameSession
    case deleteSession
    case pinSession
    case archiveSession
    case branchSession
    case chatStart
    case chatStream(streamID: String)
    case chatCancel(streamID: String)
    case chatStreamStatus(streamID: String)
    case chatSteer
    case approvalPending(sessionID: String)
    case approvalStream(sessionID: String)
    case approvalRespond
    case clarifyPending(sessionID: String)
    case clarifyStream(sessionID: String)
    case clarifyRespond
    case models
    case profiles
    case upload

    var path: String {
        switch self {
        case .health:
            return "/health"
        case .authStatus:
            return "/api/auth/status"
        case .login:
            return "/api/auth/login"
        case .logout:
            return "/api/auth/logout"
        case .sessions:
            return "/api/sessions"
        case .sessionsSearch:
            return "/api/sessions/search"
        case .session:
            return "/api/session"
        case .sessionStatus:
            return "/api/session/status"
        case .newSession:
            return "/api/session/new"
        case .renameSession:
            return "/api/session/rename"
        case .deleteSession:
            return "/api/session/delete"
        case .pinSession:
            return "/api/session/pin"
        case .archiveSession:
            return "/api/session/archive"
        case .branchSession:
            return "/api/session/branch"
        case .chatStart:
            return "/api/chat/start"
        case .chatStream:
            return "/api/chat/stream"
        case .chatCancel:
            return "/api/chat/cancel"
        case .chatStreamStatus:
            return "/api/chat/stream/status"
        case .chatSteer:
            return "/api/chat/steer"
        case .approvalPending:
            return "/api/approval/pending"
        case .approvalStream:
            return "/api/approval/stream"
        case .approvalRespond:
            return "/api/approval/respond"
        case .clarifyPending:
            return "/api/clarify/pending"
        case .clarifyStream:
            return "/api/clarify/stream"
        case .clarifyRespond:
            return "/api/clarify/respond"
        case .models:
            return "/api/models"
        case .profiles:
            return "/api/profiles"
        case .upload:
            return "/api/upload"
        }
    }

    var queryItems: [URLQueryItem] {
        switch self {
        case let .sessions(includeArchived, archivedLimit):
            guard includeArchived else { return [] }
            var items = [URLQueryItem(name: "include_archived", value: "1")]
            if let archivedLimit {
                items.append(URLQueryItem(name: "archived_limit", value: "\(archivedLimit)"))
            }
            return items
        case let .sessionsSearch(query, content, depth):
            return [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "content", value: content ? "1" : "0"),
                URLQueryItem(name: "depth", value: "\(depth)")
            ]
        case let .session(id, includeMessages, messageLimit, messageBefore, expandRenderable):
            var items = [
                URLQueryItem(name: "session_id", value: id),
                URLQueryItem(name: "messages", value: includeMessages ? "1" : "0")
            ]
            if let messageLimit {
                items.append(URLQueryItem(name: "msg_limit", value: "\(messageLimit)"))
            }
            if let messageBefore {
                items.append(URLQueryItem(name: "msg_before", value: "\(messageBefore)"))
            }
            if expandRenderable {
                items.append(URLQueryItem(name: "expand_renderable", value: "1"))
            }
            return items
        case let .sessionStatus(id):
            return [URLQueryItem(name: "session_id", value: id)]
        case let .chatStream(streamID),
            let .chatCancel(streamID),
            let .chatStreamStatus(streamID):
            return [URLQueryItem(name: "stream_id", value: streamID)]
        case let .approvalPending(sessionID),
            let .approvalStream(sessionID),
            let .clarifyPending(sessionID),
            let .clarifyStream(sessionID):
            return [URLQueryItem(name: "session_id", value: sessionID)]
        default:
            return []
        }
    }

    var url: URL {
        url(relativeTo: nil)
    }

    func url(relativeTo baseURL: URL?) -> URL {
        var components = URLComponents()
        components.scheme = baseURL?.scheme ?? "https"
        components.host = baseURL?.host
        components.port = baseURL?.port
        components.path = path
        let items = queryItems
        if !items.isEmpty {
            components.queryItems = items
        }
        guard let url = components.url else {
            fatalError("Invalid endpoint URL for \(self)")
        }
        return url
    }
}
