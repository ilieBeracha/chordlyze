import SwiftUI

/// The same song document and rows used by live follow and recorded practice.
struct AnalysisTabsView: View {
    @StateObject private var store: SongSheetStore
    @State private var simple = false
    @State private var manualShift = 0
    @State private var selectedChord: SelectedChord?
    @Environment(\.scenePhase) private var scenePhase

    init(song: SongDescriptor, store: SongSheetStore? = nil) {
        _store = StateObject(wrappedValue: store ?? SongSheetStore.shared(for: song))
    }
    private var capo: Int {
        ChordMath.autoCapo(names: store.analysis?.chords.filter { $0.label != "N" }
            .map { ($0.displayName, $0.duration) } ?? [])
    }
    private var shift: Int { (simple ? -capo : 0) + manualShift }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.separator).frame(height: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if store.analysis != nil { toolbox }
                    SongSheetStatus(store: store)
                    ChordSheetView(store: store, transposeBy: shift,
                                   onChordTap: { selectedChord = SelectedChord(name: $0) })
                }
                .padding(20)
            }
            .refreshable { store.retry() }
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $selectedChord) { ChordDiagramSheet(chord: $0.name) }
        .task(id: scenePhase) {
            if scenePhase == .active { await store.observe() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            BackCircle(size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.song.title).font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white).lineLimit(1)
                Text([store.song.artist, store.analysis?.key].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var toolbox: some View {
        HStack(spacing: 12) {
            if let chart = store.analysis, store.canPractice {
                NavigationLink {
                    PracticeView(analysis: chart, title: store.song.title, artist: store.song.artist,
                                 album: store.song.album, trackID: store.song.id, songStore: store)
                } label: {
                    Label("Practice", systemImage: "mic.fill")
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(Color.spotifyGreen)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Button { manualShift = max(-6, manualShift - 1) } label: { Image(systemName: "minus") }
                    .accessibilityLabel("Transpose down")
                Text(manualShift == 0 ? "±0" : String(format: "%+d", manualShift))
                    .font(.system(size: 13, weight: .bold, design: .monospaced)).frame(width: 30)
                Button { manualShift = min(6, manualShift + 1) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Transpose up")
            }
            .buttonStyle(.plain).foregroundStyle(.white)
            Button { simple.toggle() } label: {
                Text(simple ? "Capo \(capo)" : "Original")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(Color.spotifyGreen)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
    }
}

struct SongSheetStatus: View {
    @ObservedObject var store: SongSheetStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.message.isEmpty {
                HStack(alignment: .top, spacing: 9) {
                    if store.busy { ProgressView().controlSize(.small) }
                    Text(store.message).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    if !store.busy { Button("Retry") { store.retry() }.font(.system(size: 12, weight: .bold)) }
                }
            }
            if store.lyricsLoading {
                Text("Loading lyrics…").font(.system(size: 12)).foregroundStyle(Palette.secondary)
            } else if let note = store.lyricsNote {
                HStack {
                    Text(note).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    if store.lyricsFailed { Button("Retry") { store.retry() }.font(.system(size: 12, weight: .bold)) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("song-sheet-status")
    }
}

/// Shared rendering: lyrics never disappear because chords are still loading.
struct ChordSheetView: View {
    @ObservedObject var store: SongSheetStore
    var transposeBy = 0
    var playhead: Double? = nil
    var style: ChordRowView.Style = .sheet
    var onChordTap: ((String) -> Void)? = nil
    var onRowTap: ((SheetModel.Row) -> Void)? = nil

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            ForEach(store.rows) { row in
                ChordRowView(row: row, transposeBy: transposeBy, playhead: playhead,
                             style: style, onChordTap: onChordTap, onLyricTap: { onRowTap?(row) })
                    .padding(.vertical, 8)
                    .opacity(playhead == nil || row.contains(playhead!) ? 1 : 0.55)
                    .id(row.id)
                    .accessibilityIdentifier("song-row-\(row.start)")
            }
            if !store.untimedLyrics.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Lyrics, no timing").font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.tertiary)
                    ForEach(Array(store.untimedLyrics.enumerated()), id: \.offset) { _, line in
                        Text(line).font(style.wordFont).foregroundStyle(Palette.secondary)
                            .frame(maxWidth: .infinity, alignment: line.isRTLText ? .trailing : .leading)
                    }
                }
                .padding(.top, 12)
                .accessibilityIdentifier("untimed-lyrics")
            }
        }
    }
}
