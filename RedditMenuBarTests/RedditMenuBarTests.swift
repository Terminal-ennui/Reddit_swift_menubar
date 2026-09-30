import XCTest
@testable import RedditMenuBar

final class RedditMenuBarTests: XCTestCase {
    func testOAuthRejectsWrongStateAndCallback() throws {
        XCTAssertEqual(try OAuth.code(from: URL(string: "redditmenubar://oauth/callback?state=good&code=abc")!, expectedState: "good"), "abc")
        for string in ["redditmenubar://oauth/callback?state=bad&code=abc", "redditmenubar://other/callback?state=good&code=abc", "redditmenubar://oauth/callback?state=good&error=access_denied", "redditmenubar://oauth/callback?state=good&state=bad&code=abc"] {
            XCTAssertThrowsError(try OAuth.code(from: URL(string: string)!, expectedState: "good"))
        }
    }
    func testBaselineDeduplicationAndAccountIsolation() throws {
        let first = InboxItem(id: "t4_one", subject: "reply", body: "hello", url: RedditLinks.home)
        let second = InboxItem(id: "t4_two", subject: "reply", body: "hello", url: RedditLinks.home)
        var alice = Account(id: "a", username: "alice")
        var bob = Account(id: "b", username: "bob")
        XCTAssertTrue(AlertTracker.ingest([first], account: &alice).isEmpty)
        XCTAssertEqual(AlertTracker.ingest([first, second], account: &alice), [second])
        alice = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(alice))
        XCTAssertTrue(AlertTracker.ingest([first, second], account: &alice).isEmpty)
        XCTAssertTrue(AlertTracker.ingest([second], account: &bob).isEmpty)
        XCTAssertEqual(AlertTracker.ingest([first, second], account: &bob), [first])
    }
    func testSafeSafariURLs() {
        XCTAssertEqual(RedditLinks.subreddit("swift").absoluteString, "https://www.reddit.com/r/swift")
        XCTAssertEqual(RedditLinks.inbox("/r/swift/comments/abc").host, "www.reddit.com")
        XCTAssertEqual(RedditLinks.inbox("https://evil.example/test").path, "/message/inbox")
        XCTAssertEqual(RedditLinks.popular.absoluteString, "https://www.reddit.com/r/popular/")
    }
    func testPaginationAndTokenRefresh() async throws {
        let id = "test-" + UUID().uuidString
        defer { Keychain.remove(id) }
        try Keychain.write(Tokens(access: "expired", refresh: "refresh", expires: .distantPast), account: id)
        StubProtocol.handler = { request in
            if request.url!.path == "/api/v1/access_token" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("client:".utf8).base64EncodedString())
                return (200, [:], #"{"access_token":"fresh","expires_in":3600}"#)
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
            let second = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.contains { $0.name == "after" && $0.value == "page2" }
            return (200, [:], second ? #"{"data":{"after":null,"children":[{"data":{"display_name":"apple"}}]}}"# : #"{"data":{"after":"page2","children":[{"data":{"display_name":"swift"}}]}}"#)
        }
        let client = LiveRedditClient(clientID: "client", session: session())
        let subs = try await client.subscriptions(accountID: id)
        XCTAssertEqual(subs, ["apple", "swift"])
        XCTAssertEqual(try Keychain.read(id).refresh, "refresh")
        XCTAssertEqual(try Keychain.read(id).access, "fresh")
    }
    func testRateLimit() async throws {
        let id = "test-" + UUID().uuidString
        defer { Keychain.remove(id) }
        try Keychain.write(Tokens(access: "valid", refresh: "refresh", expires: Date().addingTimeInterval(3600)), account: id)
        StubProtocol.handler = { _ in (429, ["Retry-After": "120"], "{}") }
        do { _ = try await LiveRedditClient(clientID: "client", session: session()).unread(accountID: id); XCTFail("Expected rate limit") }
        catch RedditError.rateLimited(let delay) { XCTAssertEqual(delay, 120) }
    }
    func testInboxDoesNotMarkReadAndRevokedRefreshRequiresReconnect() async throws {
        let id = "test-" + UUID().uuidString
        defer { Keychain.remove(id) }
        try Keychain.write(Tokens(access: "valid", refresh: "refresh", expires: Date().addingTimeInterval(3600)), account: id)
        StubProtocol.handler = { request in
            XCTAssertTrue(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.contains { $0.name == "mark" && $0.value == "false" })
            return (200, [:], #"{"data":{"after":null,"children":[{"data":{"name":"t4_one","subject":"reply","body":"hello","context":"/r/swift/comments/abc"}}]}}"#)
        }
        let items = try await LiveRedditClient(clientID: "client", session: session()).unread(accountID: id)
        XCTAssertEqual(items.first?.id, "t4_one")
        try Keychain.write(Tokens(access: "expired", refresh: "revoked", expires: .distantPast), account: id)
        StubProtocol.handler = { _ in (400, [:], #"{"error":"invalid_grant"}"#) }
        do { _ = try await LiveRedditClient(clientID: "client", session: session()).unread(accountID: id); XCTFail("Expected reconnect") }
        catch RedditError.reconnect { }
    }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }
}

final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, [String: String], String))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, headers, body) = Self.handler(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
