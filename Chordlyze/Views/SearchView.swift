import SwiftUI

/// Search any song (iTunes catalog) and analyze its chords — no Spotify needed.
struct SearchView: View {
    @State private var query = ""
    @State private var results: [ITunesSong] = []
    @State private var searching = false
    @FocusState private var focused: Bool

    struct ITunesSong: Decodable, Identifiable {
        let trackId: Int
        let trackName: String
        let artistName: String
        let artworkUrl60: String?
        var id: Int { trackId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { BackCircle(); Spacer() }
                .padding(.horizontal, 20)

            Text("Search")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 14)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Palette.secondary)
                TextField("Song or artist", text: $query)
                    .foregroundStyle(.white)
                    .focused($focused)
                    .submitLabel(.search)
                    .onSubmit { Task { await search() } }
                if searching { ProgressView().controlSize(.small) }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.elevated))
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results) { song in
                        NavigationLink {
                            SearchAnalysisView(song: song)
                        } label: {
                            HStack(spacing: 12) {
                                AsyncImage(url: song.artworkUrl60.flatMap(URL.init)) { image in
                                    image.resizable()
                                } placeholder: {
                                    Palette.elevated
                                }
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(song.trackName)
                                        .font(.system(size: 16))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Text(song.artistName)
                                        .font(.system(size: 13))
                                        .foregroundStyle(Palette.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color(hex: 0x5A5A5E))
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 20)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { focused = true }
    }

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        searching = true
        defer { searching = false }
        struct Response: Decodable { let results: [ITunesSong] }
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [.init(name: "term", value: term),
                            .init(name: "entity", value: "song"),
                            .init(name: "limit", value: "20")]
        guard let (data, _) = try? await URLSession.shared.data(from: comps.url!),
              let parsed = try? JSONDecoder().decode(Response.self, from: data) else { return }
        results = parsed.results
    }
}

/// Analyzes a searched song (server fetches the iTunes preview) and shows the sheet.
struct SearchAnalysisView: View {
    let song: SearchView.ITunesSong
    @State private var analysis: ChordAnalysis?
    @State private var failed = false

    var body: some View {
        Group {
            if let analysis {
                AnalysisTabsView(analysis: analysis, title: song.trackName, artist: song.artistName)
            } else if failed {
                VStack(spacing: 12) {
                    HStack { BackCircle(); Spacer() }
                    Spacer()
                    Text("Could not analyze this song.")
                        .foregroundStyle(Palette.secondary)
                    Spacer()
                }
                .padding(20)
            } else {
                VStack(spacing: 14) {
                    HStack { BackCircle(); Spacer() }
                    Spacer()
                    ProgressView()
                    Text("Analyzing \(song.trackName)…")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.secondary)
                    Spacer()
                }
                .padding(20)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            let trackID = "itunes-\(song.trackId)"
            if let cached = await BackendClient.cachedAnalysis(trackID: trackID) {
                analysis = cached
                return
            }
            analysis = await BackendClient.analyzeTrack(trackID: trackID, isrc: nil,
                                                        title: song.trackName,
                                                        artist: song.artistName)
            failed = analysis == nil
        }
    }
}
