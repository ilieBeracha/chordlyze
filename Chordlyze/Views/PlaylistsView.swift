import SwiftUI

/// Home tab: what the account has been playing, cross-referenced with the
/// analyzed library, and the songs analyzed most recently. Spotify playback
/// shows as a mini-player above the tab bar; the page itself does not change
/// between playing and idle.
struct HomeView: View {
    @EnvironmentObject var auth: SpotifyAuth
    @ObservedObject private var nowPlaying = SpotifyNowPlaying.shared
    /// This account's songs. Charts anyone made are joined separately.
    @State private var library: [BackendClient.LibraryItem] = []
    @State private var catalog: [BackendClient.LibraryItem] = []
    @State private var plays: [RecentPlays.Song] = []
    @State private var recent: [SpotifyAPI.RecentPlay] = []
    @State private var playCount = 0
    /// The token predates the recently-played scope; a reconnect grants it.
    @State private var playsNeedReconnect = false
    @State private var likedCount: Int?
    @State private var topCount: Int?
    @State private var loaded = false
    @State private var error: String?

    /// Any chart on the server: a played song with a chart is ready to follow.
    private var analyzedByTrack: [String: BackendClient.LibraryItem] {
        Dictionary(catalog.map { ($0.trackId, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    statTiles
                    insights
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
        async let charts = try? BackendClient.catalog()
        async let liked = try? api.savedTracksTotal()
        async let top = try? api.topTracksTotal()
        do {
            let recent = try await api.recentlyPlayed()
            self.recent = recent
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
        catalog = (await charts) ?? []
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

    /// One card, three columns: the library the app made, and the two
    /// Spotify collections it can browse.
    private var statTiles: some View {
        HStack(spacing: 0) {
            NavigationLink { LibraryView() } label: {
                statTile(count: loaded ? library.count : nil, label: "Analyzed", icon: "waveform")
            }.buttonStyle(.plain)
            statDivider
            NavigationLink(value: TrackSource.liked) {
                statTile(count: likedCount, label: "Liked", icon: "heart.fill")
            }.buttonStyle(.plain)
            statDivider
            NavigationLink(value: TrackSource.top) {
                statTile(count: topCount, label: "Top", icon: "chart.bar.fill")
            }.buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.homeCard))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
    }

    private var statDivider: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(width: 0.5).padding(.vertical, 14)
    }

    private func statTile(count: Int?, label: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.spotifyGreen)
            Text(count.map { $0.formatted() } ?? "—")
                .font(.system(size: 24, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    // MARK: - Insights

    /// Two small charts from data already on the page: plays per day with the
    /// analyzed share, and what the analyzed library looks like. Hidden
    /// while there is nothing to draw; never seeded.
    @ViewBuilder private var insights: some View {
        if !recent.isEmpty || !library.isEmpty {
            VStack(spacing: 12) {
                if !recent.isEmpty { listeningCard }
                if !library.isEmpty { libraryCard }
            }
        }
    }

    private var listeningCard: some View {
        let days = RecentPlays.daily(recent, analyzed: Set(analyzedByTrack.keys))
        let peak = max(1, days.map(\.total).max() ?? 1)
        let analyzed = days.reduce(0) { $0 + $1.analyzed }
        let oldest = recent.map(\.playedAt).min()
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Listening").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                Text(oldest.map { "last \(recent.count) plays, since \(RecentPlays.relativeTime($0))" } ?? "")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(days, id: \.date) { day in
                    VStack(spacing: 6) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Palette.gray5)
                                .frame(height: max(3, 56 * CGFloat(day.total) / CGFloat(peak)))
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.spotifyGreen)
                                .frame(height: day.analyzed == 0 ? 0 : max(3, 56 * CGFloat(day.analyzed) / CGFloat(peak)))
                        }
                        .frame(maxWidth: .infinity, alignment: .bottom)
                        .accessibilityLabel("\(day.total) plays, \(day.analyzed) analyzed")
                        Text(day.date.formatted(.dateTime.weekday(.narrow)))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.tertiary)
                    }
                }
            }
            .frame(height: 74, alignment: .bottom)
            HStack(spacing: 6) {
                Circle().fill(Color.spotifyGreen).frame(width: 6, height: 6)
                Text("\(analyzed) of \(recent.count) plays were songs you can practice")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.homeCard))
    }

    private struct Bucket: Identifiable {
        let name: String
        let count: Int
        var id: String { name }
    }

    private var difficultyBuckets: [Bucket] {
        ["easy", "medium", "hard"].map { level in
            Bucket(name: level, count: library.filter { $0.difficulty?.level == level }.count)
        }
    }

    private var keyBuckets: [Bucket] {
        Dictionary(grouping: library.compactMap(\.key), by: { $0 })
            .map { Bucket(name: $0.key, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
            .prefix(4).map { $0 }
    }

    private var libraryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your \(library.count) analyzed songs").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            difficultyBar(difficultyBuckets)
            keyBars(keyBuckets)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.homeCard))
    }

    @ViewBuilder private func difficultyBar(_ levels: [Bucket]) -> some View {
        let graded = levels.reduce(0) { $0 + $1.count }
        if graded > 0 {
            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(levels.filter { $0.count > 0 }) { level in
                            Rectangle().fill(Palette.difficulty(level.name))
                                .frame(width: max(2, geo.size.width * CGFloat(level.count) / CGFloat(graded)))
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 8)
                HStack(spacing: 14) {
                    ForEach(levels) { level in
                        HStack(spacing: 5) {
                            Circle().fill(Palette.difficulty(level.name)).frame(width: 6, height: 6)
                            Text("\(level.count) \(level.name)").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func keyBars(_ keys: [Bucket]) -> some View {
        let top = CGFloat(max(1, keys.first?.count ?? 1))
        if !keys.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(keys) { key in
                    HStack(spacing: 10) {
                        Text(key.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.nearWhite)
                            .frame(width: 64, alignment: .leading).lineLimit(1)
                        GeometryReader { geo in
                            Capsule().fill(Color.spotifyGreen.opacity(0.75))
                                .frame(width: max(4, geo.size.width * CGFloat(key.count) / top))
                        }
                        .frame(height: 6)
                        Text("\(key.count)").font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Palette.secondary).monospacedDigit()
                            .frame(width: 28, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Played recently

    private var playedRecently: some View {
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                sectionLabel("Played recently")
                Spacer()
                if !plays.isEmpty {
                    Text("\(plays.count) songs")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.secondary)
                }
            }
            if playsNeedReconnect {
                reconnectRow("Reconnect Spotify to see what you played.")
            } else if plays.isEmpty {
                emptyRow(loaded ? "Nothing played yet." : "Loading your plays…")
            } else {
                rowList(Array(plays.prefix(5))) { song in
                    NavigationLink {
                        ChordView(track: song.track)
                    } label: {
                        songRow(artwork: song.track.album.artworkURL, title: song.track.name,
                                meta: "\(song.track.artistNames) · \(RecentPlays.relativeTime(song.lastPlayed))",
                                plays: song.count, saved: analyzedByTrack[song.track.id])
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Last analyzed

    private var lastAnalyzed: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                sectionLabel("Last analyzed")
                Spacer()
                NavigationLink {
                    LibraryView()
                } label: {
                    HStack(spacing: 3) {
                        Text("All songs")
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.spotifyGreen)
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
            if library.isEmpty {
                emptyRow(loaded ? "Analyze a song from Search or a playlist to see it here." : "Loading your library…")
            } else {
                rowList(Array(library.prefix(3))) { item in
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

    // MARK: - Rows

    /// Rows separated by a hairline that starts after the artwork, as a list does.
    private func rowList<Item: Identifiable, Row: View>(_ items: [Item], @ViewBuilder row: @escaping (Item) -> Row) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(item)
                if index < items.count - 1 {
                    Rectangle().fill(Palette.separator).frame(height: 0.5).padding(.leading, 65)
                }
            }
        }
    }

    private func songRow(artwork url: URL?, title: String, meta: String, plays: Int = 1,
                         saved: BackendClient.LibraryItem?) -> some View {
        HStack(spacing: 13) {
            artwork(url, size: 52, radius: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    Text(meta)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                    if plays > 1 {
                        Text("×\(plays)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Palette.secondaryAlt)
                            .padding(.vertical, 1).padding(.horizontal, 6)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                }
            }
            Spacer(minLength: 8)
            if let key = saved?.key {
                KeyBadge(key: key, difficulty: saved?.difficulty?.level)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.faint)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
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
            .font(.system(size: 20, weight: .bold))
            .tracking(-0.2)
            .foregroundStyle(.white)
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
