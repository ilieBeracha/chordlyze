import SwiftUI

/// The song page: one song document, the rows Live and Practice use, at
/// Live's size. When Spotify has the song up the page follows it in place:
/// sounding chord bright, sung words lit, loop and seek by tapping a line.
/// The header holds the chord-shape rail toggle and, while playing, the loop.
struct AnalysisTabsView: View {
    @StateObject private var store: SongSheetStore
    @State private var selectedChord: SelectedChord?
    @State private var showSettings = false
    @State private var practiceRange: ClosedRange<Double>?
    @State private var starting = false
    @State private var startError: String?
    @State private var lastPosition = 0.0
    @State private var seekDenied = false
    /// A–B repeat: the range lives on the store; only the arming is view state.
    @State private var loopStart: Double?
    @State private var loopArmed = true
    @AppStorage("chordLead") private var lead = 0.0
    @AppStorage("chordRail") private var showRail = false

    /// The Spotify poller behind seeks and calibration; the offline fixture passes its own.
    @ObservedObject var nowPlaying: SpotifyNowPlaying

    @MainActor init(song: SongDescriptor, store: SongSheetStore? = nil, nowPlaying: SpotifyNowPlaying? = nil) {
        _store = StateObject(wrappedValue: store ?? SongSheetStore.shared(for: song))
        _nowPlaying = ObservedObject(wrappedValue: nowPlaying ?? .shared)
    }

    /// Spotify has this song up, playing or paused, whoever started it.
    private var songIsUp: Bool { store.canPractice && nowPlaying.playing?.track.id == store.song.id }
    private var duration: Double { store.song.duration ?? store.analysis?.coverageEnd ?? 0 }
    private func clamp(_ time: Double) -> Double { max(0, min(time, duration > 0 ? duration : .infinity)) }

