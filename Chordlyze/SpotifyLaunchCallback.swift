import Foundation

/// Keep callback routing testable without UIKit or a real Spotify account.
enum SpotifyLaunchCallback {
    enum Result: Equatable { case success, failure(String) }

    static func matches(_ url: URL, redirectURI: String) -> Bool {
        guard let expected = URL(string: redirectURI) else { return false }
        return url.scheme == expected.scheme && url.host == expected.host &&
            url.path == expected.path && url.port == expected.port &&
            url.user == nil && url.password == nil
    }

    static func result(accessToken: String?, error: String?) -> Result? {
        if error != nil {
            return .failure("Spotify didn’t authorize playback. Open Spotify again and allow Chordlyze to connect.")
        }
        guard let accessToken, !accessToken.isEmpty else { return nil }
        return .success
    }
}
