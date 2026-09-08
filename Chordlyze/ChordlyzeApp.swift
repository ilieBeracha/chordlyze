import SwiftUI

@main
struct ChordlyzeApp: App {
    @StateObject private var auth = SpotifyAuth()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Remove downloaded mixes left by the retired instrument-isolation feature.
        if let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: cache.appendingPathComponent("Isolation", isDirectory: true))
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--chord-recognition-preview") {
                    NavigationStack { LiveChordRecognitionView() }
                } else if ProcessInfo.processInfo.arguments.contains("--saved-take-preview") {
                    SavedTakePreview()
                } else if ProcessInfo.processInfo.arguments.contains("--practice-report-preview") {
                    PracticeReportPreview()
                } else if ProcessInfo.processInfo.arguments.contains("--music-preview") {
                    MusicPreview().environmentObject(auth)
                } else if ProcessInfo.processInfo.arguments.contains("--song-sheet-preview") {
                    SongSheetPreview()
                } else { root }
                #else
                root
                #endif
            }
            .preferredColorScheme(.dark)
            .tint(.spotifyGreen)
            .onOpenURL { url in
                if auth.isAuthorized, !isPreview { SpotifyAppLauncher.shared.handle(url) }
            }
            .onChange(of: auth.isAuthorized, initial: true) { _, authorized in
                // Signed out: nothing should keep polling, and nothing from
                // the old account should still be on screen after a re-login.
                if !authorized {
                    SpotifyNowPlaying.shared.reset()
                    SpotifyAppLauncher.shared.reset()
                }
                // The backend identifies the account by its Spotify token.
                BackendClient.tokenProvider = authorized ? { [auth] in try await auth.validToken() } : nil
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { SpotifyNowPlaying.shared.stop() }
                if phase == .active, auth.isAuthorized, !isPreview { SpotifyNowPlaying.shared.start(api: SpotifyAPI(auth: auth)) }
            }
        }
    }

    /// Signed out: only the login screen, no tabs. Every tab needs Spotify.
    @ViewBuilder private var root: some View {
        if !auth.isAuthorized { LoginView().environmentObject(auth) }
        else if openLive { NavigationStack { SpotifyLiveView() }.environmentObject(auth) }
        else { MainTabsView().environmentObject(auth) }
    }

    /// Debug launch flag: straight to Live follow, for checking the runner
    /// against a real song without driving the UI.
    private var openLive: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--open-live")
        #else
        false
        #endif
    }

    private var isPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--chord-recognition-preview") || ProcessInfo.processInfo.arguments.contains("--song-sheet-preview") || ProcessInfo.processInfo.arguments.contains("--music-preview") || ProcessInfo.processInfo.arguments.contains("--practice-report-preview") || ProcessInfo.processInfo.arguments.contains("--saved-take-preview")
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
