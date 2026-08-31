import SwiftUI

/// Every song ever analyzed — saved on the backend, survives app restarts.
struct LibraryView: View {
    @State private var items: [BackendClient.LibraryItem] = []
    @State private var error: String?

    var body: some View {
        List(items) { item in
            NavigationLink {
                SavedAnalysisView(item: item)
            } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(item.title ?? "Unknown song").font(.body)
                        if let artist = item.artist, !artist.isEmpty {
                            Text(artist).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let key = item.key {
                        Text(key)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.spotifyGreen)
                    }
                }
            }
        }
        .navigationTitle("Analyzed")
        .overlay {
            if let error {
                Text(error).foregroundStyle(.red).padding()
            } else if items.isEmpty {
                ContentUnavailableView("Nothing yet", systemImage: "music.note",
                                       description: Text("Songs you analyze appear here forever."))
            }
        }
        .task {
            do { items = try await BackendClient.library() }
            catch { self.error = "Could not load library: \(error.localizedDescription)" }
        }
    }
}

struct SavedAnalysisView: View {
    let item: BackendClient.LibraryItem
    @State private var analysis: ChordAnalysis?

    var body: some View {
        Group {
            if let analysis {
                AnalysisTabsView(analysis: analysis,
                                 title: item.title ?? "Unknown song", artist: item.artist ?? "")
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.ignoresSafeArea())
                    .toolbar(.hidden, for: .navigationBar)
            }
        }
        .task {
            analysis = await BackendClient.cachedAnalysis(trackID: item.trackId)
        }
    }
}
