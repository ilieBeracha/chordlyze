import SwiftUI

/// A short route back to music, followed by personal songs and recent listening.
struct HomeView: View {
    @EnvironmentObject private var auth: SpotifyAuth
    @ObservedObject private var nowPlaying = SpotifyNowPlaying.shared
    @ObservedObject private var takes = PracticeTakeStore.shared
    @ObservedObject private var artworkColors = ArtworkColor.shared
    @State private var fallbackArtwork: HomeArtwork?
    @StateObject private var collection: MusicCollection
    @State private var plays: [RecentPlays.Song] = []
    @State private var playsError: String?
    @State private var needsReconnect = false
    @State private var loadingPlays = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var openSearch: () -> Void
    var openLibrary: () -> Void
    var openPractice: () -> Void
    private let preview: Bool

    init(openSearch: @escaping () -> Void, openLibrary: @escaping () -> Void, openPractice: @escaping () -> Void,
         fetch: @escaping () async throws -> [BackendClient.LibraryItem] = { try await BackendClient.library() },
         preview: Bool = false) {
        self.openSearch = openSearch; self.openLibrary = openLibrary; self.openPractice = openPractice
        self.preview = preview
        _collection = StateObject(wrappedValue: MusicCollection(fetch: fetch))
    }

    private var ambientArtwork: HomeArtwork? {
        HomeArtwork.active(
            playing: preview ? nil : nowPlaying.playing.map { HomeArtwork(id: $0.track.id, url: $0.track.album.artworkURL) },
            isPlaying: !preview && nowPlaying.playing?.isPlaying == true,
            fallback: fallbackArtwork)
    }

