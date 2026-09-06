import SwiftUI

/// Every chart on the server, arranged to be picked from rather than
/// scrolled: by how hard it is to play, by genre, key, tempo and chord
/// count, plus the newest charts. Each shelf opens a plain list.
struct CatalogBrowseView: View {
    typealias Item = BackendClient.LibraryItem

    struct Shelf: Identifiable {
        let title: String
        let items: [Item]
        var id: String { title }
    }

    let items: [Item]
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            searchField
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                shelves
            } else {
                CatalogRows(items: Self.search(items, query))
                    .padding(.horizontal, 20)
            }
        }
        .padding(.bottom, 110)  // clear of the floating tab bar
    }

    static func songs(_ count: Int) -> String { count == 1 ? "1 song" : "\(count) songs" }

    // MARK: - Shelves

    @ViewBuilder private var shelves: some View {
        let byLevel = Self.byDifficulty(items)
        let genres = Self.byGenre(items)
        let keys = Self.byKey(items)
        let tempos = Self.byTempo(items)
        let few = items.filter { ($0.chordCount ?? .max) <= 4 }
        section("Start here") {
            HStack(spacing: 10) {
                ForEach(["easy", "medium", "hard"], id: \.self) { level in
                    NavigationLink {
                        CatalogListView(title: "\(level.capitalized) to play", items: byLevel[level] ?? [])
                    } label: {
                        levelCard(level, count: byLevel[level]?.count ?? 0)
                    }
                    .buttonStyle(.plain)
                    .disabled((byLevel[level] ?? []).isEmpty)
                }
            }
        }
        if !few.isEmpty {
            section("Four chords or fewer", trailing: few.count) {
                NavigationLink { CatalogListView(title: "Four chords or fewer", items: few) } label: {
                    ArtworkStrip(items: Array(few.prefix(8)))
                }
                .buttonStyle(.plain)
            }
        }
        if !genres.isEmpty {
            section("Genres") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(genres) { shelf in
                        NavigationLink { CatalogListView(title: shelf.title, items: shelf.items) } label: {
                            genreCard(shelf)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        if !keys.isEmpty {
            section("Keys") {
                chipRow(keys) { shelf in
                    Text(shelf.title).font(.system(size: 14, weight: .bold, design: .rounded))
                    Text("\(shelf.items.count)").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
            }
        }
        if !tempos.isEmpty {
            section("Tempo") {
                chipRow(tempos) { shelf in
                    Text(shelf.title).font(.system(size: 14, weight: .semibold))
                    Text("\(shelf.items.count)").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
            }
        }
        section("New charts") {
            ArtworkStrip(items: Array(items.prefix(12)))
        }
    }

    private func section<Content: View>(_ title: String, trailing: Int? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                Spacer()
                if let trailing {
                    Text(Self.songs(trailing)).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
            }
            .padding(.horizontal, 20)
            content().padding(.horizontal, 20)
        }
    }

    private func levelCard(_ level: String, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Circle().fill(Palette.difficulty(level)).frame(width: 10, height: 10)
            Text(level.capitalized).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
            Text(Self.songs(count)).font(.system(size: 12)).foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.homeCard))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Palette.difficulty(level).opacity(0.35)))
        .opacity(count == 0 ? 0.4 : 1)
    }

    private func genreCard(_ shelf: Shelf) -> some View {
        HStack(spacing: 10) {
            ArtworkTile(url: shelf.items.first?.artworkURL, size: 40, radius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(shelf.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(Self.songs(shelf.items.count)).font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.homeCard))
    }

    private func chipRow<Label: View>(_ shelves: [Shelf], @ViewBuilder label: @escaping (Shelf) -> Label) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(shelves) { shelf in
                    NavigationLink { CatalogListView(title: shelf.title, items: shelf.items) } label: {
                        HStack(spacing: 6) { label(shelf) }
                            .foregroundStyle(Color.spotifyGreen)
                            .padding(.vertical, 8).padding(.horizontal, 12)
                            .background(Capsule().fill(Palette.greenTintFill))
                            .overlay(Capsule().strokeBorder(Palette.greenTintBorder))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, -20).padding(.leading, 20)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary)
            TextField("Search all charts", text: $query)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .foregroundStyle(.white)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
        .padding(.horizontal, 20)
    }

    // MARK: - Grouping

    static func search(_ items: [Item], _ query: String) -> [Item] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return items.filter {
            ($0.title ?? "").localizedCaseInsensitiveContains(needle)
                || ($0.artist ?? "").localizedCaseInsensitiveContains(needle)
                || ($0.genre ?? "").localizedCaseInsensitiveContains(needle)
        }
    }

    static func byDifficulty(_ items: [Item]) -> [String: [Item]] {
        Dictionary(grouping: items.filter { $0.difficulty != nil }, by: { $0.difficulty!.level })
    }

    static func byGenre(_ items: [Item]) -> [Shelf] {
        Dictionary(grouping: items.filter { $0.genre != nil }, by: { $0.genre! })
            .map { Shelf(title: $0.key, items: $0.value) }
            .sorted { $0.items.count != $1.items.count ? $0.items.count > $1.items.count : $0.title < $1.title }
    }

    static func byKey(_ items: [Item]) -> [Shelf] {
        Dictionary(grouping: items.filter { $0.key != nil }, by: { $0.key! })
            .map { Shelf(title: $0.key, items: $0.value) }
            .sorted { $0.items.count != $1.items.count ? $0.items.count > $1.items.count : $0.title < $1.title }
    }

    static func byTempo(_ items: [Item]) -> [Shelf] {
        let bands: [(String, ClosedRange<Double>)] = [("Slow · under 90", 0...89.999), ("Medium · 90–130", 90...130), ("Fast · over 130", 130.001...1000)]
        return bands.compactMap { title, range in
            let inBand = items.filter { $0.tempoBpm.map(range.contains) ?? false }
            return inBand.isEmpty ? nil : Shelf(title: title, items: inBand)
        }
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
