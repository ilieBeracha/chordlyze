import AuthenticationServices
import CryptoKit
import Foundation

/// Spotify OAuth 2.0 with PKCE — no client secret needed on device.
@MainActor
final class SpotifyAuth: NSObject, ObservableObject {
    /// True while a refresh token is on hand: the signed-in screens show at
    /// once on launch and the access token is refreshed behind them. Only a
    /// logout, or Spotify rejecting the refresh token, drops it.
    @Published private(set) var isAuthorized = false
    @Published var lastError: String?
    /// Bumped on every successful token grant, so screens can restart work a
    /// dead token had stopped (the now-playing poller after a reconnect).
    @Published private(set) var grants = 0

    private var accessToken: String?
    private var refreshToken: String?
    private var expiresAt: Date = .distantPast
    private var codeVerifier = ""
    /// One refresh in flight at a time: Spotify rotates PKCE refresh tokens,
    /// so two concurrent refreshes with the same token fail the second.
    private var refreshTask: Task<Void, Never>?
    private var tokenError: Error?
    private var sessionGeneration = 0
    private let session: URLSession
    private let now: () -> Date
    private let writeRefreshToken: (String) -> Void
    private let deleteRefreshToken: () -> Void

    init(session: URLSession = .shared, now: @escaping () -> Date = Date.init,
         readRefreshToken: () -> String? = { Keychain.read("spotify_refresh_token") },
         writeRefreshToken: @escaping (String) -> Void = { Keychain.write("spotify_refresh_token", value: $0) },
         deleteRefreshToken: @escaping () -> Void = { Keychain.delete("spotify_refresh_token") }) {
        self.session = session
        self.now = now
        self.writeRefreshToken = writeRefreshToken
        self.deleteRefreshToken = deleteRefreshToken
        super.init()
        refreshToken = readRefreshToken()
        isAuthorized = refreshToken != nil
    }

    func login() {
        sessionGeneration += 1
        refreshTask?.cancel(); refreshTask = nil
        let generation = sessionGeneration
        codeVerifier = Self.randomVerifier()
        let challenge = Self.codeChallenge(for: codeVerifier)
        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            .init(name: "client_id", value: Config.spotifyClientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Config.redirectURI),
            .init(name: "scope", value: Config.scopes),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
        ]
        let session = ASWebAuthenticationSession(url: comps.url!, callbackURLScheme: "chordlyze") { [weak self] url, error in
            guard let self else { return }
            if let error { Task { @MainActor in self.lastError = error.localizedDescription }; return }
            guard let url,
                  let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                      .queryItems?.first(where: { $0.name == "code" })?.value else {
                Task { @MainActor in self.lastError = "No authorization code returned" }
                return
            }
            Task { @MainActor in
                guard self.sessionGeneration == generation else { return }
                await self.exchange(code: code)
            }
        }
        session.presentationContextProvider = self
        session.start()
    }

    /// Forgets all tokens; the app returns to the login screen.
    func logout() {
        sessionGeneration += 1
        refreshTask?.cancel(); refreshTask = nil
        accessToken = nil
        refreshToken = nil
        tokenError = nil
        expiresAt = .distantPast
        deleteRefreshToken()
        isAuthorized = false
    }

    /// A live access token, refreshed first when the current one is (nearly)
    /// expired. Throws when there is nothing to refresh with.
    func validToken(rejecting rejected: String? = nil) async throws -> String {
        // Concurrent 401s for an old token share one refresh. A late 401 must
        // not discard the new token another request already obtained.
        if let rejected, accessToken == rejected {
            accessToken = nil
            expiresAt = .distantPast
        }
        if let accessToken, now() < expiresAt { return accessToken }
        await refresh()
        try Task.checkCancellation()
        guard let accessToken, now() < expiresAt else {
            if let tokenError { throw tokenError }
            throw NSError(domain: "SpotifyAPI", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Reconnect Spotify in Profile."])
        }
        return accessToken
    }

    private func exchange(code: String) async {
        await tokenRequest(body: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Config.redirectURI,
            "client_id": Config.spotifyClientID,
            "code_verifier": codeVerifier,
        ], isRefresh: false)
    }

    private func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        guard let refreshToken else { return }
        let generation = sessionGeneration
        let task = Task {
            await self.tokenRequest(body: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": Config.spotifyClientID,
            ], isRefresh: true)
        }
        refreshTask = task
        await task.value
        if sessionGeneration == generation { refreshTask = nil }
    }

    private func tokenRequest(body: [String: String], isRefresh: Bool) async {
        let generation = sessionGeneration
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.timeoutInterval = 12
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = body
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        do {
            let (data, response) = try await session.data(for: req)
            guard generation == sessionGeneration, !Task.isCancelled else { return }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let detail = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if isRefresh, http.statusCode == 400, detail?["error"] as? String == "invalid_grant" {
                    // invalid_grant: the refresh token was revoked or already
                    // rotated away. Nothing to retry with — sign out.
                    logout()
                    lastError = "Spotify signed this device out — connect again."
                    return
                }
                lastError = "Spotify could not refresh the connection (\(http.statusCode)). Try again."
                tokenError = NSError(domain: "SpotifyToken", code: http.statusCode,
                                     userInfo: [NSLocalizedDescriptionKey: lastError!])
                return
            }
            let token = try JSONDecoder().decode(TokenResponse.self, from: data)
            accessToken = token.accessToken
            if let r = token.refreshToken {
                refreshToken = r
                writeRefreshToken(r)
            }
            expiresAt = now().addingTimeInterval(TimeInterval(token.expiresIn - 60))
            isAuthorized = true
            lastError = nil
            tokenError = nil
            grants += 1
        } catch {
            guard generation == sessionGeneration, !Task.isCancelled else { return }
            tokenError = error
            lastError = "Token exchange failed: \(error.localizedDescription)"
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }
}

extension SpotifyAuth: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // ASWebAuthenticationSession calls this on the main thread.
        MainActor.assumeIsolated { ASPresentationAnchor() }
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
