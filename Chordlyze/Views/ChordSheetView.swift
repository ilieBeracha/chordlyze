import SwiftUI

/// The chord sheet: one song document, the same rows Live and Practice use.
/// Capo and transpose are stored on the document, so every surface names
/// the same chords.
struct AnalysisTabsView: View {
    @StateObject private var store: SongSheetStore
    @State private var selectedChord: SelectedChord?
    @State private var showSettings = false
    @State private var practiceRange: ClosedRange<Double>?
    @State private var showLive = false
    @State private var starting = false
    @State private var startError: String?

    /// The Spotify poller behind Live seeks and calibration; the offline fixture passes its own.
    var nowPlaying: SpotifyNowPlaying = .shared

    init(song: SongDescriptor, store: SongSheetStore? = nil, nowPlaying: SpotifyNowPlaying = .shared) {
        _store = StateObject(wrappedValue: store ?? SongSheetStore.shared(for: song))
        self.nowPlaying = nowPlaying
    }

    var body: some View {
        VStack(spacing: 0) {
            SongSheetHeader(store: store)
            Rectangle().fill(Palette.separator).frame(height: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if store.canPractice { toolbar }
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
        .sheet(isPresented: $showSettings) { SongPlayingSettings(store: store, nowPlaying: nowPlaying) }
        .navigationDestination(isPresented: Binding(get: { practiceRange != nil },
            set: { if !$0 { practiceRange = nil } })) {
            if let range = practiceRange, let chart = store.analysis {
                PracticeView(analysis: chart, title: store.song.title, artist: store.song.artist,
                    album: store.song.album, trackID: store.song.id, songStore: store, initialRange: range)
            }
        }
        .navigationDestination(isPresented: $showLive) {
            LiveSongView(store: store, onSeek: { await nowPlaying.seek(to: $0) }, playbackNote: nowPlaying.playbackNote) {
                nowPlaying.livePosition().map(store.timing.chartTime)
            }
        }
        .observes(store)
    }

    /// One row under the header: play along with the song, practice, key
    /// and capo, save. The chart starts right beneath it.
    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    playAlong()
                } label: {
                    Label(starting ? "Starting…" : "Play along", systemImage: "play.fill")
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.spotifyGreen))
                }
                .buttonStyle(.plain).disabled(starting)
                .accessibilityIdentifier("play-along")
                if let chart = store.analysis {
                    NavigationLink {
                        PracticeView(analysis: chart, title: store.song.title, artist: store.song.artist,
                                     album: store.song.album, trackID: store.song.id, songStore: store)
                    } label: { tool("Practice") }
                    .buttonStyle(.plain)
                }
                Button { showSettings = true } label: { tool("Key & capo") }.buttonStyle(.plain)
                Button {
                    Task { await store.setSaved(!store.saved) }
                } label: {
                    Image(systemName: store.saved ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(store.saved ? Color.spotifyGreen : .white)
                        .frame(width: 44, height: 42)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
                }
                .buttonStyle(.plain).accessibilityIdentifier("save-toggle")
            }
            if let note = startError ?? store.saveError {
                Text(note).font(.footnote).foregroundStyle(Palette.warning)
            }
        }
    }

    private func tool(_ title: String) -> some View {
        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
    }

    /// Start the song on this phone's Spotify and follow it live.
    private func playAlong() {
        starting = true
        startError = nil
        Task {
            do {
                try await nowPlaying.play(trackID: store.song.id, at: 0)
                showLive = true
            } catch {
                startError = error.localizedDescription
            }
            starting = false
        }
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
                Text([store.song.artist, store.analysis?.key, store.chordNote,
                      store.analysis?.tempo.map { "\(Int($0.bpm.rounded())) BPM" }].compactMap { $0 }
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
            // Timing and edition notes live in Key & capo; the page shows only
            // what is still happening or went wrong.
            if store.lyricsLoading {
                note("Loading lyrics…", icon: nil, spinning: true) { EmptyView() }
            } else if store.lyricsFailed, let text = store.lyricsNote {
                note(text, icon: "clock") { Button("Retry") { store.refresh() } }
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
    /// Live: repeat this line until cleared.
    var onLoopRow: ((SheetModel.Row) -> Void)? = nil
    var verdict: ((Double) -> PracticeFeedback.Verdict?)? = nil
    /// Song time for the words, without the chord display lead.
    var wordPlayhead: Double? = nil

    var body: some View {
        LazyVStack(alignment: .leading, spacing: style == .live ? 22 : 20) {
            // A wordless row with no chord change of its own is the previous chord
            // still sounding: nothing to draw, so it takes no space.
            ForEach(store.rows.filter { !$0.text.isEmpty || !$0.chords.isEmpty || $0.kind == .uncovered }) { row in
                ChordRowView(row: row, transposeBy: store.shift, playhead: playhead,
                             style: style, onChordTap: onChordTap, onLyricTap: { onRowTap?(row) }, verdict: verdict,
                             wordPlayhead: wordPlayhead)
                    .padding(.vertical, 8)
                    .id(row.id)
                    .accessibilityIdentifier("song-row-\(row.start)")
                    .contextMenu {
                        if let onPracticeRow, row.start < (store.analysis?.coverageEnd ?? 0) {
                            Button("Practice this passage", systemImage: "mic.fill") { onPracticeRow(row) }
                        }
                        if let onLoopRow, row.start < (store.analysis?.coverageEnd ?? 0) {
                            Button("Loop this line", systemImage: "repeat") { onLoopRow(row) }
                        }
                    }
            }
        }
    }
}

struct SongPlayingSettings: View {
    @ObservedObject var store: SongSheetStore
    var nowPlaying: SpotifyNowPlaying = .shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("chordLead") private var lead = 0.0
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
                    Text("Every song, Live and Practice. Off by default; raise it only if chords light after you hear them change.")
                        .font(.footnote).foregroundStyle(.secondary)
                    NavigationLink {
                        TimingCalibrationView(store: store, nowPlaying: nowPlaying)
                    } label: {
                        LabeledContent("Calibrate by ear", value: store.timing.isIdentity ? "Not calibrated" : "Calibrated")
                    }
                    .disabled(!store.canPractice)
                    .accessibilityIdentifier("calibrate")
                    HStack {
                        Text(String(format: "This song: chords %@ by %.2f s", store.timing.offset > 0 ? "later" : "earlier", abs(store.timing.offset)))
                        Spacer()
                        Button("−") { Task { await store.nudgeTiming(chordsEarlierBy: -0.05) } }.buttonStyle(.bordered)
                        Button("+") { Task { await store.nudgeTiming(chordsEarlierBy: 0.05) } }.buttonStyle(.bordered)
                    }
                    .accessibilityIdentifier("timing-offset")
                    Text(store.timingError ?? store.timingNote ?? store.editionNote
                         ?? "Calibration aligns the chart's recording with the one Spotify plays, for this account.")
                        .font(.footnote).foregroundStyle(store.timingError == nil ? .secondary : Color(Palette.warning))
                }
                Button("Reset to original") {
                    store.manualShift = 0; store.capoMode = false; lead = 0.3
                    Task { await store.setTiming(nil) }
                }
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
