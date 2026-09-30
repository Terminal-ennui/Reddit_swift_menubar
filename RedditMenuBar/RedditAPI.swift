import Foundation

actor LiveRedditClient: RedditClient {
    let clientID: String
    let session: URLSession
    private var refreshing: [String: Task<Tokens, Error>] = [:]
    init(clientID: String, session: URLSession = .shared) { self.clientID = clientID; self.session = session }

    private struct TokenResponse: Decodable {
        var access_token: String
        var refresh_token: String?
        var expires_in: Double
    }
    private func tokenRequest(_ fields: [String: String], refresh: String = "") async throws -> Tokens {
        var request = URLRequest(url: URL(string: "https://www.reddit.com/api/v1/access_token")!)
        request.httpMethod = "POST"
        request.setValue("Basic " + Data((clientID + ":").utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var parts = URLComponents()
        parts.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let data = try await perform(request)
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)
        return Tokens(access: response.access_token, refresh: response.refresh_token ?? refresh,
                      expires: Date().addingTimeInterval(response.expires_in))
    }
    func authorize(code: String, accountID: String) async throws {
        let tokens = try await tokenRequest(["grant_type": "authorization_code", "code": code, "redirect_uri": OAuth.redirect])
        guard !tokens.refresh.isEmpty else { throw RedditError.invalidResponse }
        try Keychain.write(tokens, account: accountID)
    }
    private func access(_ accountID: String, force: Bool = false) async throws -> String {
        if let task = refreshing[accountID] { return try await task.value.access }
        let tokens = try Keychain.read(accountID)
        if !force && tokens.expires > Date().addingTimeInterval(60) { return tokens.access }
        let task = Task { try await self.tokenRequest(["grant_type": "refresh_token", "refresh_token": tokens.refresh], refresh: tokens.refresh) }
        refreshing[accountID] = task
        defer { refreshing[accountID] = nil }
        let renewed = try await task.value
        try Keychain.write(renewed, account: accountID)
        return renewed.access
    }
    private func perform(_ input: URLRequest) async throws -> Data {
        var request = input
        request.timeoutInterval = 30
        request.setValue("macos:com.personal.RedditMenuBar:v1.0 (personal menu bar app)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RedditError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw RedditError.reconnect
        case 400:
            if request.url?.path == "/api/v1/access_token",
               let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               body["error"] as? String == "invalid_grant" { throw RedditError.reconnect }
            throw RedditError.server(400)
        case 429:
            let delay = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? Double(http.value(forHTTPHeaderField: "x-ratelimit-reset") ?? "") ?? 60
            throw RedditError.rateLimited(max(60, delay))
        default: throw RedditError.server(http.statusCode)
        }
    }
    private func get(_ path: String, accountID: String, after: String? = nil) async throws -> Data {
        var parts = URLComponents(string: "https://oauth.reddit.com" + path)!
        parts.queryItems = [URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "raw_json", value: "1")]
        if path.hasPrefix("/message/") { parts.queryItems?.append(URLQueryItem(name: "mark", value: "false")) }
        if let after { parts.queryItems?.append(URLQueryItem(name: "after", value: after)) }
        var request = URLRequest(url: parts.url!)
        request.setValue("Bearer " + (try await access(accountID)), forHTTPHeaderField: "Authorization")
        do { return try await perform(request) }
        catch RedditError.reconnect {
            request.setValue("Bearer " + (try await access(accountID, force: true)), forHTTPHeaderField: "Authorization")
            return try await perform(request)
        }
    }
    func identity(accountID: String) async throws -> Account {
        struct Identity: Decodable { var name: String }
        let me = try JSONDecoder().decode(Identity.self, from: await get("/api/v1/me", accountID: accountID))
        return Account(id: accountID, username: me.name)
    }
    private struct Listing<T: Decodable>: Decodable {
        struct Body: Decodable { var after: String?; var children: [Child] }
        struct Child: Decodable { var data: T }
        var data: Body
    }
    private func listing<T: Decodable>(_ type: T.Type, path: String, accountID: String) async throws -> [T] {
        var result: [T] = [], after: String?, visited: Set<String> = []
        repeat {
            let page = try JSONDecoder().decode(Listing<T>.self, from: await get(path, accountID: accountID, after: after))
            result += page.data.children.map(\.data)
            after = page.data.after
            if let after, !visited.insert(after).inserted { throw RedditError.invalidResponse }
        } while after != nil
        return result
    }
    func subscriptions(accountID: String) async throws -> [String] {
        struct Sub: Decodable { var display_name: String }
        return try await Array(Set(listing(Sub.self, path: "/subreddits/mine/subscriber", accountID: accountID).map(\.display_name))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
    func unread(accountID: String) async throws -> [InboxItem] {
        struct Message: Decodable { var name: String; var subject: String; var body: String; var context: String? }
        return try await listing(Message.self, path: "/message/unread", accountID: accountID).map {
            InboxItem(id: $0.name, subject: $0.subject, body: $0.body, url: RedditLinks.inbox($0.context))
        }
    }
}

actor MockRedditClient: RedditClient {
    private var items: [String: [InboxItem]] = [:]
    func identity(accountID: String) async throws -> Account { Account(id: accountID, username: accountID) }
    func subscriptions(accountID: String) async throws -> [String] {
        accountID == "mock-alice" ? ["apple", "macOS", "swift"] : ["books", "space", "technology"]
    }
    func unread(accountID: String) async throws -> [InboxItem] { items[accountID] ?? [] }
    func simulate(accountID: String) {
        items[accountID, default: []].append(InboxItem(id: UUID().uuidString, subject: "Mock comment reply", body: "This is a simulated Reddit notification.", url: RedditLinks.subreddit("swift")))
    }
}
