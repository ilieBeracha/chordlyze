import SwiftUI

/// Search any song (iTunes catalog) and analyze its chords — no Spotify needed.
struct SearchView: View {
    @State private var query = ""
    @State private var results: [ITunesSong] = []
    @State private var searching = false
    /// Last search failed (network) or found nothing; nil before any search.
    @State private var note: String?
    @FocusState private var focused: Bool

    struct ITunesSong: Decodable, Identifiable {
        let trackId: Int
        let trackName: String
        let artistName: String
        let artworkUrl100: String?
        var id: Int { trackId }
        var artworkURL: URL? { artworkUrl100.flatMap(URL.init) }
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
                    if let note {
                        Text(note)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(results) { song in
                        NavigationLink {
                            SearchAnalysisView(song: song)
                        } label: {
                            SongRow(artworkURL: song.artworkURL, title: song.trackName,
                                    artist: song.artistName) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Palette.chevron)
                            }
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
        do {
            let (data, _) = try await URLSession.shared.data(from: comps.url!)
            results = try JSONDecoder().decode(Response.self, from: data).results
            note = results.isEmpty ? "Nothing found for “\(term)”." : nil
        } catch {
            results = []
            note = "Search failed: \(error.localizedDescription)"
        }
    }
}

/// Analyzes a searched song (server fetches that exact iTunes track's
/// preview) and shows the sheet.
struct SearchAnalysisView: View {
    let song: SearchView.ITunesSong
    @State private var analysis: ChordAnalysis?
    @State private var failure: String?

    var body: some View {
        Group {
            if let analysis {
                AnalysisTabsView(analysis: analysis, title: song.trackName, artist: song.artistName,
                                 trackID: "itunes-\(song.trackId)")
            } else {
                WaitingView(title: song.trackName, subtitle: song.artistName.uppercased(),
                            message: failure ?? "Analyzing chords…", spinning: failure == nil)
            }
        }
        .task {
            do {
                analysis = try await BackendClient.retrying {
                    try await BackendClient.analyzeTrack(trackID: "itunes-\(song.trackId)", isrc: nil,
                                                         title: song.trackName, artist: song.artistName,
                                                         itunesID: song.trackId)
                }
                if analysis == nil { failure = "Chords unavailable for this song." }
            } catch {
                failure = "Couldn't reach the chord service: \(error.localizedDescription)"
            }
        }
    }
}
