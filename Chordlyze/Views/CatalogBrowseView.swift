import SwiftUI

/// Shared chart discovery lives exclusively in Search.
struct CatalogBrowseView: View {
    typealias Item = BackendClient.LibraryItem
    struct Crate: Identifiable {
        let title: String
        let items: [Item]
        var id: String { title }
    }
    let items: [Item]
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MusicSectionHeading(title: "Browse charts", detail: "\(items.count) available")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 280 : 150), spacing: 12)], spacing: 12) {
                ForEach(Self.crates(items)) { crate in
                    NavigationLink { CatalogListView(title: crate.title, items: crate.items) } label: {
                        CrateCover(crate: crate)
                    }.buttonStyle(MusicPressStyle())
                }
            }
            NavigationLink { CatalogListView(title: "All charts", items: items) } label: {
                HStack {
                    Text("View all charts")
                    Spacer()
                    Image(systemName: "arrow.right")
                }.font(MusicStyle.font(15, bold: true)).frame(minHeight: 44)
            }.buttonStyle(MusicPressStyle())
        }
    }

    static func songs(_ count: Int) -> String { count == 1 ? "1 song" : "\(count) songs" }

    // MARK: - Crates

    /// Newest first, then difficulty, genres by size, chord count and tempo,
    /// then the keys with at least three charts. Empty crates are not shown.
    static func crates(_ items: [Item]) -> [Crate] {
        var out: [Crate] = []
        if !items.isEmpty { out.append(Crate(title: "New charts", items: Array(items.prefix(12)))) }
        let byLevel = Dictionary(grouping: items.filter { $0.difficulty != nil }, by: { $0.difficulty!.level })
        for level in ["easy", "medium", "hard"] {
            if let group = byLevel[level], !group.isEmpty { out.append(Crate(title: "\(level.capitalized) to play", items: group)) }
        }
        out += grouped(items, by: \.genre)
        let few = items.filter { $0.chordCount.map { (1...4).contains($0) } ?? false }
        if !few.isEmpty { out.append(Crate(title: "Four chords or fewer", items: few)) }
        let tempos: [(String, (Double) -> Bool)] = [
            ("Slow tempo", { $0 > 0 && $0 < 90 }),
            ("Mid tempo", { $0 >= 90 && $0 <= 130 }),
            ("Fast tempo", { $0 > 130 })
        ]
        for (title, includes) in tempos {
            let group = items.filter { $0.tempoBpm.map(includes) ?? false }
            if !group.isEmpty { out.append(Crate(title: title, items: group)) }
        }
        out += grouped(items, by: \.key).filter { $0.items.count >= 3 || items.count < 12 }
        return out
    }

    private static func grouped(_ items: [Item], by field: KeyPath<Item, String?>) -> [Crate] {
        Dictionary(grouping: items.filter { $0[keyPath: field] != nil }, by: { $0[keyPath: field]! })
            .map { Crate(title: $0.key, items: $0.value) }
            .sorted { $0.items.count != $1.items.count ? $0.items.count > $1.items.count : $0.title < $1.title }
    }

}

struct CatalogListView: View {
    let title: String
    let items: [BackendClient.LibraryItem]
    @State private var query = ""
    @State private var filter: MusicFilter = .all

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                MusicHeader(title: title, subtitle: "Shared charts, ready to open and save.", isRoot: false)
                MusicSearchField(prompt: "Search these charts", text: $query)
                MusicFilters(selection: $filter)
                let matches = MusicQuery.apply(items, query: query, filter: filter)
                Text("\(matches.count) charts").font(MusicStyle.font(14)).foregroundStyle(MusicStyle.secondary)
                if matches.isEmpty {
                    MusicNotice(title: "No matching charts", message: "Try a different search or filter.", actionTitle: "Clear filters") {
                        query = ""; filter = .all
                    }
                } else { CatalogRows(items: matches) }
            }.padding(24)
        }.scrollDismissesKeyboard(.interactively).modifier(MusicSurface())
    }
}

struct CatalogRows: View {
    let items: [BackendClient.LibraryItem]
    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(items) { item in
                NavigationLink { SavedAnalysisView(item: item) } label: {
                    MusicSongRow(title: item.title ?? "Unknown song", artist: item.artist ?? "",
                                 artwork: item.artworkURL, key: item.key,
                                 detail: [item.difficulty?.level.capitalized,
                                          item.chordCount.map { "\($0) chords" }].compactMap { $0 }.joined(separator: " · "))
                }.buttonStyle(MusicPressStyle())
                MusicRule()
            }
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
                    Text(crate.title).font(MusicStyle.font(16, bold: true)).tracking(-0.2)
                        .foregroundStyle(.white).lineLimit(2)
                    Text(CatalogBrowseView.songs(crate.items.count)).font(MusicStyle.font(12))
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
