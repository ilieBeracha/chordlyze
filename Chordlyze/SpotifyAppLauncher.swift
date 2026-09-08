import SpotifyiOS
import UIKit

/// The Web API cannot wake a suspended iOS app. Use Spotify's supported
/// authorization-and-play handoff, then let the existing Web API controller
/// verify the account's device/song/position. SDK tokens never replace PKCE
/// credentials, and opening the app alone is never treated as authorization.
@MainActor
final class SpotifyAppLauncher {
    static let shared = SpotifyAppLauncher()
    private let remote = SPTAppRemote(configuration: SPTConfiguration(
        clientID: Config.spotifyClientID, redirectURL: URL(string: Config.redirectURI)!), logLevel: .none)
    private var pending: (id: UUID, authorized: (String?) -> Void)?

    @discardableResult
    func open(trackID: String, opened: @escaping (Bool) -> Void,
              authorized: @escaping (String?) -> Void) -> UUID {
        let id = UUID()
        pending = (id, authorized)
        remote.authorizeAndPlayURI("spotify:track:\(trackID)") { [weak self] installed in
            Task { @MainActor in
                guard self?.pending?.id == id else { return }
                if !installed { self?.pending = nil }
                opened(installed)
            }
        }
        return id
    }

    func handle(_ url: URL) {
        guard let pending,
              SpotifyLaunchCallback.matches(url, redirectURI: Config.redirectURI),
              let parameters = remote.authorizationParameters(from: url) else { return }
        let result = SpotifyLaunchCallback.result(
            accessToken: parameters[SPTAppRemoteAccessTokenKey],
            error: parameters[SPTAppRemoteErrorDescriptionKey])
        guard let result else { return } // e.g. a PKCE code callback
        self.pending = nil
        switch result {
        case .success: pending.authorized(nil)
        case .failure(let message): pending.authorized(message)
        }
    }

    func cancel(_ id: UUID) {
        if pending?.id == id { pending = nil }
    }
    func reset() { pending = nil }
}
