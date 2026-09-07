import SwiftUI

/// Library contains only this account's requested, saved, or practiced songs.
struct LibraryView: View {
    var isRoot = false
    var findSong: (() -> Void)? = nil
    @StateObject private var collection: MusicCollection
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var query = ""
    @State private var filter: MusicFilter = .all
    @AppStorage("librarySort") private var sortRaw = MusicSort.recent.rawValue

    init(isRoot: Bool = false, findSong: (() -> Void)? = nil,
         fetch: @escaping () async throws -> [BackendClient.LibraryItem] = { try await BackendClient.library() }) {
        self.isRoot = isRoot
        self.findSong = findSong
        _collection = StateObject(wrappedValue: MusicCollection(fetch: fetch))
    }

    private var songs: [BackendClient.LibraryItem] {
        MusicQuery.apply(collection.items, query: query, filter: filter, sort: MusicSort.restored(sortRaw))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                MusicHeader(title: "Your library", subtitle: "Saved and analyzed songs.", isRoot: isRoot)
                summary
                MusicSearchField(prompt: "Search your library", text: $query)
                MusicFilters(selection: $filter)
                if let error = collection.error {
                    MusicNotice(title: "Couldn’t refresh your songs", message: error,
                                actionTitle: "Try again") { Task { await collection.load() } }
                }
                if collection.loading && collection.items.isEmpty {
                    ProgressView("Loading your songs…").frame(maxWidth: .infinity, minHeight: 100)
                } else if collection.items.isEmpty && collection.error == nil {
                    VStack(alignment: .leading, spacing: 18) {
                        MusicNotice(title: "Start with a song you love", message: "Find a song in Search, then save its chart or request an analysis. It will appear here.")
                        discoveryLink
                    }
                } else if !collection.items.isEmpty {
                    songList
                }
                spotifyCollections
            }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .modifier(MusicSurface())
        .refreshable { await collection.load() }
        .task {
            sortRaw = MusicSort.restored(sortRaw).rawValue
            await collection.load()
        }
    }

    private var summaryText: String {
        if collection.items.isEmpty {
            if collection.loading { return "Loading songs…" }
            if collection.error != nil { return "Songs unavailable" }
        }
        return "\(collection.items.count) saved \(collection.items.count == 1 ? "song" : "songs")"
    }

    private var summary: some View {
        (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .bottom))) {
            Text(summaryText)
                .font(MusicStyle.font(15)).foregroundStyle(MusicStyle.secondary)
            Spacer()
            discoveryLink
        }.padding(.bottom, 22).overlay(alignment: .bottom) { MusicRule() }
    }

    @ViewBuilder private var discoveryLink: some View {
        if let findSong {
            Button(action: findSong) { Label("Find a song", systemImage: "plus").frame(minHeight: 44) }
                .font(MusicStyle.font(15, bold: true)).buttonStyle(MusicPressStyle())
        } else {
            NavigationLink { SearchView() } label: { Label("Find a song", systemImage: "plus").frame(minHeight: 44) }
                .font(MusicStyle.font(15, bold: true)).buttonStyle(MusicPressStyle())
        }
    }

    private var songList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(songs.count) \(songs.count == 1 ? "song" : "songs")")
                    .font(MusicStyle.font(14)).foregroundStyle(MusicStyle.secondary)
                Spacer()
                Menu {
                    Picker("Sort songs", selection: $sortRaw) {
                        ForEach(MusicSort.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                } label: {
                    Label(MusicSort.restored(sortRaw).rawValue,
                          systemImage: "arrow.up.arrow.down")
                        .font(MusicStyle.font(13, bold: true)).frame(minHeight: 44)
                }.accessibilityLabel("Sort songs, \(sortRaw)")
            }
            if songs.isEmpty {
                MusicNotice(title: "No matching songs", message: "Try another title, artist, key, or filter.", actionTitle: "Clear filters") {
                    query = ""; filter = .all
                }.padding(.top, 12)
            } else {
                CatalogRows(items: songs)
            }
        }
    }

    private var spotifyCollections: some View {
        VStack(alignment: .leading, spacing: 12) {
            MusicRule()
            MusicSectionHeading(title: "From Spotify")
            HStack(spacing: 12) {
                NavigationLink { SpotifyCollectionDestination(source: .liked) } label: {
                    collectionButton("Liked songs", icon: "heart")
                }
                NavigationLink { SpotifyCollectionDestination(source: .top) } label: {
                    collectionButton("Top tracks", icon: "chart.bar")
                }
            }.buttonStyle(MusicPressStyle())
        }
    }

    private func collectionButton(_ title: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: icon).font(.system(size: 22))
            Text(title).font(MusicStyle.font(15, bold: true))
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(MusicStyle.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct SpotifyCollectionDestination: View {
    @EnvironmentObject private var auth: SpotifyAuth
    let source: TrackSource
    var body: some View { TracksView(api: SpotifyAPI(auth: auth), source: source) }
}

struct SavedAnalysisView: View {
    let item: BackendClient.LibraryItem
    var body: some View {
        AnalysisTabsView(song: SongDescriptor(trackID: item.trackId, title: item.title ?? "Unknown song",
            artist: item.artist ?? "", album: item.album, duration: item.duration,
            isrc: item.isrc, artwork: item.artwork,
            itunesID: item.trackId.hasPrefix("itunes-") ? Int(item.trackId.dropFirst(7)) : nil))
    }
}
