import SwiftUI

/// Analyzed library, "key column" (design 5a): full-bleed rows on black with
/// album art and a two-line key badge (large root, small mode).
struct LibraryView: View {
    var isRoot = false
    enum SortMode: String, CaseIterable, Identifiable {
        case recent, alpha, key
        var id: String { rawValue }
        var label: String {
            switch self {
            case .recent: return "Recent"
            case .alpha: return "A–Z"
            case .key: return "Key"
            }
        }
    }

    enum Scope: String, CaseIterable, Identifiable {
        case mine, everyone
        var id: String { rawValue }
        var label: String { self == .mine ? "My songs" : "Browse" }
    }

    @State private var items: [BackendClient.LibraryItem] = []
    @State private var error: String?
    @State private var loading = true
    @AppStorage("librarySort") private var sortRaw = SortMode.recent.rawValue
    /// Mine: songs this account requested, saved or practiced. Everyone:
    /// every chart on the server, ready to open and save.
    @State private var scope: Scope = .mine

    private var sortMode: SortMode { SortMode(rawValue: sortRaw) ?? .recent }
    private var sorted: [BackendClient.LibraryItem] {
        switch sortMode {
        case .recent:
            return items
        case .alpha:
            return items.sorted {
                ($0.title ?? "").localizedCaseInsensitiveCompare($1.title ?? "") == .orderedAscending
            }
        case .key:
            return items.sorted { ($0.key ?? "\u{10FFFF}") < ($1.key ?? "\u{10FFFF}") }
        }
    }
    private var distinctKeys: Int { Set(items.compactMap(\.key)).count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 20)
                Picker("Library", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20).padding(.top, 12)
                .onChange(of: scope) { _, _ in Task { loading = true; await load() } }

                if loading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else if let error {
                    errorView(error)
                } else if scope == .everyone {
                    CatalogBrowseView(items: items)
                        .padding(.top, 16)
                } else if items.isEmpty {
                    ContentUnavailableView(scope == .mine ? "No saved songs yet" : "No charts yet", systemImage: "music.note",
                                           description: Text(scope == .mine
                                               ? "Analyze a song, or save one from All charts, to find it here."
                                               : "Every song anyone analyzes shows up here."))
                        .padding(.top, 40)
                } else {
                    VStack(spacing: 0) {
                        ForEach(sorted) { item in
                            NavigationLink {
                                SavedAnalysisView(item: item)
                            } label: {
                                SongRow(artworkURL: item.artworkURL,
                                        title: item.title ?? "Unknown song",
                                        artist: item.artist ?? "") {
                                    if let key = item.key {
                                        KeyBadge(key: key, difficulty: item.difficulty?.level)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 16)
                    .animation(.default, value: sortRaw)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await load() }
        .task { await load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            if !isRoot { BackCircle() }
            VStack(alignment: .leading, spacing: 1) {
                Text(scope == .mine ? "Saved songs" : "Browse charts")
                    .font(.system(size: 26, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(.white)
                if !items.isEmpty {
                    Text(scope == .mine ? "\(items.count) songs · \(distinctKeys) keys"
                                        : "\(items.count) charts from every account")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if scope == .mine { sortMenu }
        }
    }

    private var sortMenu: some View {
            Menu {
                Picker("Sort", selection: $sortRaw) {
                    ForEach(SortMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
            } label: {
                Text("Sort")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.spotifyGreen)
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
            }
    }

    // MARK: - States

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await load() }
            } label: {
                Text("Retry")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.vertical, 11)
                    .padding(.horizontal, 26)
                    .background(Capsule().fill(Color.spotifyGreen))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .padding(.horizontal, 30)
    }

    // MARK: - Data

    private func load() async {
        do {
            items = try await (scope == .mine ? BackendClient.library() : BackendClient.catalog())
            error = nil
        } catch {
            self.error = "Could not load library: \(error.localizedDescription)"
        }
        loading = false
    }
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