    var body: some View {
        VStack(spacing: 0) {
            SongSheetHeader(store: store) {
                if store.canPractice {
                    HeaderCircle(icon: "guitars", on: showRail, label: showRail ? "Hide chord shapes" : "Show chord shapes",
                                 identifier: "chord-rail-toggle") {
                        withAnimation(.easeInOut(duration: 0.25)) { showRail.toggle() }
                    }
                    if songIsUp {
                        HeaderCircle(icon: "repeat", on: store.loop != nil || loopStart != nil,
                                     label: store.loop != nil ? "Clear loop" : loopStart == nil ? "Loop from here" : "Loop until here",
                                     identifier: store.loop != nil ? "loop-active" : "loop-start") {
                            loopTapped(at: lastPosition)
                        }
                    }
                }
            }
            if songIsUp {
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    // Words at the calibrated time; chords a little ahead of it by the display lead.
                    let wordPosition = clamp(nowPlaying.livePosition().map(store.timing.chartTime) ?? lastPosition)
                    let position = clamp(wordPosition + lead)
                    page(playhead: position, wordPlayhead: wordPosition)
                        .onChange(of: wordPosition) { _, value in
                            lastPosition = value
                            loopCheck(at: value)
                        }
                }
            } else {
                page(playhead: nil, wordPlayhead: nil)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .chordDiagram($selectedChord)
        .sheet(isPresented: $showSettings) { SongPlayingSettings(store: store, nowPlaying: nowPlaying) }
        .navigationDestination(isPresented: Binding(get: { practiceRange != nil },
            set: { if !$0 { practiceRange = nil } })) {
            if let range = practiceRange, let chart = store.analysis {
                PracticeView(analysis: chart, title: store.song.title, artist: store.song.artist,
                    album: store.song.album, trackID: store.song.id, songStore: store, initialRange: range)
            }
        }
        .onChange(of: songIsUp) { _, up in if !up { loopStart = nil } }
        .observes(store)
    }

    /// Rail, toolbar, status, the chart, and while playing the time line.
    /// `playhead` is the chart second Spotify is at plus the display lead;
    /// `wordPlayhead` the same without the lead.
    private func page(playhead: Double?, wordPlayhead: Double?) -> some View {
        let activeID = wordPlayhead.flatMap { SheetModel.activeRow(store.rows, at: $0)?.id }
        return VStack(spacing: 0) {
            if showRail, store.canPractice {
                ChordRailView(events: SheetModel.events(store.analysis), position: playhead ?? 0, transposeBy: store.shift,
                              onTap: { selectedChord = SelectedChord(name: $0) })
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if store.canPractice { toolbar(playhead: playhead) }
                        SongSheetStatus(store: store)
                        ChordSheetView(store: store, playhead: playhead, style: .live,
                                       onChordTap: { selectedChord = SelectedChord(name: $0) },
                                       onRowTap: songIsUp ? { row in
                                           Task { seekDenied = !(await nowPlaying.seek(to: store.timing.spotifyTime(row.start))) }
                                       } : nil,
                                       onPracticeRow: store.canPractice ? { row in
                                           practiceRange = row.start...min(row.end, store.analysis?.coverageEnd ?? row.end)
                                       } : nil,
                                       onLoopRow: songIsUp ? { row in
                                           store.loop = row.start...max(row.start + 1, row.end); loopStart = nil; loopArmed = true
                                       } : nil,
                                       wordPlayhead: wordPlayhead)
                    }
                    .padding(.horizontal, 24).padding(.top, 16)
                    .padding(.bottom, playhead == nil ? 40 : 320)  // the last lines can roll up to the reading height too
                }
                .refreshable { store.refresh() }
                .onChange(of: activeID, initial: true) { _, id in
                    // The line being sung settles a third of the way down, so what
                    // comes next is already in view; the roll is slow enough to follow.
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.32)) }
                }
            }
            if let playhead {
                HStack(spacing: 12) {
                    Text(mmss(playhead)).font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white).accessibilityIdentifier("live-position")
                    ProgressView(value: playhead, total: max(1, duration)).tint(.spotifyGreen)
                    loopChip
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
            }
        }
    }

    /// One row under the header: play along with the song, practice, key
    /// and capo, save. While the song is up, Play along has nothing to do
    /// and goes away.
    private func toolbar(playhead: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if playhead == nil {
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
                }
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
            if let note = startError ?? store.saveError ?? (seekDenied ? "Spotify could not seek. Check playback permissions or Premium." : nil) {
                Text(note).font(.footnote).foregroundStyle(Palette.warning)
            }
        }
    }

    private func tool(_ title: String) -> some View {
        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
    }

    /// Start the song on this phone's Spotify; the page lights up in place
    /// once the poller sees it.
    private func playAlong() {
        starting = true
        startError = nil
        Task {
            do {
                try await nowPlaying.play(trackID: store.song.id, at: 0)
            } catch {
                startError = error.localizedDescription
            }
            starting = false
        }
    }

    /// The loop circle: first tap marks A, the second marks B and starts the
    /// loop, a tap on a running loop clears it. Long-pressing a line loops it.
    private func loopTapped(at now: Double) {
        if store.loop != nil {
            store.loop = nil
        } else if let start = loopStart {
            guard now > start + 1 else { return }
            store.loop = start...now; loopStart = nil; loopArmed = true
        } else {
            loopStart = now
        }
    }

    /// Back to the start once per pass; re-arm after the jump lands.
    private func loopCheck(at value: Double) {
        guard let loop = store.loop else { return }
        if value >= loop.upperBound, loopArmed {
            loopArmed = false
            Task { seekDenied = !(await nowPlaying.seek(to: store.timing.spotifyTime(loop.lowerBound))) }
        } else if value < loop.upperBound - 1 {
            loopArmed = true
        }
    }

    /// Beside the progress line, only while a loop is being set or running.
    @ViewBuilder private var loopChip: some View {
        if let loop = store.loop {
            HStack(spacing: 5) {
                Image(systemName: "repeat").font(.system(size: 11, weight: .bold))
                Text("\(mmss(loop.lowerBound))–\(mmss(loop.upperBound))").monospacedDigit()
            }
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.spotifyGreen)
            .accessibilityIdentifier("loop-range")
        } else if let loopStart {
            Text("A \(mmss(loopStart)) · tap again at B").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Color.spotifyGreen)
        }
    }
}

/// Title, artist, key and the current capo/transpose, over every song surface.
/// `trailing` holds a screen's own round controls, matching the back circle.
struct SongSheetHeader<Trailing: View>: View {
    @ObservedObject var store: SongSheetStore
    @ViewBuilder var trailing: () -> Trailing

    init(store: SongSheetStore, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.store = store
        self.trailing = trailing
    }

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
            Spacer(minLength: 8)
            HStack(spacing: 8) { trailing() }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}

extension SongSheetHeader where Trailing == EmptyView {
    init(store: SongSheetStore) { self.init(store: store) { EmptyView() } }
}

/// A round header control the size of the back circle; green when on.
struct HeaderCircle: View {
    let icon: String
    var on = false
    var label: String
    var identifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(on ? .black : .white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(on ? Color.spotifyGreen : Palette.elevated))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: on)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier ?? "")
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
