import SwiftUI

/// Analyzed library, "key column" (design 5a): full-bleed rows on black with
/// album art and a two-line key badge (large root, small mode).
struct LibraryView: View {
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

    @State private var items: [BackendClient.LibraryItem] = []
    @State private var error: String?
    @State private var loading = true
    @AppStorage("librarySort") private var sortRaw = SortMode.recent.rawValue

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

                if loading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else if let error {
                    errorView(error)
                } else if items.isEmpty {
                    ContentUnavailableView("No analyses yet", systemImage: "music.note",
                                           description: Text("Play something with Auto Session, or open a song from your playlists."))
                        .padding(.top, 40)
                } else {
                    VStack(spacing: 0) {
                        ForEach(sorted) { item in
                            NavigationLink {
                                SavedAnalysisView(item: item)
                            } label: {
                                row(item)
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
            BackCircle(size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text("Analyzed")
                    .font(.system(size: 26, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(.white)
                if !items.isEmpty {
                    Text("\(items.count) songs · \(distinctKeys) keys")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: 0x8E8E93))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
    }

    // MARK: - Rows

    private func row(_ item: BackendClient.LibraryItem) -> some View {
        HStack(spacing: 13) {
            AsyncImage(url: item.artworkURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                LinearGradient(colors: [Color(hex: 0x2C2C2E), Color(hex: 0x1C1C1E)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title ?? "Unknown song")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let artist = item.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: 0x8E8E93))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let key = item.key {
                let (root, mode) = Self.splitKey(key)
                VStack(alignment: .trailing, spacing: 0) {
                    HStack(spacing: 5) {
                        if let level = item.difficulty?.level {
                            Circle()
                                .fill(Self.difficultyColor(level))
                                .frame(width: 6, height: 6)
                        }
                        Text(root)
                            .font(.system(size: 17, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.spotifyGreen)
                    }
                    if !mode.isEmpty {
                        Text(mode)
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.4)
                            .foregroundStyle(Color(hex: 0x5C5C60))
                    }
                }
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 20)
        .contentShape(Rectangle())
    }

    static func difficultyColor(_ level: String) -> Color {
        switch level {
        case "easy": return Color(hex: 0x30D158)
        case "medium": return Color(hex: 0xFFD60A)
        default: return Color(hex: 0xFF453A)
        }
    }

    /// "A# minor" -> ("A#", "minor"); keeps sharps/flats as the backend sent them.
    static func splitKey(_ key: String) -> (root: String, mode: String) {
        let parts = key.split(separator: " ", maxSplits: 1)
        guard let first = parts.first else { return (key, "") }
        return (String(first), parts.count > 1 ? parts[1].lowercased() : "")
    }

    // MARK: - States

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: 0x8E8E93))
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
            items = try await BackendClient.library()
            error = nil
        } catch {
            self.error = "Could not load library: \(error.localizedDescription)"
        }
        loading = false
    }
}

struct SavedAnalysisView: View {
    let item: BackendClient.LibraryItem
    @State private var analysis: ChordAnalysis?

    var body: some View {
        Group {
            if let analysis {
                AnalysisTabsView(analysis: analysis,
                                 title: item.title ?? "Unknown song", artist: item.artist ?? "",
                                 trackID: item.trackId)
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