    private var ambientColor: Color? {
        // Debug fixtures use a clearly labeled sample wash; real sessions
        // always extract their colors from the selected album artwork.
        if preview && !collection.items.isEmpty { return Color(red: 0.32, green: 0.18, blue: 0.14) }
        return ambientArtwork.flatMap { artworkColors.color(for: $0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    if collection.loading && collection.items.isEmpty {
                        ProgressView("Loading your music…").frame(maxWidth: .infinity, minHeight: 180)
                    } else if let song = collection.items.first {
                        featuredSong(song)
                    } else {
                        firstSong
                    }
                    quickActions
                    if !preview, let take = takes.takes.first { latestTake(take) }
                    if let error = collection.error {
                        MusicNotice(title: "Couldn’t refresh your library", message: error,
                                    actionTitle: "Try again") { Task { await collection.load() } }
                    }
                    if !collection.items.isEmpty { yourSongs }
                    if !preview { recentlyPlayed }
                }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 32)
            }
            .modifier(MusicSurface(ambient: ambientColor))
            .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
            .refreshable { await reload() }
            .task(id: auth.grants) { await reload() }
            .task(id: ambientArtwork?.id) {
                if let artwork = ambientArtwork { await artworkColors.load(trackID: artwork.id, url: artwork.url) }
            }
            .onAppear { if !preview { takes.reload() } }
            .onChange(of: collection.items.map(\.id)) { _, _ in chooseFallbackArtwork() }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Home").font(MusicStyle.font(38, bold: true, relativeTo: .largeTitle)).tracking(-1.3)
                    .accessibilityAddTraits(.isHeader)
                Text("A little practice. More music.").font(MusicStyle.font(15)).foregroundStyle(MusicStyle.secondary)
            }
            Spacer()
            NavigationLink { ProfileView() } label: {
                Image(systemName: "person.crop.circle").font(.system(size: 25, weight: .regular))
                    .frame(width: 44, height: 44).foregroundStyle(MusicStyle.ink)
            }.buttonStyle(MusicPressStyle()).accessibilityLabel("Profile and settings")
        }
    }

    private func featuredSong(_ song: BackendClient.LibraryItem) -> some View {
        NavigationLink { SavedAnalysisView(item: song) } label: {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Back to your music").font(MusicStyle.font(14, bold: true))
                        if let key = song.key {
                            Text(key).font(MusicStyle.font(48, bold: true, relativeTo: .largeTitle))
                                .tracking(-2).foregroundStyle(MusicStyle.accent)
                                .accessibilityLabel("Key, \(key)")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    MusicArtwork(url: song.artworkURL, size: 88)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(song.title ?? "Unknown song")
                        .font(MusicStyle.font(32, bold: true, relativeTo: .title)).tracking(-1).lineLimit(3)
                    Text(song.artist ?? "").font(MusicStyle.font(16)).foregroundStyle(MusicStyle.secondary)
                }
                MusicRule()
                HStack(alignment: .firstTextBaseline) {
                    Text([song.difficulty?.level.capitalized, song.chordCount.map { "\($0) chords" }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(MusicStyle.font(13)).foregroundStyle(MusicStyle.secondary)
                    Spacer()
                    Label("Open song", systemImage: "arrow.right").font(MusicStyle.font(15, bold: true))
                        .foregroundStyle(MusicStyle.accent)
                }
            }.padding(22).foregroundStyle(MusicStyle.ink)
                .background(MusicStyle.surface, in: RoundedRectangle(cornerRadius: 20))
                .contentShape(RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(MusicPressStyle())
    }

    private var firstSong: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "music.note.list").font(.system(size: 36)).foregroundStyle(MusicStyle.accent)
            Text("Start with a\nsong you love.")
                .font(MusicStyle.font(38, bold: true, relativeTo: .largeTitle)).tracking(-1.4)
            Text("Find its chords. Play a passage. Make it yours.")
                .font(MusicStyle.font(16)).foregroundStyle(MusicStyle.secondary)
            Button(action: openSearch) {
                Label("Find a song", systemImage: "arrow.right").font(MusicStyle.font(16, bold: true))
                    .frame(minHeight: 48).padding(.horizontal, 20)
                    .foregroundStyle(.black).background(MusicStyle.accent, in: Capsule())
            }.buttonStyle(MusicPressStyle())
        }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            .background(MusicStyle.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private var quickActions: some View {
        HStack(alignment: .top, spacing: 0) {
            Button(action: openSearch) { quickAction("Find a song", detail: "Search & discover", icon: "magnifyingglass") }
            Rectangle().fill(MusicStyle.rule).frame(width: 1)
            Button(action: openPractice) { quickAction("Practice", detail: "Drills & recordings", icon: "guitars") }
        }.fixedSize(horizontal: false, vertical: true).buttonStyle(MusicPressStyle())
            .padding(.vertical, 18)
            .overlay(alignment: .top) { MusicRule() }.overlay(alignment: .bottom) { MusicRule() }
    }

    private func quickAction(_ title: String, detail: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: icon).font(.system(size: 21)).padding(.bottom, 5).foregroundStyle(MusicStyle.accent)
            Text(title).font(MusicStyle.font(16, bold: true)).foregroundStyle(MusicStyle.ink)
            Text(detail).font(MusicStyle.font(12)).foregroundStyle(MusicStyle.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).contentShape(Rectangle())
    }

    private func latestTake(_ take: PracticeTake) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MusicSectionHeading(title: "Latest recording")
            NavigationLink { ScrollView { SavedTakeView(take: take) } } label: {
                MusicSongRow(title: take.song.title, artist: take.song.artist,
                             artwork: take.song.artwork.flatMap(URL.init),
                             detail: "\(take.createdAt.formatted(date: .abbreviated, time: .omitted)) · \(Int(take.plan.rate * 100))% pace")
            }.buttonStyle(MusicPressStyle())
            MusicRule()
        }
    }

    private var yourSongs: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                MusicSectionHeading(title: "Your songs")
                Button("See all", action: openLibrary).font(MusicStyle.font(14, bold: true))
                    .frame(minHeight: 44).fixedSize().buttonStyle(MusicPressStyle())
            }
            CatalogRows(items: Array(collection.items.prefix(3)))
        }
    }

    private var recentlyPlayed: some View {
        VStack(alignment: .leading, spacing: 12) {
            MusicSectionHeading(title: "Recently played", detail: "Spotify")
            if needsReconnect {
                MusicNotice(title: "Reconnect Spotify", message: "Reconnect to see your recent listening.", actionTitle: "Reconnect") { auth.login() }
            } else if let playsError {
                MusicNotice(title: "Recent listening is unavailable", message: playsError, actionTitle: "Try again") { Task { await loadPlays() } }
            } else if loadingPlays && plays.isEmpty {
                ProgressView("Loading recent songs…").frame(maxWidth: .infinity, minHeight: 60)
            } else if plays.isEmpty {
                Text("Songs you play on Spotify will appear here.").font(MusicStyle.font(15)).foregroundStyle(MusicStyle.secondary)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(plays.prefix(4))) { song in
                        NavigationLink { ChordView(track: song.track) } label: {
                            MusicSongRow(title: song.track.name, artist: song.track.artistNames,
                                         artwork: song.track.album.artworkURL, detail: RecentPlays.relativeTime(song.lastPlayed))
                        }.buttonStyle(MusicPressStyle())
                        MusicRule()
                    }
                }
            }
        }
    }

    private var miniPlayer: some View {
        Group {
            if !preview, let playing = nowPlaying.playing {
                MiniPlayer(playing: playing, nowPlaying: nowPlaying,
                           store: SongSheetStore.shared(for: SongDescriptor(track: playing.track)))
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }.animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 1), value: nowPlaying.playing == nil)
    }

    private func reload() async {
        if preview { await collection.load(); chooseFallbackArtwork(); return }
        nowPlaying.start(api: SpotifyAPI(auth: auth))
        async let songs: () = collection.load()
        async let listening: () = loadPlays()
        _ = await (songs, listening)
        chooseFallbackArtwork()
    }

    private func chooseFallbackArtwork() {
        let recent = plays.prefix(8).map { HomeArtwork(id: $0.track.id, url: $0.track.album.artworkURL) }
        let saved = collection.items.prefix(8).map { HomeArtwork(id: $0.trackId, url: $0.artworkURL) }
        fallbackArtwork = HomeArtwork.fallback(current: fallbackArtwork, recent: recent, saved: saved)
    }

    private func loadPlays() async {
        loadingPlays = true
        defer { loadingPlays = false }
        do {
            let recent = try await SpotifyAPI(auth: auth).recentlyPlayed()
            guard !Task.isCancelled else { return }
            plays = RecentPlays.songs(recent)
            needsReconnect = false; playsError = nil
        } catch {
            guard !Task.isCancelled else { return }
            let code = (error as NSError).code
            needsReconnect = code == 401 || code == 403
            playsError = MusicLoadError.message(error)
        }
    }
}

