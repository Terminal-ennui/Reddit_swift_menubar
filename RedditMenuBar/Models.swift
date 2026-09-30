import Foundation

struct Account: Codable, Identifiable, Equatable {
    var id: String
    var username: String
    var notifications = true
    var subreddits: [String] = []
    var seen: Set<String> = []
    var baselined = false
}

struct Tokens: Codable {
    var access: String
    var refresh: String
    var expires: Date
}

struct InboxItem: Equatable {
    var id: String
    var subject: String
    var body: String
    var url: URL
}

enum RedditError: Error, LocalizedError {
    case reconnect, rateLimited(TimeInterval), server(Int), invalidCallback, invalidResponse
    var errorDescription: String? {
        switch self {
        case .reconnect: return "Reconnect this account in Settings."
        case .rateLimited: return "Reddit rate limit reached; retrying later."
        case .server(let code): return "Reddit returned HTTP \(code)."
        case .invalidCallback: return "The sign-in callback could not be verified."
        case .invalidResponse: return "Reddit returned an unexpected response."
        }
    }
}

enum RedditLinks {
    static let home = URL(string: "https://www.reddit.com/")!
    static let popular = URL(string: "https://www.reddit.com/r/popular/")!
    static func subreddit(_ name: String) -> URL {
        home.appendingPathComponent("r").appendingPathComponent(name)
    }
    static func inbox(_ context: String?) -> URL {
        guard let context, let url = URL(string: context, relativeTo: home)?.absoluteURL,
              url.scheme == "https", url.host == "www.reddit.com" || url.host == "reddit.com" else {
            return home.appendingPathComponent("message/inbox")
        }
        return url
    }
}

enum OAuth {
    static let redirect = "redditmenubar://oauth/callback"
    static func authorization(clientID: String, state: String) -> URL {
        var parts = URLComponents(string: "https://www.reddit.com/api/v1/authorize")!
        parts.queryItems = ["client_id": clientID, "response_type": "code", "state": state,
                           "redirect_uri": redirect, "duration": "permanent",
                           "scope": "identity mysubreddits privatemessages"].map { URLQueryItem(name: $0.key, value: $0.value) }
        return parts.url!
    }
    static func code(from url: URL, expectedState: String) throws -> String {
        guard url.scheme == "redditmenubar", url.host == "oauth", url.path == "/callback",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == expectedState,
              !items.contains(where: { $0.name == "error" }),
              items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw RedditError.invalidCallback
        }
        return code
    }
}

enum AlertTracker {
    static func ingest(_ items: [InboxItem], account: inout Account) -> [InboxItem] {
        var fresh: [InboxItem] = []
        for item in items {
            if account.seen.insert(item.id).inserted && account.baselined { fresh.append(item) }
        }
        account.baselined = true
        return fresh
    }
}

protocol RedditClient: Sendable {
    func identity(accountID: String) async throws -> Account
    func subscriptions(accountID: String) async throws -> [String]
    func unread(accountID: String) async throws -> [InboxItem]
}
