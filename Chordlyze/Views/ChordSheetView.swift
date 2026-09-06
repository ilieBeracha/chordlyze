import SwiftUI

/// The chord sheet: one song document, the same rows Live and Practice use.
/// Capo and transpose are stored on the document, so every surface names
/// the same chords.
struct AnalysisTabsView: View {
    @StateObject private var store: SongSheetStore
    @State private var selectedChord: SelectedChord?
    @State private var showSettings = false
    @State private var practiceRange: ClosedRange<Double>?

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
                    ChordSheetView(store: store, onChordTap: { selectedChord = SelectedChord(name: $0) },
                        onPracticeRow: store.canPractice ? { row in
                            practiceRange = row.start...min(row.end, store.analysis?.coverageEnd ?? row.end)
                        } : nil)
                }
                .padding(20)
            }
            .refreshable { store.refresh() }
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .chordDiagram($selectedChord)
        .sheet(isPresented: $showSettings) { SongPlayingSettings(store: store) }
        .navigationDestination(isPresented: Binding(get: { practiceRange != nil },
            set: { if !$0 { practiceRange = nil } })) {
            if let range = practiceRange, let chart = store.analysis {
                PracticeView(analysis: chart, title: store.song.title, artist: store.song.artist,
                    album: store.song.album, trackID: store.song.id, songStore: store, initialRange: range)
            }
        }
        .observes(store)
    }

    private var toolbox: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let chart = store.analysis, store.canPractice {
                HStack(spacing: 16) {
                    NavigationLink {
                        PracticeView(analysis: chart, title: store.song.title, artist: store.song.artist,
                                     album: store.song.album, trackID: store.song.id, songStore: store)
                    } label: {
                        Label("Practice", systemImage: "mic.fill").font(.headline)
                            .frame(minHeight: 44)
                    }.buttonStyle(.plain)
                    Spacer(minLength: 0)
                    Button("Choose section") { practiceRange = 0...min(30, chart.coverageEnd) }
                        .font(.subheadline).frame(minHeight: 44)
                }
                Divider()
                Button {
                    Task { await store.setSaved(!store.saved) }
                } label: {
                    HStack {
                        Label(store.saved ? "In your library" : "Save to library",
                              systemImage: store.saved ? "bookmark.fill" : "bookmark")
                        Spacer()
                        if let error = store.saveError {
                            Text(error).font(.caption).foregroundStyle(Palette.warning).lineLimit(1)
                        }
                    }.font(.subheadline).frame(minHeight: 44)
                }.buttonStyle(.plain)
                    .accessibilityIdentifier("save-toggle")
                Divider()
            }
            Button { showSettings = true } label: {
                HStack {
                    Label("Key & capo", systemImage: "slider.horizontal.3")
                    Spacer()
                    Image(systemName: "chevron.right")
                }.font(.subheadline).frame(minHeight: 44)
            }.buttonStyle(.plain)
        }
        .foregroundStyle(Color.spotifyGreen)
        .padding(.horizontal, 14).padding(.vertical, 6)
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

/// Analysis and lyrics state under the toolbox. When the song can be
/// analyzed, that is the one clear action on the page: a full-width button.
struct SongSheetStatus: View {
    @ObservedObject var store: SongSheetStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = store.actionTitle {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle").font(.system(size: 12, weight: .semibold))
                        Text(store.message).font(.system(size: 13))
                    }
                    .foregroundStyle(Palette.secondaryAlt)
                    Button { store.retry() } label: {
                        Text(title == "Analyze" ? "Analyze this song" : "Retry analysis")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(Color.spotifyGreen))
                    }
                    .buttonStyle(.plain)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.homeCard))
                .padding(.bottom, 4)
            } else if !store.message.isEmpty {
                note(store.message, icon: "exclamationmark.circle", spinning: store.busy) { EmptyView() }
            }
            if let text = store.editionNote {
                note(text, icon: "exclamationmark.triangle") { EmptyView() }
                    .accessibilityIdentifier("edition-note")
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
    var onPracticeRow: ((SheetModel.Row) -> Void)? = nil
    var verdict: ((Double) -> PracticeFeedback.Verdict?)? = nil

    var body: some View {
        LazyVStack(alignment: .leading, spacing: style == .live ? 30 : 20) {
            ForEach(store.rows) { row in
                ChordRowView(row: row, transposeBy: store.shift, playhead: playhead,
                             style: style, onChordTap: onChordTap, onLyricTap: { onRowTap?(row) }, verdict: verdict)
                    .padding(.vertical, 8)
                    .id(row.id)
                    .accessibilityIdentifier("song-row-\(row.start)")
                    .contextMenu {
                        if let onPracticeRow, row.start < (store.analysis?.coverageEnd ?? 0) {
                            Button("Practice this passage", systemImage: "mic.fill") { onPracticeRow(row) }
                        }
                    }
            }
        }
    }
}

struct SongPlayingSettings: View {
    @ObservedObject var store: SongSheetStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("chordLead") private var lead = 0.3
    private var soundingKey: String {
        guard let key = store.analysis?.key else { return "Not available" }
        let parts = key.split(separator: " ", maxSplits: 1)
        guard let root = parts.first else { return key }
        return ([ChordMath.transpose(String(root), by: store.manualShift)] + parts.dropFirst().map(String.init)).joined(separator: " ")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Sounding key") {
                    LabeledContent("Play in", value: soundingKey)
                    Stepper("Transpose: \(store.manualShift > 0 ? "+" : "")\(store.manualShift) semitones",
                        value: $store.manualShift, in: -6...6)
                    Text("Changes the displayed chords and the key used to score your playing. Spotify audio remains in its original key.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Guitar chord shapes") {
                    Toggle("Use suggested capo shapes", isOn: $store.capoMode)
                    if store.capoMode {
                        LabeledContent("Place capo at", value: store.capo == 0 ? "No capo needed" : "Fret \(store.capo)")
                    }
                    Text("With the capo at this fret, the displayed shapes produce the sounding key above. Capo shapes do not change the scoring key.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Timing against Spotify") {
                    Stepper(String(format: "Show chords ahead by %.1f s", lead), value: $lead, in: -1...2, step: 0.1)
                        .accessibilityIdentifier("chord-lead")
                    Text("Every song, Live and Practice. Raise it if chords highlight after you hear them change.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Stepper(String(format: "This song only: %@ by %.2f s", store.timingOffset < 0 ? "later" : "earlier", abs(store.timingOffset)),
                            value: $store.timingOffset, in: -5...5, step: 0.25)
                        .accessibilityIdentifier("timing-offset")
                    Text(store.editionNote ?? "For a chart whose recording starts earlier or later than the Spotify track.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("Reset to original") { store.manualShift = 0; store.capoMode = false; store.timingOffset = 0; lead = 0.3 }
            }
            .navigationTitle("Key & capo").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
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