/// Song artwork with the app's dark-gradient fallback.
private func artwork(_ url: URL?, size: CGFloat, radius: CGFloat) -> some View {
    AsyncImage(url: url) { image in
        image.resizable().aspectRatio(contentMode: .fill)
    } placeholder: {
        LinearGradient(colors: [Palette.gray5, Palette.elevated],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
}

/// Now-playing strip: artwork, title, "artist · key", Follow live, and a
/// 2pt progress line driven by the poller's clock.
private struct MiniPlayer: View {
    let playing: SpotifyNowPlaying.Playing
    @ObservedObject var nowPlaying: SpotifyNowPlaying
    @ObservedObject var store: SongSheetStore

    private var subtitle: String {
        let artist = playing.track.artistNames
        if let key = store.analysis?.key, store.canPractice { return "\(artist) · \(key)" }
        if store.busy { return "\(artist) · analyzing…" }
        return artist
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                NavigationLink {
                    ChordView(track: playing.track)
                } label: {
                    HStack(spacing: 12) {
                        artwork(playing.track.album.artworkURL, size: 42, radius: 6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(playing.track.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(playing.isPlaying ? Color.spotifyGreen : Palette.secondary)
                                    .frame(width: 6, height: 6)
                                Text(subtitle)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Palette.secondaryAlt)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
                NavigationLink {
                    SpotifyLiveView()
                } label: {
                    Text("Follow live")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)
                        .background(Capsule().fill(Color.spotifyGreen))
                }
                .buttonStyle(.plain)
            }
            .padding(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 10))
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let duration = playing.track.durationMs.map { Double($0) / 1000 } ?? 0
                let fraction = duration > 0 ? max(0, min(1, (nowPlaying.livePosition() ?? 0) / duration)) : 0
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Palette.gray5
                        Color.spotifyGreen.frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 2)
            }
        }
        .background(Palette.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

enum TrackSource: Hashable {
    case liked
    case top
    case playlist(id: String, name: String)

    var title: String {
        switch self {
        case .liked: return "Liked Songs"
        case .top: return "Top Tracks"
        case .playlist(_, let name): return name
        }
    }
}
/// One source's tracks (liked, top, or a playlist), each with its saved key
/// when the library has it.
struct TracksView: View {
    let api: SpotifyAPI
    let source: TrackSource
    @State private var tracks: [Track] = []
    @State private var libraryByTrack: [String: BackendClient.LibraryItem] = [:]
    @State private var error: String?
    /// Spotify refuses playlist contents to apps in development mode (403).
    @State private var locked = false
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    BackCircle()
                    Spacer()
                    if !tracks.isEmpty {
                        let analyzed = tracks.filter { libraryByTrack[$0.id] != nil }.count
                        Text("\(tracks.count) songs · \(analyzed) analyzed")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.secondary)
                    }
                }
                .padding(.horizontal, 20)

                Text(source.title)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 10)

                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                } else if locked {
                    ContentUnavailableView {
                        Label("Playlist locked by Spotify", systemImage: "lock")
                    } description: {
                        Text("Spotify blocks playlist contents for apps in development mode. Use Liked Songs or Top Tracks.")
                    }
                } else if let error {
                    Text(error).foregroundStyle(Palette.destructive).padding(20)
                }

                ForEach(tracks) { track in
                    NavigationLink {
                        ChordView(track: track)
                    } label: {
                        SongRow(artworkURL: track.album.artworkURL,
                                title: track.name, artist: track.artistNames) {
                            if let saved = libraryByTrack[track.id], let key = saved.key {
                                KeyBadge(key: key, difficulty: saved.difficulty?.level)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Palette.chevron)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            defer { loading = false }
            async let lib = try? BackendClient.catalog()
            do {
                switch source {
                case .liked: tracks = try await api.likedTracks()
                case .top: tracks = try await api.topTracks()
                case .playlist(let id, _): tracks = try await api.tracks(playlistID: id)
                }
            } catch {
                if case .playlist = source, (error as NSError).code == 403 {
                    locked = true
                } else {
                    self.error = error.localizedDescription
                }
            }
            if let items = await lib {
                libraryByTrack = Dictionary(items.map { ($0.trackId, $0) }, uniquingKeysWith: { a, _ in a })
            }
        }
    }
}
