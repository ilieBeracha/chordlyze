import SwiftUI

/// Home tab: what the account has been playing, cross-referenced with the
/// analyzed library, and the songs analyzed most recently. Spotify playback
/// shows as a mini-player above the tab bar; the page itself does not change
/// between playing and idle.
struct HomeView: View {
    @EnvironmentObject var auth: SpotifyAuth
    @ObservedObject private var nowPlaying = SpotifyNowPlaying.shared
    @State private var library: [BackendClient.LibraryItem] = []
    @State private var plays: [RecentPlays.Song] = []
    @State private var playCount = 0
    /// The token predates the recently-played scope; a reconnect grants it.
    @State private var playsNeedReconnect = false
    @State private var likedCount: Int?
    @State private var topCount: Int?
    @State private var loaded = false
    @State private var error: String?

    private var analyzedByTrack: [String: BackendClient.LibraryItem] {
        Dictionary(library.map { ($0.trackId, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    statTiles
                    playedRecently
                    lastAnalyzed
                    if nowPlaying.needsReauth {
                        reconnectRow("Spotify stopped answering. Reconnect to see what's playing.")
                    } else if nowPlaying.playing == nil {
                        spotifyPrompt
                    }
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(Palette.destructive)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 62)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .ignoresSafeArea(edges: .top)
            .background(Color.black.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
            .navigationDestination(for: TrackSource.self) { source in
                TracksView(api: SpotifyAPI(auth: auth), source: source)
            }
            .toolbar(.hidden, for: .navigationBar)
            .refreshable {
                nowPlaying.resume()
                await reload()
            }
            // Every token grant (launch refresh, reconnect) restarts the
            // poller and reloads; a no-op for the poller while it runs.
            .task(id: auth.grants) {
                nowPlaying.start(api: SpotifyAPI(auth: auth))
                await reload()
            }
        }
    }

    private func reload() async {
        let api = SpotifyAPI(auth: auth)
        async let saved = try? BackendClient.library()
        async let liked = try? api.savedTracksTotal()
        async let top = try? api.topTracksTotal()
        do {
            let recent = try await api.recentlyPlayed()
            plays = RecentPlays.songs(recent)
            playCount = recent.count
            playsNeedReconnect = false
            error = nil
        } catch {
            let code = (error as NSError).code
            if code == 401 || code == 403 {
                playsNeedReconnect = true
            } else {
                self.error = "Could not load recent plays: \(error.localizedDescription)"
            }
        }
        library = (await saved) ?? []
        likedCount = await liked
        topCount = await top
        loaded = true
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 0) {
            Text("Home")
                .font(.system(size: 30, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(.white)
            Spacer()
            NavigationLink {
                ProfileView()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .padding(.trailing, -11)
        }
    }

    // MARK: - Stats

    private var statTiles: some View {
        HStack(spacing: 8) {
            NavigationLink { LibraryView() } label: {
                statTile(count: loaded ? library.count : nil, label: "Analyzed")
            }.buttonStyle(.plain)
            NavigationLink(value: TrackSource.liked) {
                statTile(count: likedCount, label: "Liked")
            }.buttonStyle(.plain)
            NavigationLink(value: TrackSource.top) {
                statTile(count: topCount, label: "Top")
            }.buttonStyle(.plain)
        }
    }

    private func statTile(count: Int?, label: String) -> some View {
        VStack(spacing: 2) {
            Text(count.map(String.init) ?? "—")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(1)
                .foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.homeCard))
    }

    // MARK: - Played recently

    private var playedRecently: some View {
        let analyzed = plays.filter { analyzedByTrack[$0.track.id] != nil }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                sectionLabel("PLAYED RECENTLY")
                Spacer()
                if !plays.isEmpty {
                    (Text("\(playCount)").foregroundStyle(.white).fontWeight(.bold)
                        + Text(playCount == 1 ? " play · " : " plays · ")
                        + Text("\(analyzed)").foregroundStyle(.white).fontWeight(.bold)
                        + Text(" analyzed"))
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.secondaryAlt)
                }
            }
            if playsNeedReconnect {
                reconnectRow("Reconnect Spotify to see what you played.")
            } else if plays.isEmpty {
                emptyRow(loaded ? "Nothing played yet." : "Loading your plays…")
            } else {
                VStack(spacing: 14) {
                    ForEach(plays.prefix(5)) { song in
                        NavigationLink {
                            ChordView(track: song.track)
                        } label: {
                            songRow(artwork: song.track.album.artworkURL, title: song.track.name,
                                    meta: [song.track.artistNames, RecentPlays.relativeTime(song.lastPlayed),
                                           song.count > 1 ? "×\(song.count)" : nil].compactMap { $0 }.joined(separator: " · "),
                                    saved: analyzedByTrack[song.track.id])
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Last analyzed

    private var lastAnalyzed: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                sectionLabel("LAST ANALYZED")
                Spacer()
                NavigationLink {
                    LibraryView()
                } label: {
                    Text("All songs")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.spotifyGreen)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
            if library.isEmpty {
                emptyRow(loaded ? "Analyze a song from Search or a playlist to see it here." : "Loading your library…")
            } else {
                VStack(spacing: 14) {
                    ForEach(library.prefix(3)) { item in
                        NavigationLink {
                            SavedAnalysisView(item: item)
                        } label: {
                            songRow(artwork: item.artworkURL, title: item.title ?? "Unknown song",
                                    meta: item.artist ?? "", saved: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Rows

    private func songRow(artwork url: URL?, title: String, meta: String,
                         saved: BackendClient.LibraryItem?) -> some View {
        HStack(spacing: 13) {
            artwork(url, size: 50, radius: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(meta)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let key = saved?.key {
                KeyBadge(key: key, difficulty: saved?.difficulty?.level)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.faint)
            }
        }
        .frame(minHeight: 50)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Palette.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.homeCard))
    }

    // MARK: - Spotify

    private var spotifyPrompt: some View {
        HStack(spacing: 10) {
            Circle().fill(Palette.faint).frame(width: 6, height: 6)
            Text("Play something on Spotify to follow chords live")
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(Palette.gray5)
        )
    }

    /// A token without a scope this build needs, or one Spotify revoked.
    private func reconnectRow(_ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.warning)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.white)
            Spacer()
            Button("Reconnect") { auth.login() }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.black)
                .padding(.vertical, 7)
                .padding(.horizontal, 12)
                .background(Capsule().fill(Color.spotifyGreen))
                .buttonStyle(.plain)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.08)))
    }

    /// Above the tab bar while Spotify plays; the page above does not move.
    private var miniPlayer: some View {
        VStack(spacing: 0) {
            if let playing = nowPlaying.playing {
                MiniPlayer(playing: playing, nowPlaying: nowPlaying,
                           store: SongSheetStore.shared(for: SongDescriptor(track: playing.track)))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.3), value: nowPlaying.playing == nil)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(Palette.secondary)
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
            async let lib = try? BackendClient.library()
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
