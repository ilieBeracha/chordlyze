#if DEBUG
import SwiftUI

/// Explicit, offline preview fixtures. Never used by the signed-in application.
/// Launch --music-preview with --music-library, --music-search, --music-empty,
/// --music-error, or --music-large-type to inspect each state without an account.
struct MusicPreview: View {
    @StateObject private var recordings = SavedTakePreviewModel()
    @State private var tab: MainTabsView.Tab
    private let args = ProcessInfo.processInfo.arguments
    init() {
        let args = ProcessInfo.processInfo.arguments
        _tab = State(initialValue: (args.contains("--music-library") || args.contains("--music-recordings")) ? .library : args.contains("--music-search") ? .search : .home)
    }
    var body: some View {
        TabView(selection: $tab) {
            HomeView(openSearch: { tab = .search }, openLibrary: { tab = .library },
                     fetch: load, preview: true, takes: recordings.store)
                .tabItem { Label("Home", systemImage: "house") }.tag(MainTabsView.Tab.home)
            NavigationStack {
                SearchView(isRoot: true, fetch: load, discovery: SongDiscovery(fetch: { _ in [] }))
            }.tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(MainTabsView.Tab.search)
            NavigationStack { LibraryView(isRoot: true, findSong: { tab = .search }, takes: recordings.store,
                                         initialSection: args.contains("--music-recordings") ? .recordings : .songs, fetch: load) }
                .tabItem { Label("Library", systemImage: "music.note.list") }.tag(MainTabsView.Tab.library)
        }
        .tint(MusicStyle.accent)
        .preferredColorScheme(.dark)
        .environment(\.dynamicTypeSize, args.contains("--music-large-type") ? .accessibility3 : .large)
        .safeAreaInset(edge: .top, spacing: 0) {
            Text("Design preview · sample songs").font(.caption).foregroundStyle(MusicStyle.secondary)
                .frame(maxWidth: .infinity).background(MusicStyle.surface)
        }
    }

    private func load() async throws -> [BackendClient.LibraryItem] {
        if args.contains("--music-error") { throw URLError(.notConnectedToInternet) }
        if args.contains("--music-empty") { return [] }
        let rows: [[String: Any]] = [
            ["track_id": "preview-1", "title": "Autumn Leaves", "artist": "Sample jazz arrangement", "key": "G minor", "genre": "Jazz", "chord_count": 8, "tempo_bpm": 112, "difficulty": ["level": "medium", "score": 5]],
            ["track_id": "preview-2", "title": "Amazing Grace", "artist": "Sample folk arrangement", "key": "G major", "genre": "Folk", "chord_count": 3, "tempo_bpm": 78, "difficulty": ["level": "easy", "score": 2]],
            ["track_id": "preview-3", "title": "Greensleeves", "artist": "Sample acoustic arrangement", "key": "A minor", "genre": "Folk", "chord_count": 6, "tempo_bpm": 92, "difficulty": ["level": "medium", "score": 4]],
            ["track_id": "preview-4", "title": "When the Saints Go Marching In", "artist": "Sample piano arrangement", "key": "C major", "genre": "Jazz", "chord_count": 4, "tempo_bpm": 134, "difficulty": ["level": "easy", "score": 3]],
            ["track_id": "preview-5", "title": "שיר לדוגמה", "artist": "Sample Hebrew song", "key": "D minor", "genre": "Folk", "chord_count": 4, "tempo_bpm": 84, "difficulty": ["level": "easy", "score": 2]]
        ]
        return try JSONDecoder().decode([BackendClient.LibraryItem].self, from: JSONSerialization.data(withJSONObject: rows))
    }
}
#endif
