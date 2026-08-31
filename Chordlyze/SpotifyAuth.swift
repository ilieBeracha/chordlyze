import AuthenticationServices
import CryptoKit
import Foundation

/// Spotify OAuth 2.0 with PKCE — no client secret needed on device.
@MainActor
final class SpotifyAuth: NSObject, ObservableObject {
    @Published var isAuthorized = false
    @Published var lastError: String?

    private(set) var accessToken: String? {
        didSet { isAuthorized = accessToken != nil }
    }
    private var refreshToken: String?
    private var expiresAt: Date = .distantPast
    private var codeVerifier = ""

    override init() {
        super.init()
        if let stored = Keychain.read("spotify_refresh_token") {
            refreshToken = stored
            Task { try? await refresh() }
        }
    }

    func login() {
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
            Task { await self.exchange(code: code) }
        }
        session.presentationContextProvider = self
        session.start()
    }

    /// Forgets all tokens; the app returns to the login screen.
    func logout() {
        accessToken = nil
        refreshToken = nil
        expiresAt = .distantPast
        Keychain.delete("spotify_refresh_token")
    }

    func validToken() async throws -> String {
        if let token = accessToken, Date() < expiresAt { return token }
        if refreshToken != nil { try await refresh() }
        guard let token = accessToken else { throw URLError(.userAuthenticationRequired) }
        return token
    }

    private func exchange(code: String) async {
        await tokenRequest(body: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Config.redirectURI,
            "client_id": Config.spotifyClientID,
            "code_verifier": codeVerifier,
        ])
    }

    private func refresh() async throws {
        guard let refreshToken else { throw URLError(.userAuthenticationRequired) }
        await tokenRequest(body: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Config.spotifyClientID,
        ])
    }

    private func tokenRequest(body: [String: String]) async {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = body
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                lastError = "Spotify token endpoint \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")"
                return
            }
            let token = try JSONDecoder().decode(TokenResponse.self, from: data)
            accessToken = token.accessToken
            #if targetEnvironment(simulator)
            // Debug only: expose token for host-side API diagnosis. Remove before release.
            let debugURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("debug_token.txt")
            try? token.accessToken.write(to: debugURL, atomically: true, encoding: .utf8)
            #endif
            if let r = token.refreshToken {
                refreshToken = r
                Keychain.write("spotify_refresh_token", value: r)
            }
            expiresAt = Date().addingTimeInterval(TimeInterval(token.expiresIn - 60))
            lastError = nil
        } catch {
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
