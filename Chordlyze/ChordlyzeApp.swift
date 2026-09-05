import SwiftUI

@main
struct ChordlyzeApp: App {
    @StateObject private var auth = SpotifyAuth()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--song-sheet-preview") {
                    SongSheetPreview()
                } else { root }
                #else
                root
                #endif
            }
            .preferredColorScheme(.dark)
            .tint(.spotifyGreen)
            .onChange(of: auth.isAuthorized) { _, authorized in
                // Signed out: nothing should keep polling, and nothing from
                // the old account should still be on screen after a re-login.
                if !authorized { SpotifyNowPlaying.shared.reset() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { SpotifyNowPlaying.shared.stop() }
                if phase == .active, auth.isAuthorized, !isPreview { SpotifyNowPlaying.shared.start(api: SpotifyAPI(auth: auth)) }
            }
        }
    }

    /// Signed out: only the login screen, no tabs. Every tab needs Spotify.
    @ViewBuilder private var root: some View {
        if auth.isAuthorized { MainTabsView().environmentObject(auth) }
        else { LoginView().environmentObject(auth) }
    }

    private var isPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--song-sheet-preview")
        #else
        false
        #endif
    }
}

extension Color {
    static let spotifyGreen = Color(red: 30 / 255, green: 215 / 255, blue: 96 / 255)
}

enum Config {
    /// Register an app at https://developer.spotify.com/dashboard and paste its Client ID.
    static let spotifyClientID = "bf522f5e658143baaeb6945b49f751e2"
    static let redirectURI = "chordlyze://callback"
    static let scopes = "playlist-read-private playlist-read-collaborative user-library-read user-top-read user-read-currently-playing user-read-playback-state user-modify-playback-state user-read-recently-played"
    /// Deployed chord-analysis backend (Fly.io). For local backend work,
    /// temporarily point this at http://127.0.0.1:8787.
    static let backendBaseURL = URL(string: "https://chordlyze-api.fly.dev")!
}
