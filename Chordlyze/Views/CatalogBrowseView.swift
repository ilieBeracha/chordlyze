import SwiftUI

/// Every chart on the server as crates: each way in (newest, difficulty,
/// genre, chord count, tempo, key) is a square cover built from its own
/// songs' artwork, in one grid with one search. No section headers; the
/// artwork carries the screen.
struct CatalogBrowseView: View {
    typealias Item = BackendClient.LibraryItem

    struct Crate: Identifiable {
        let title: String
        let items: [Item]
        var id: String { title }
    }

    let items: [Item]
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            searchField
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(Self.crates(items)) { crate in
                        NavigationLink { CatalogListView(title: crate.title, items: crate.items) } label: {
                            CrateCover(crate: crate)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            } else {
                CatalogRows(items: Self.search(items, query))
                    .padding(.horizontal, 20)
            }
        }
        .padding(.bottom, 110)  // clear of the floating tab bar
    }

    static func songs(_ count: Int) -> String { count == 1 ? "1 song" : "\(count) songs" }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.secondary)
            TextField("Search \(items.count) charts", text: $query)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.system(size: 15)).foregroundStyle(.white)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
        .padding(.horizontal, 20)
    }

    // MARK: - Crates

    /// Newest first, then difficulty, genres by size, chord count and tempo,
    /// then the keys with at least three charts. Empty crates are not shown.
    static func crates(_ items: [Item]) -> [Crate] {
        var out: [Crate] = []
        if items.count > 4 { out.append(Crate(title: "New charts", items: Array(items.prefix(12)))) }
        let byLevel = Dictionary(grouping: items.filter { $0.difficulty != nil }, by: { $0.difficulty!.level })
        for level in ["easy", "medium", "hard"] {
            if let group = byLevel[level], !group.isEmpty { out.append(Crate(title: "\(level.capitalized) to play", items: group)) }
        }
        out += grouped(items, by: \.genre)
        let few = items.filter { ($0.chordCount ?? .max) <= 4 }
        if !few.isEmpty { out.append(Crate(title: "Four chords or fewer", items: few)) }
        let bands: [(String, ClosedRange<Double>)] = [("Slow", 0...89.999), ("Mid tempo", 90...130), ("Fast", 130.001...1000)]
        for (title, range) in bands {
            let inBand = items.filter { $0.tempoBpm.map(range.contains) ?? false }
            if !inBand.isEmpty { out.append(Crate(title: title, items: inBand)) }
        }
        out += grouped(items, by: \.key).filter { $0.items.count >= 3 || items.count < 12 }
        return out
    }

    private static func grouped(_ items: [Item], by field: KeyPath<Item, String?>) -> [Crate] {
        Dictionary(grouping: items.filter { $0[keyPath: field] != nil }, by: { $0[keyPath: field]! })
            .map { Crate(title: $0.key, items: $0.value) }
            .sorted { $0.items.count != $1.items.count ? $0.items.count > $1.items.count : $0.title < $1.title }
    }

    static func search(_ items: [Item], _ query: String) -> [Item] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return items.filter {
            ($0.title ?? "").localizedCaseInsensitiveContains(needle)
                || ($0.artist ?? "").localizedCaseInsensitiveContains(needle)
                || ($0.genre ?? "").localizedCaseInsensitiveContains(needle)
        }
    }
}

/// A square cover: a two-by-two mosaic of the crate's own artwork under a
/// gradient, the name and count on top. Fewer than four songs repeat.
struct CrateCover: View {
    let crate: CatalogBrowseView.Crate

    private var artwork: [URL?] {
        let urls = crate.items.map(\.artworkURL)
        guard !urls.isEmpty else { return [] }
        return (0..<4).map { urls[$0 % urls.count] }
    }

    var body: some View {
        GeometryReader { geo in
            let half = geo.size.width / 2
            ZStack(alignment: .bottomLeading) {
                LazyVGrid(columns: [GridItem(.fixed(half), spacing: 0), GridItem(.fixed(half), spacing: 0)], spacing: 0) {
                    ForEach(Array(artwork.enumerated()), id: \.offset) { _, url in
                        ArtworkTile(url: url, size: half, radius: 0)
                    }
                }
                .saturation(0.85)
                LinearGradient(stops: [.init(color: .clear, location: 0.45), .init(color: .black.opacity(0.88), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 2) {
                    Text(crate.title).font(.system(size: 16, weight: .bold)).tracking(-0.2)
                        .foregroundStyle(.white).lineLimit(1)
                    Text(CatalogBrowseView.songs(crate.items.count)).font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.75))
                }
                .padding(12)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// A shelf opened: plain rows, same as Saved songs.
struct CatalogListView: View {
    let title: String
    let items: [BackendClient.LibraryItem]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    BackCircle()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.system(size: 26, weight: .bold)).tracking(-0.3).foregroundStyle(.white)
                        Text(CatalogBrowseView.songs(items.count)).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    }
                }
                .padding(.horizontal, 20)
                CatalogRows(items: items).padding(.horizontal, 20).padding(.top, 16)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

struct CatalogRows: View {
    let items: [BackendClient.LibraryItem]

    var body: some View {
        if items.isEmpty {
            Text("No charts match.").font(.system(size: 13)).foregroundStyle(Palette.secondary).padding(.vertical, 20)
        } else {
            VStack(spacing: 0) {
                ForEach(items) { item in
                    NavigationLink { SavedAnalysisView(item: item) } label: {
                        SongRow(artworkURL: item.artworkURL, title: item.title ?? "Unknown song",
                                artist: [item.artist, item.genre].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")) {
                            if let key = item.key { KeyBadge(key: key, difficulty: item.difficulty?.level) }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Square artwork cards in a horizontal strip; each opens its sheet.
struct ArtworkStrip: View {
    let items: [BackendClient.LibraryItem]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(items) { item in
                    NavigationLink { SavedAnalysisView(item: item) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            ArtworkTile(url: item.artworkURL, size: 118, radius: 12)
                            Text(item.title ?? "Unknown song").font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white).lineLimit(1)
                            Text([item.artist ?? "", item.key ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
                        }
                        .frame(width: 118, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, -20).padding(.leading, 20)
    }
}

struct ArtworkTile: View {
    let url: URL?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            LinearGradient(colors: [Palette.gray5, Palette.elevated], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
