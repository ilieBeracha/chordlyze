import SwiftUI

/// Every chart on the server, arranged to be picked from rather than
/// scrolled. One accent colour, hierarchy from type and spacing: a
/// difficulty filter that narrows everything below, genres and collections
/// as quiet lists, keys as hairline chips, and the newest charts as a grid.
struct CatalogBrowseView: View {
    typealias Item = BackendClient.LibraryItem

    struct Shelf: Identifiable {
        let title: String
        let items: [Item]
        var id: String { title }
    }

    let items: [Item]
    @State private var query = ""
    @State private var level: String?  // nil = all

    private var filtered: [Item] {
        level.map { chosen in items.filter { $0.difficulty?.level == chosen } } ?? items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            searchField
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                levelFilter
                shelves
            } else {
                CatalogRows(items: Self.search(items, query))
                    .padding(.horizontal, 20)
            }
        }
        .padding(.bottom, 110)  // clear of the floating tab bar
    }

    static func songs(_ count: Int) -> String { count == 1 ? "1 song" : "\(count) songs" }

    // MARK: - Filter

    private var levelFilter: some View {
        let counts = Self.byDifficulty(items)
        return HStack(spacing: 8) {
            filterChip("All", count: items.count, selected: level == nil) { level = nil }
            ForEach(["easy", "medium", "hard"], id: \.self) { name in
                filterChip(name.capitalized, count: counts[name]?.count ?? 0, selected: level == name) {
                    level = level == name ? nil : name
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private func filterChip(_ title: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text("\(count)").font(.system(size: 12, weight: .medium)).monospacedDigit().opacity(0.6)
            }
            .foregroundStyle(selected ? .black : .white)
            .padding(.vertical, 8).padding(.horizontal, 13)
            .background(Capsule().fill(selected ? Color.white : Color.clear))
            .overlay(Capsule().strokeBorder(selected ? Color.clear : Palette.separator))
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .opacity(count == 0 ? 0.35 : 1)
        .animation(.easeOut(duration: 0.15), value: selected)
    }

    // MARK: - Shelves

    @ViewBuilder private var shelves: some View {
        let current = filtered
        let genres = Self.byGenre(current)
        let keys = Self.byKey(current)
        let collections = Self.collections(current)
        if current.isEmpty {
            Text("No charts at this level yet.").font(.system(size: 13)).foregroundStyle(Palette.secondary)
                .padding(.horizontal, 20)
        }
        if !genres.isEmpty {
            section("Genres") { rowList(genres) }
        }
        if !collections.isEmpty {
            section("Collections") { rowList(collections) }
        }
        if !keys.isEmpty {
            section("Keys") { keyChips(keys) }
        }
        if !current.isEmpty {
            section("Latest", trailing: current.count) { latestGrid(Array(current.prefix(6))) }
        }
    }

    private func section<Content: View>(_ title: String, trailing: Int? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 17, weight: .semibold)).tracking(-0.2).foregroundStyle(.white)
                Spacer()
                if let trailing {
                    Text(Self.songs(trailing)).font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                }
            }
            content()
        }
        .padding(.horizontal, 20)
    }

    /// Settings-style rows: name, count, chevron, hairlines between.
    private func rowList(_ shelves: [Shelf]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(shelves.enumerated()), id: \.element.id) { index, shelf in
                NavigationLink { CatalogListView(title: shelf.title, items: shelf.items) } label: {
                    HStack(spacing: 12) {
                        Text(shelf.title).font(.system(size: 16)).foregroundStyle(.white).lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(shelf.items.count)").font(.system(size: 14)).monospacedDigit().foregroundStyle(Palette.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.faint)
                    }
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < shelves.count - 1 {
                    Rectangle().fill(Palette.separator).frame(height: 0.5)
                }
            }
        }
    }

    private func keyChips(_ shelves: [Shelf]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(shelves) { shelf in
                    NavigationLink { CatalogListView(title: shelf.title, items: shelf.items) } label: {
                        HStack(spacing: 6) {
                            Text(shelf.title).font(.system(size: 14, weight: .semibold, design: .rounded))
                            Text("\(shelf.items.count)").font(.system(size: 12)).monospacedDigit().foregroundStyle(Palette.secondary)
                        }
                        .foregroundStyle(.white)
                        .padding(.vertical, 8).padding(.horizontal, 12)
                        .overlay(Capsule().strokeBorder(Palette.separator))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.horizontal, -20)
    }

    private func latestGrid(_ latest: [Item]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 16) {
            ForEach(latest) { item in
                NavigationLink { SavedAnalysisView(item: item) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        GeometryReader { geo in
                            ArtworkTile(url: item.artworkURL, size: geo.size.width, radius: 8)
                        }
                        .aspectRatio(1, contentMode: .fit)
                        Text(item.title ?? "Unknown song").font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white).lineLimit(1)
                        Text([item.artist ?? "", item.key ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.secondary)
            TextField("Search all charts", text: $query)
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

    /// Ways in that are not a genre or a key: chord count and tempo.
    static func collections(_ items: [Item]) -> [Shelf] {
        let bands: [(String, (Item) -> Bool)] = [
            ("Four chords or fewer", { ($0.chordCount ?? .max) <= 4 }),
            ("Slow, under 90 BPM", { ($0.tempoBpm ?? -1) >= 0 && $0.tempoBpm! < 90 }),
            ("Medium, 90 to 130 BPM", { ($0.tempoBpm ?? -1) >= 90 && $0.tempoBpm! <= 130 }),
            ("Fast, over 130 BPM", { ($0.tempoBpm ?? -1) > 130 }),
        ]
        return bands.compactMap { title, matches in
            let inBand = items.filter(matches)
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
