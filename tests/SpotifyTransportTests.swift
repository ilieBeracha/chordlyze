import Combine
import Foundation

enum Config {
    static let spotifyClientID = "offline-client"
    static let redirectURI = "chordlyze://callback"
    static let scopes = "user-read-playback-state user-modify-playback-state"
}

/// All HTTP stays inside URLProtocol. Tokens and keychain are in-memory fixtures.
final class SpotifyHTTPStub: URLProtocol {
    struct Reply {
        var status = 200
        var body = ""
        var headers: [String: String] = [:]
        var delay: TimeInterval = 0
        var failure: Error?
    }
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> Reply)?
    private static var requests: [URLRequest] = []
    static func configure(_ handle: @escaping (URLRequest) -> Reply) {
        lock.lock(); defer { lock.unlock() }
        handler = handle; requests = []
    }
    static var captured: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let handler = Self.handler!
        Self.lock.unlock()
        let reply = handler(request)
        if reply.delay > 0 { Thread.sleep(forTimeInterval: reply.delay) }
        if let failure = reply.failure { client?.urlProtocol(self, didFailWithError: failure); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status,
            httpVersion: "HTTP/1.1", headerFields: reply.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@main struct SpotifyTransportTests {
    @MainActor static var checks = 0
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { fatalError(message) }
    }
    @MainActor static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpotifyHTTPStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var refreshes: [String] = []
        let api = SpotifyAPI(session: session, token: { "old-token" }, refreshRejectedToken: {
            refreshes.append($0); return "new-token"
        })

        SpotifyHTTPStub.configure { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer old-token"
                ? .init(status: 401, body: #"{"error":{"message":"expired"}}"#)
                : .init(status: 204)
        }
        try await api.play(trackID: "song", positionMs: 12500, deviceID: "phone with spaces")
        let retried = SpotifyHTTPStub.captured
        check(retried.count == 2 && refreshes == ["old-token"], "A rejected token is refreshed and retried once")
        check(retried.allSatisfy { $0.httpMethod == "PUT" && $0.timeoutInterval == 12 && $0.cachePolicy == .reloadIgnoringLocalCacheData },
              "Commands have bounded timeouts and bypass local cache")
        check(URLComponents(url: retried.last!.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "phone with spaces",
              "Device IDs are safely URL encoded")

        SpotifyHTTPStub.configure { _ in .init(status: 401) }
        do { try await api.play(trackID: "song", positionMs: 0); fatalError("Repeated 401 must fail") }
        catch { check((error as NSError).code == 401 && SpotifyHTTPStub.captured.count == 2, "Authentication retry is bounded") }

        SpotifyHTTPStub.configure { _ in .init(status: 403, body: #"{"error":{"reason":"RESTRICTION_VIOLATED","message":"Command disallowed"}}"#) }
        do { try await api.seek(toMs: 1000, deviceID: "phone"); fatalError("403 must fail") }
        catch {
            let error = error as NSError
            check(error.code == 403 && error.userInfo["reason"] as? String == "RESTRICTION_VIOLATED",
                  "Control errors preserve Spotify's reason")
            check(SpotifyHTTPStub.captured.count == 1, "A forbidden command is not retried")
        }

        SpotifyHTTPStub.configure { _ in .init(status: 429, headers: ["Retry-After": "31"]) }
        do { _ = try await api.devices(); fatalError("429 must fail") }
        catch { check((error as NSError).userInfo["retryAfter"] as? Double == 31, "Device discovery preserves Retry-After") }

        SpotifyHTTPStub.configure { _ in .init(failure: URLError(.timedOut)) }
        do { try await api.play(trackID: "song", positionMs: 0); fatalError("Timeout must fail") }
        catch { check(SpotifyHTTPStub.captured.count == 1, "An uncertain timed-out play command is never blindly replayed") }

        SpotifyHTTPStub.configure { _ in .init(status: 204) }
        let idle = try await api.currentlyPlaying()
        check(idle == nil && SpotifyHTTPStub.captured.first?.url?.path == "/v1/me/player", "Playback reads the full device-aware state and handles idle")
        try await api.seek(toMs: 9999, deviceID: "phone")
        let seek = URLComponents(url: SpotifyHTTPStub.captured.last!.url!, resolvingAgainstBaseURL: false)!
        check(seek.queryItems?.contains(.init(name: "position_ms", value: "9999")) == true &&
              seek.queryItems?.contains(.init(name: "device_id", value: "phone")) == true, "Seeks target the observed device explicitly")

        SpotifyHTTPStub.configure { _ in .init(body: #"{"progress_ms":10,"is_playing":true,"device":{"id":"phone","name":"Phone","type":"Smartphone","is_active":true,"is_restricted":true},"item":{"type":"episode","name":"Podcast"}}"#) }
        let episode = try await api.currentlyPlaying()
        check(episode?.item == nil && episode?.device?.isRestricted == true, "Podcast and device restrictions decode without crashing the poller")

        // Exercise the real OAuth refresh path with an in-memory keychain.
        var saved: String? = "refresh-one"
        var instant = Date()
        let auth = SpotifyAuth(session: session, now: { instant }, readRefreshToken: { saved },
                               writeRefreshToken: { saved = $0 }, deleteRefreshToken: { saved = nil })
        SpotifyHTTPStub.configure { _ in .init(body: #"{"access_token":"access-one","refresh_token":"refresh-two","expires_in":3600}"#, delay: 0.05) }
        async let first = auth.validToken()
        async let second = auth.validToken()
        let pair = try await (first, second)
        check(pair.0 == "access-one" && pair.1 == "access-one" && SpotifyHTTPStub.captured.count == 1,
              "Concurrent callers share one rotating refresh-token request")
        check(saved == "refresh-two" && auth.isAuthorized, "The rotated refresh token is saved")

        SpotifyHTTPStub.configure { _ in .init(body: #"{"access_token":"access-two","expires_in":3600}"#, delay: 0.05) }
        async let refreshA = auth.validToken(rejecting: "access-one")
        async let refreshB = auth.validToken(rejecting: "access-one")
        let next = try await (refreshA, refreshB)
        let late = try await auth.validToken(rejecting: "access-one")
        check(next.0 == "access-two" && next.1 == "access-two" && late == "access-two" && SpotifyHTTPStub.captured.count == 1,
              "Concurrent and late 401s never invalidate a newly refreshed token")

        instant = instant.addingTimeInterval(4000)
        SpotifyHTTPStub.configure { _ in .init(failure: URLError(.notConnectedToInternet)) }
        do { _ = try await auth.validToken(); fatalError("Expired access token must not escape") }
        catch { check((error as NSError).code == URLError.notConnectedToInternet.rawValue && auth.isAuthorized,
                      "Refresh failure preserves login but never returns an expired token") }

        SpotifyHTTPStub.configure { _ in .init(status: 400, body: #"{"error":"temporarily_unavailable"}"#) }
        do { _ = try await auth.validToken(); fatalError("Failed refresh must fail") }
        catch { check(auth.isAuthorized && saved != nil, "A generic token 400 does not delete the refresh token") }

        SpotifyHTTPStub.configure { _ in .init(status: 400, body: #"{"error":"invalid_grant"}"#) }
        do { _ = try await auth.validToken(); fatalError("Revoked token must fail") }
        catch { check(!auth.isAuthorized && saved == nil, "Only invalid_grant signs out a revoked refresh token") }

        saved = "refresh-again"
        let loggingOut = SpotifyAuth(session: session, readRefreshToken: { saved },
            writeRefreshToken: { saved = $0 }, deleteRefreshToken: { saved = nil })
        SpotifyHTTPStub.configure { _ in .init(body: #"{"access_token":"late","refresh_token":"late-refresh","expires_in":3600}"#, delay: 0.1) }
        let inFlight = Task { try await loggingOut.validToken() }
        for _ in 0..<100 {
            if !SpotifyHTTPStub.captured.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        loggingOut.logout()
        do { _ = try await inFlight.value; fatalError("Late refresh must fail") } catch { }
        check(!loggingOut.isAuthorized && saved == nil, "A refresh completing after logout cannot restore credentials")
        print("Spotify HTTP and authentication: \(checks)/\(checks) checks passed")
    }
}
