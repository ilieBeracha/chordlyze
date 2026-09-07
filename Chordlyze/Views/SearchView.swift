import SwiftUI

/// One global discovery destination: ready charts and the wider song catalog.
struct SearchView: View {
    var isRoot = false
    @State private var query = ""
    @StateObject private var catalog: MusicCollection
    @StateObject private var discovery: SongDiscovery
    @State private var filter: MusicFilter = .all

    init(isRoot: Bool = false,
         fetch: @escaping () async throws -> [BackendClient.LibraryItem] = { try await BackendClient.catalog() },
         discovery: SongDiscovery? = nil) {
        self.isRoot = isRoot
        _catalog = StateObject(wrappedValue: MusicCollection(fetch: fetch))
        _discovery = StateObject(wrappedValue: discovery ?? SongDiscovery())
    }

    private var browsing: Bool { MusicQuery.normalized(query).isEmpty }
    private var matchingCharts: [BackendClient.LibraryItem] { MusicQuery.apply(catalog.items, query: query, filter: filter) }
    private var otherSongs: [DiscoveredSong] {
        // Only an exact recording ID establishes that this iTunes result has a chart.
        let known = Set(catalog.items.map(\.trackId))
        return discovery.results.filter { !known.contains("itunes-\($0.id)") }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                MusicHeader(title: "Search", subtitle: "Search any song. Discover charts ready to play.", isRoot: isRoot)
                MusicSearchField(prompt: "Song, artist, or album", text: $query) { discovery.search(query, immediately: true) }
                if let error = catalog.error {
                    MusicNotice(title: "Charts couldn’t load", message: error, actionTitle: "Try again") { Task { await catalog.load() } }
                }
                if browsing {
                    if catalog.loading && catalog.items.isEmpty {
                        ProgressView("Loading charts…").frame(maxWidth: .infinity, minHeight: 100)
                    } else if catalog.items.isEmpty && catalog.error == nil {
                        MusicNotice(title: "What would you like to play?", message: "Search for a song or artist above. You can request a chart from the song sheet.")
                    } else if !catalog.items.isEmpty { CatalogBrowseView(items: catalog.items) }
                } else { searchResults }
            }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .modifier(MusicSurface())
        .onChange(of: query) { _, value in discovery.search(value) }
        .refreshable { await catalog.load() }
        .task { await catalog.load() }
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 20) {
            MusicSectionHeading(title: "Ready charts", detail: "\(matchingCharts.count)")
            MusicFilters(selection: $filter)
            if matchingCharts.isEmpty {
                Text(catalog.error == nil ? "No ready charts match this search and filter." : "Ready charts are unavailable. You can still search for songs below.")
                    .font(MusicStyle.font(14)).foregroundStyle(MusicStyle.secondary)
            } else { CatalogRows(items: matchingCharts) }
            MusicSectionHeading(title: "More songs")
            Text("Open a song to check its chart or request an analysis.")
                .font(MusicStyle.font(14)).foregroundStyle(MusicStyle.secondary)
            if discovery.searching {
                ProgressView("Searching songs…").frame(maxWidth: .infinity, minHeight: 60)
            } else if let error = discovery.error {
                MusicNotice(title: "Search couldn’t finish", message: error, actionTitle: "Try again") {
                    discovery.search(query, immediately: true)
                }
            } else if discovery.completedQuery != nil && otherSongs.isEmpty {
                Text("No more songs found. Try a different title or artist.")
                    .font(MusicStyle.font(14)).foregroundStyle(MusicStyle.secondary)
            }
            LazyVStack(spacing: 0) {
                ForEach(otherSongs) { song in
                    NavigationLink { SearchAnalysisView(song: song) } label: {
                        MusicSongRow(title: song.trackName, artist: song.artistName, artwork: song.artworkURL,
                                     detail: song.collectionName)
                    }.buttonStyle(MusicPressStyle())
                    MusicRule()
                }
            }
        }
    }
}

struct SearchAnalysisView: View {
    let song: DiscoveredSong
    var body: some View {
        AnalysisTabsView(song: SongDescriptor(trackID: "itunes-\(song.trackId)",
            title: song.trackName, artist: song.artistName, album: song.collectionName,
            duration: song.trackTimeMillis.map { Double($0) / 1000 },
            artwork: song.artworkUrl100, itunesID: song.trackId))
    }
}
