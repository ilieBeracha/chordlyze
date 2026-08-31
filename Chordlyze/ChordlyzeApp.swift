import SwiftUI

@main
struct ChordlyzeApp: App {
    @StateObject private var auth = SpotifyAuth()

    var body: some Scene {
        WindowGroup {
            Group {
                if auth.isAuthorized {
                    PlaylistsView().environmentObject(auth)
                } else {
                    LoginView().environmentObject(auth)
                }
            }
            .preferredColorScheme(.dark)
            .tint(.spotifyGreen)
        }
    }
}

extension Color {
    static let spotifyGreen = Color(red: 30 / 255, green: 215 / 255, blue: 96 / 255)
}

enum Config {
    /// Register an app at https://developer.spotify.com/dashboard and paste its Client ID.
    static let spotifyClientID = "bf522f5e658143baaeb6945b49f751e2"
    static let redirectURI = "chordlyze://callback"
    static let scopes = "playlist-read-private playlist-read-collaborative user-library-read user-top-read"
    /// Deployed chord-analysis backend (Fly.io). For local backend work,
    /// temporarily point this at http://127.0.0.1:8787.
    static let backendBaseURL = URL(string: "https://chordlyze-api.fly.dev")!
}
