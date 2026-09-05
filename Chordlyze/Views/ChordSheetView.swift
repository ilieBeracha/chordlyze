import SwiftUI

/// The chord sheet: one song document, the same rows Live and Practice use.
/// Capo and transpose are stored on the document, so every surface names
/// the same chords.
struct AnalysisTabsView: View {
    @StateObject private var store: SongSheetStore
    @State private var selectedChord: SelectedChord?

    init(song: SongDescriptor, store: SongSheetStore? = nil) {
        _store = StateObject(wrappedValue: store ?? SongSheetStore.shared(for: song))
    }

    var body: some View {
        VStack(spacing: 0) {
            SongSheetHeader(store: store)
            Rectangle().fill(Palette.separator).frame(height: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if store.analysis != nil { toolbox }
                    SongSheetStatus(store: store)
                    ChordSheetView(store: store, onChordTap: { selectedChord = SelectedChord(name: $0) })
                }
                .padding(20)
            }
            .refreshable { store.refresh() }
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .chordDiagram($selectedChord)
        .observes(store)
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
                Button { store.manualShift = max(-6, store.manualShift - 1) } label: { Image(systemName: "minus") }
                    .accessibilityLabel("Transpose down")
                Text(store.manualShift == 0 ? "±0" : String(format: "%+d", store.manualShift))
                    .font(.system(size: 13, weight: .bold, design: .monospaced)).frame(width: 30)
                Button { store.manualShift = min(6, store.manualShift + 1) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Transpose up")
            }
            .buttonStyle(.plain).foregroundStyle(.white)
            Button { store.capoMode.toggle() } label: {
                Text(store.capoMode ? "Capo \(store.capo)" : "Original")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(Color.spotifyGreen)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
    }
}

/// Title, artist, key and the current capo/transpose, over every song surface.
struct SongSheetHeader: View {
    @ObservedObject var store: SongSheetStore

    var body: some View {
        HStack(spacing: 12) {
            BackCircle(size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.song.title).font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white).lineLimit(1)
                Text([store.song.artist, store.analysis?.key, store.chordNote].compactMap { $0 }
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}

/// Analysis and lyrics state under the toolbox. The Analyze/Retry label comes
/// from the document, the same one the Live card shows.
struct SongSheetStatus: View {
    @ObservedObject var store: SongSheetStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.message.isEmpty {
                note(store.message, icon: "exclamationmark.circle", spinning: store.busy) {
                    if let title = store.actionTitle { Button(title) { store.retry() } }
                }
            }
            if store.lyricsLoading {
                note("Loading lyrics…", icon: nil, spinning: true) { EmptyView() }
            } else if let text = store.lyricsNote {
                note(text, icon: "clock") {
                    if store.lyricsFailed { Button("Retry") { store.refresh() } }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("song-sheet-status")
    }

    private func note<Action: View>(_ text: String, icon: String?, spinning: Bool = false,
                                    @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 8) {
            if spinning {
                ProgressView().controlSize(.small)
            } else if let icon {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            }
            Text(text).font(.system(size: 12))
            action().font(.system(size: 12, weight: .bold))
        }
        .foregroundStyle(Palette.secondary)
    }
}

/// Shared rendering: lyrics never disappear because chords are still loading.
/// Chord names follow the document's shift on every surface.
struct ChordSheetView: View {
    @ObservedObject var store: SongSheetStore
    var playhead: Double? = nil
    var style: ChordRowView.Style = .sheet
    var onChordTap: ((String) -> Void)? = nil
    var onRowTap: ((SheetModel.Row) -> Void)? = nil

    var body: some View {
        LazyVStack(alignment: .leading, spacing: style == .live ? 30 : 20) {
            ForEach(store.rows) { row in
                ChordRowView(row: row, transposeBy: store.shift, playhead: playhead,
                             style: style, onChordTap: onChordTap, onLyricTap: { onRowTap?(row) })
                    .padding(.vertical, 8)
                    .id(row.id)
                    .accessibilityIdentifier("song-row-\(row.start)")
            }
        }
    }
}

extension View {
    /// Keeps the song document observed while this screen is on an active scene.
    func observes(_ store: SongSheetStore) -> some View { modifier(ObservesSongSheet(store: store)) }

    /// Tapping a chord anywhere opens the same guitar and piano diagram.
    func chordDiagram(_ selected: Binding<SelectedChord?>) -> some View {
        sheet(item: selected) { ChordDiagramSheet(chord: $0.name) }
    }
}

private struct ObservesSongSheet: ViewModifier {
    let store: SongSheetStore
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.task(id: scenePhase) {
            if scenePhase == .active { await store.observe() }
        }
    }
}
