import SwiftUI

/// The song page: one song document, the rows Live and Practice use, at
/// Live's size. When Spotify has the song up the page follows it in place:
/// sounding chord bright, steady lyrics, and seeking by tapping a line.
/// The header holds playback and a menu for secondary song actions.
struct AnalysisTabsView: View {
    @StateObject private var store: SongSheetStore
    @ObservedObject private var takes: PracticeTakeStore
    @State private var selectedChord: SelectedChord?
    @State private var showSettings = false
    @State private var showSongMap = false
    @State private var showPractice = false
    @State private var showRecordings = false
    @State private var navigationTime: Double?
    @State private var practiceRange: ClosedRange<Double>?
    @State private var lastPosition = 0.0
    @State private var seekDenied = false
    @State private var startingPlayback = false
    @State private var playbackError: String?
    @State private var needsPlaybackDevice = false
    @State private var automaticallyOpenSpotify = false
    @State private var requestedPlaybackPosition = 0.0
    @State private var playbackTask: Task<Void, Never>?
    @Environment(\.openURL) private var openURL
    // A fresh song page starts with the diagrams closed. Timing quality must
    // never override this explicit presentation choice.
    @State private var showRail = false

    /// The Spotify poller behind seeks and calibration; the offline fixture passes its own.
    @ObservedObject var nowPlaying: SpotifyNowPlaying

    @MainActor init(song: SongDescriptor, store: SongSheetStore? = nil, nowPlaying: SpotifyNowPlaying? = nil,
                    takes: PracticeTakeStore? = nil) {
        _store = StateObject(wrappedValue: store ?? SongSheetStore.shared(for: song))
        _nowPlaying = ObservedObject(wrappedValue: nowPlaying ?? .shared)
        self.takes = takes ?? .shared
    }

    /// Spotify has this song up, playing or paused, whoever started it.
    private var songIsUp: Bool { store.canPractice && nowPlaying.playing?.track.id == store.song.id }
    private var beatGrid: BeatGrid? { store.beatGrid }
    private var duration: Double { store.song.duration ?? store.analysis?.coverageEnd ?? 0 }
    private func clamp(_ time: Double) -> Double { max(0, min(time, duration > 0 ? duration : .infinity)) }

    var body: some View {
        VStack(spacing: 0) {
            SongSheetHeader(store: store) {
                if store.canPractice {
                    HeaderCircle(icon: startingPlayback || nowPlaying.isControlling ? "ellipsis" : songIsUp && nowPlaying.playing?.isPlaying == true ? "waveform" : "play.fill",
                                 on: true, label: songIsUp && nowPlaying.playing?.isPlaying == true ? "Open playback controls in Spotify" : songIsUp ? "Resume song" : "Play along",
                                 identifier: "song-play-along") {
                        if songIsUp && nowPlaying.playing?.isPlaying == true { openSpotify() }
                        else { startPlayingAlong() }
                    }.disabled(startingPlayback || nowPlaying.isControlling)
                }
                songMenu
            }
            if store.canPractice {
                SongPlayingControls(store: store, showRail: $showRail)
            }
            // Keep the page's identity when Spotify starts during an app switch.
            // Replacing the idle subtree would dismiss its pending recovery.
            TimelineView(.animation(minimumInterval: 0.1, paused: !songIsUp)) { _ in
                let wordPosition = nowPlaying.livePosition().map(store.timing.chartTime) ?? lastPosition
                let position = wordPosition
                page(playhead: songIsUp ? position : nil, wordPlayhead: songIsUp ? wordPosition : nil)
                    .onChange(of: wordPosition) { _, value in
                        if songIsUp { lastPosition = value }
                    }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .chordDiagram($selectedChord)
        .onDisappear { playbackTask?.cancel(); playbackTask = nil }
        .sheet(isPresented: $showSongMap) {
            if let grid = beatGrid {
                SongMapSheet(grid: grid, position: lastPosition, onJump: { time in
                    navigationTime = nil
                    Task { @MainActor in
                        navigationTime = time
                        if songIsUp { seekDenied = !(await nowPlaying.seek(to: store.timing.spotifyTime(time))) }
                    }
                }, onPractice: { practiceRange = $0 })
            }
        }
        .navigationDestination(isPresented: $showPractice) {
            if let chart = store.analysis {
                PracticeView(analysis: chart, title: store.song.title, artist: store.song.artist,
                             album: store.song.album, trackID: store.song.id, songStore: store, nowPlaying: nowPlaying)
            }
        }
        .navigationDestination(isPresented: $showRecordings) {
            RecordingsView(song: store.song, takes: takes)
        }
        .sheet(isPresented: $showSettings) { SongPlayingSettings(store: store, nowPlaying: nowPlaying) }
        .navigationDestination(isPresented: Binding(get: { practiceRange != nil },
            set: { if !$0 { practiceRange = nil } })) {
            if let range = practiceRange, let chart = store.analysis {
                PracticeView(analysis: chart, title: store.song.title, artist: store.song.artist,
                    album: store.song.album, trackID: store.song.id, songStore: store, initialRange: range, nowPlaying: nowPlaying)
            }
        }
        .observes(store)
        .onAppear { takes.reload() }
    }

    /// Optional diagrams, status, the chart, and while playing the time line.
    /// Words and chords use the same calibrated recording clock, with their
    /// own measured intervals determining which element is sounding.
    private func page(playhead: Double?, wordPlayhead: Double?) -> some View {
        let activeID = wordPlayhead.flatMap { store.followingRow(at: $0)?.id }
        return VStack(spacing: 0) {
            // The optional progression belongs to the viewport, not lyric scroll
            // content: it remains available while auto-follow advances the page.
            if showRail, store.canPractice {
                ChordRailView(events: SheetModel.events(store.analysis), position: playhead ?? -1, transposeBy: store.shift,
                              onTap: { selectedChord = SelectedChord(name: $0) })
            }
            if store.needsChordPlaybackSummary {
                IndependentChordSummary(events: SheetModel.events(store.analysis), position: playhead,
                                        transposeBy: store.shift, onChordTap: { selectedChord = SelectedChord(name: $0) })
                    .padding(.horizontal, 24).padding(.bottom, 8)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if nowPlaying.isControlling || playbackError != nil || store.saveError != nil || nowPlaying.controlMessage != nil || needsPlaybackDevice {
                            playbackStatus
                        }
                        if store.actionTitle != nil || !store.message.isEmpty || store.lyricsLoading || store.lyricTimingMessage != nil || (store.lyricsFailed && store.lyricsNote != nil) {
                            SongSheetStatus(store: store)
                        }
                        ChordSheetView(store: store, playhead: playhead, style: .live,
                                       onChordTap: { selectedChord = SelectedChord(name: $0) },
                                       onRowTap: songIsUp ? { row in
                                           Task { seekDenied = !(await nowPlaying.seek(to: store.timing.spotifyTime(row.start))) }
                                       } : nil,
                                       onPracticeRow: store.canPractice ? { row in
                                           practiceRange = row.start...min(row.end, store.analysis?.coverageEnd ?? row.end)
                                       } : nil)
                    }
                    .padding(.horizontal, 24).padding(.top, 16)
                    .padding(.bottom, playhead == nil ? 40 : 320)  // the last lines can roll up to the reading height too
                }
                .onChange(of: navigationTime) { _, time in
                    guard !store.usesIndependentLyrics, let time,
                          let row = SheetModel.activeRow(store.rows, at: time) else { return }
                    withAnimation { proxy.scrollTo(row.id, anchor: .top) }
                }
                .refreshable { store.refresh() }
                .onChange(of: activeID, initial: true) { _, id in
                    // The line being sung settles a third of the way down, so what
                    // comes next is already in view; the roll is slow enough to follow.
                    guard !needsPlaybackDevice, let id else { return }
                    withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.32)) }
                }
            }
            if let playhead {
                HStack(spacing: 12) {
                    Button { openSpotify() } label: {
                        Image(systemName: "music.note").frame(width: 44, height: 44)
                    }.tint(.spotifyGreen).accessibilityLabel("Open playback controls in Spotify")
                    Text(mmss(clamp(playhead))).font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white).accessibilityIdentifier("live-position")
                    ProgressView(value: clamp(playhead), total: max(1, duration)).tint(.spotifyGreen)
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
            }
        }
    }

    /// Secondary actions stay labeled in one menu, outside the reading area.
    private var songMenu: some View {
        Menu {
            if store.canPractice {
                Button("Practice", systemImage: "guitars") { showPractice = true }
                    .accessibilityIdentifier("song-practice")
                if let grid = beatGrid, !grid.bars.isEmpty {
                    Button("Song map", systemImage: "map") { showSongMap = true }
                        .accessibilityIdentifier("song-map")
                }
            }
            Button("Song settings", systemImage: "slider.horizontal.3") { showSettings = true }
                .accessibilityIdentifier("song-settings")
            Button(store.saved ? "Remove from saved songs" : "Save song", systemImage: store.saved ? "bookmark.fill" : "bookmark") {
                Task { await store.setSaved(!store.saved) }
            }.accessibilityIdentifier("save-toggle")
            let recordings = takes.recordings(for: store.song.id)
            if !recordings.isEmpty {
                Button("Recordings (\(recordings.count))", systemImage: "waveform") { showRecordings = true }
                    .accessibilityIdentifier("song-recordings")
            }
            Button("Open in Spotify", systemImage: "arrow.up.forward.app", action: openSpotify)
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white).frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }.accessibilityLabel("Song options").accessibilityIdentifier("song-options")
    }

    private var playbackStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            if nowPlaying.isControlling {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for Spotify…").font(.footnote).foregroundStyle(Palette.secondary)
                }.accessibilityIdentifier("spotify-control-pending")
            }
            if let note = playbackError ?? store.saveError ?? (needsPlaybackDevice ? nil : nowPlaying.controlMessage)
                ?? (songIsUp && !nowPlaying.isControlling ? nowPlaying.playbackNote : nil) {
                Text(note).font(.footnote).foregroundStyle(Palette.warning)
            }
            if needsPlaybackDevice {
                SpotifyDeviceRecoveryView(nowPlaying: nowPlaying, trackID: store.song.id, retryTitle: "Retry play along",
                                          automaticallyOpen: automaticallyOpenSpotify, continueWhenReady: true,
                                          onRetry: { startPlayingAlong(retrying: true) })
            } else if playbackError != nil {
                Button("Open song in Spotify", action: openSpotify).frame(minHeight: 44).tint(.spotifyGreen)
            }
        }
    }

    private func startPlayingAlong(retrying: Bool = false) {
        guard !startingPlayback, !nowPlaying.isControlling else { return }
        startingPlayback = true
        playbackError = nil
        needsPlaybackDevice = false
        if !retrying {
            requestedPlaybackPosition = nowPlaying.playing?.track.id == store.song.id ? (nowPlaying.livePosition() ?? 0) : 0
        }
        playbackTask = Task { @MainActor in
            defer { startingPlayback = false; playbackTask = nil }
            do { try await nowPlaying.playAlong(trackID: store.song.id, resumingAt: requestedPlaybackPosition) }
            catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                needsPlaybackDevice = (error as? SpotifyNowPlaying.PlayError)?.needsDeviceRecovery == true
                automaticallyOpenSpotify = !retrying && (error as? SpotifyNowPlaying.PlayError)?.canWakeApp == true
                playbackError = automaticallyOpenSpotify ? nil : error.localizedDescription
            }
        }
    }

    private func openSpotify() {
        guard let url = URL(string: "spotify:track:\(store.song.id)") else { return }
        openURL(url)
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

/// Frequent playing choices stay within one tap, outside the scrolling sheet.
/// Diagram visibility belongs to the page; Simple version belongs to the song.
struct SongPlayingControls: View {
    @ObservedObject var store: SongSheetStore
    @Binding var showRail: Bool
    var allowsSimpleVersionChanges = true

    private var capoInstruction: String {
        store.capo == 0 ? "No capo needed" : "Capo on fret \(store.capo)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            control("Diagrams", icon: showRail ? "xmark" : "rectangle.grid.1x2", on: showRail) {
                withAnimation(.easeInOut(duration: 0.25)) { showRail.toggle() }
            }
            .accessibilityLabel(showRail ? "Hide chord diagrams" : "Show chord diagrams")
            .accessibilityValue(showRail ? "Shown" : "Hidden")
            .accessibilityIdentifier("chord-rail-toggle")

            VStack(spacing: 5) {
                control("Simple version", icon: store.capoMode ? "checkmark.circle.fill" : "circle", on: store.capoMode) {
                    store.capoMode.toggle()
                }
                .accessibilityValue(store.capoMode ? "On, \(capoInstruction)" : "Off")
                .disabled(!allowsSimpleVersionChanges)
                .accessibilityHint(allowsSimpleVersionChanges
                    ? "Uses easier chord shapes with a suggested capo position."
                    : "Finish practice before changing chord shapes.")
                .accessibilityIdentifier("simple-version-toggle")
                if store.capoMode {
                    Text(capoInstruction).font(.caption).foregroundStyle(Palette.secondary)
                        .accessibilityIdentifier("simple-version-capo")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20).padding(.bottom, 8)
    }

    private func control(_ title: String, icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, 10)
                .foregroundStyle(on ? Color.spotifyGreen : .white)
                .background(on ? Palette.greenTintFill : Palette.elevated, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
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
                        Text(title == "Analyze" ? "Analyze this song" : title == "Reconnect" ? "Reconnect" : "Retry analysis")
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
            } else if let text = store.lyricTimingMessage {
                note(text, icon: "waveform", spinning: store.timingLyrics) {
                    if store.canPractice && !store.timingLyrics {
                        Button(store.lyricTimingActionTitle) {
                            Task { await store.requestLyricTiming() }
                        }
                        .accessibilityIdentifier("sync-lyrics")
                    }
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
    @State private var editingRow: SheetModel.Row?
    @ObservedObject var store: SongSheetStore
    var playhead: Double? = nil
    var style: ChordRowView.Style = .sheet
    var onChordTap: ((String) -> Void)? = nil
    var onRowTap: ((SheetModel.Row) -> Void)? = nil
    var onPracticeRow: ((SheetModel.Row) -> Void)? = nil
    var verdict: ((Double) -> PracticeFeedback.Verdict?)? = nil

    var body: some View {
        LazyVStack(alignment: .leading, spacing: style == .live ? 22 : 20) {
            if store.usesIndependentLyrics, !store.independentChordTimeline.chords.isEmpty {
                DisclosureGroup("Chord timeline") {
                    ChordRowView(row: store.independentChordTimeline, transposeBy: store.shift, playhead: playhead,
                                 style: style, onChordTap: onChordTap, verdict: verdict)
                        .padding(.top, 8)
                }
                .font(.subheadline).tint(Palette.secondary)
                .accessibilityIdentifier("independent-chord-timeline")
            }
            // A wordless row with no chord change of its own is the previous chord
            // still sounding: nothing to draw, so it takes no space.
            ForEach(store.usesIndependentLyrics ? store.untimedLyricRows : store.rows.filter(\.hasVisibleContent)) { row in
                ChordRowView(row: row, transposeBy: store.shift, playhead: playhead,
                             style: style, onChordTap: onChordTap,
                             onLyricTap: store.usesIndependentLyrics ? nil : { onRowTap?(row) }, verdict: verdict)
                    .padding(.vertical, 8)
                    .id(row.id)
                    .accessibilityIdentifier("song-row-\(row.start)")
                    .contextMenu {
                        if !store.usesIndependentLyrics, store.analysis?.chartRevision != nil {
                            Button("Correct chords in this passage", systemImage: "pencil") { editingRow = row }
                        }
                        if !store.usesIndependentLyrics, let onPracticeRow, row.start < (store.analysis?.coverageEnd ?? 0) {
                            Button("Practice this passage", systemImage: "mic.fill") { onPracticeRow(row) }
                        }
                    }
            }
        }
        .sheet(item: $editingRow) { row in
            NavigationStack {
                ChordCorrectionsView(store: store, range: row.start...row.end)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { editingRow = nil }
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
    private var soundingKey: String {
        guard let key = store.analysis?.key else { return "Not available" }
        let parts = key.split(separator: " ", maxSplits: 1)
        guard let root = parts.first else { return key }
        return ([ChordMath.transpose(String(root), by: store.manualShift)] + parts.dropFirst().map(String.init)).joined(separator: " ")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Simple version", isOn: $store.capoMode)
                        .accessibilityIdentifier("simple-version-settings")
                    if store.capoMode {
                        LabeledContent("Capo", value: store.capo == 0 ? "No capo needed" : "Fret \(store.capo)")
                    }
                } footer: {
                    Text("Uses easier chord shapes. Place a capo at the shown fret to keep the same song key.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Sounding key") {
                    LabeledContent("Play in", value: soundingKey)
                    Stepper("Transpose: \(store.manualShift > 0 ? "+" : "")\(store.manualShift) semitones",
                        value: $store.manualShift, in: -6...6)
                    Text("Changes the displayed chords and the key used to score your playing. Spotify audio remains in its original key.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Chord corrections") {
                    NavigationLink {
                        ChordCorrectionsView(store: store)
                    } label: {
                        Label("Correct chords", systemImage: "pencil")
                    }
                    .disabled(store.analysis?.chartRevision == nil || store.analysis?.isPreview != false)
                    Text("Correct a chord once for this song's sheet, Live and practice.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Timing against Spotify") {
                    NavigationLink {
                        AutomaticSyncView(store: store, nowPlaying: nowPlaying)
                    } label: {
                        Label("Automatic sync", systemImage: "waveform")
                    }
                    .disabled(!store.canPractice || store.analysis?.chartRevision == nil)
                    .accessibilityIdentifier("automatic-sync")
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
                    store.manualShift = 0; store.capoMode = false
                    Task { await store.setTiming(nil) }
                }
                Section {
                    NavigationLink {
                        SongDeveloperToolsView(store: store)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Developer tools", systemImage: "wrench.and.screwdriver")
                            Text(store.reanalysisPending ? store.analysisProgressLabel
                                 : store.analysisInfo?.statusLabel ?? "Analysis details and reanalysis")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("song-developer-tools")
                }
            }
            .navigationTitle("Song settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct SongDeveloperToolsView: View {
    @ObservedObject var store: SongSheetStore

    var body: some View {
        Form {
            Section {
                Text(store.song.title).font(.headline)
                Text(store.song.artist).foregroundStyle(.secondary)
            }
            Section {
                if let info = store.analysisInfo {
                    LabeledContent("Status", value: info.statusLabel)
                        .accessibilityIdentifier("analysis-freshness")
                    LabeledContent("Version", value: info.versionLabel)
                        .accessibilityIdentifier("analysis-version")
                    LabeledContent("Last analyzed") {
                        if let date = info.analyzedDate {
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                                .multilineTextAlignment(.trailing)
                        } else {
                            Text("Date unknown").foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("analysis-date")
                    if let date = info.latestVersionDate {
                        LabeledContent("Latest version released") {
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                                .multilineTextAlignment(.trailing)
                        }
                    }
                } else {
                    Text("Analysis details aren't available from the service yet.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Saved analysis")
            } footer: {
                Text("Versions count updates to the song analyzer. Earlier analyses may not have a recorded date. Up to date describes the analyzer version; it does not guarantee that every chord or lyric is correct.")
            }
            if let info = store.analysisInfo, info.sourceProvider != nil || info.sourceTitle != nil {
                Section("Analyzed recording") {
                    if let title = info.sourceTitle, !title.isEmpty {
                        Text(title).textSelection(.enabled)
                            .accessibilityIdentifier("analysis-recording-title")
                    }
                    if let provider = info.sourceProvider, !provider.isEmpty {
                        LabeledContent("Source", value: provider.capitalized)
                    }
                }
            }
            Section {
                HStack {
                    if store.reanalysisPending { ProgressView().padding(.trailing, 4) }
                    Text(store.analysisProgressLabel)
                        .accessibilityIdentifier("analysis-progress")
                }
                if let message = store.analysisProgressMessage {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("analysis-message")
                }
                Button {
                    Task { await store.reanalyze() }
                } label: {
                    Label(store.requestingReanalysis ? "Requesting…" : "Reanalyze song", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(!store.canReanalyze)
                .accessibilityIdentifier("reanalyze-song")
                Button("Refresh status", systemImage: "arrow.triangle.2.circlepath") { store.refresh() }
                    .accessibilityIdentifier("refresh-analysis-status")
            } header: {
                Text("Reanalysis")
            } footer: {
                Text("Matches the recording again and rebuilds chords, rhythm and lyric timing. Your current chart stays available until the replacement is ready. Your edits remain saved; corrections or calibration may need review if the recording changes.")
            }
            if let info = store.analysisInfo, let model = info.model {
                Section("Analyzer") {
                    LabeledContent("Model", value: model)
                    if let revision = info.modelRevision {
                        Text(revision).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("Developer tools")
        .navigationBarTitleDisplayMode(.inline)
        .observes(store)
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


/// One bar-range picker shared by static sheets and live playback. All actions
/// use the exact detected boundary times, transformed only by the playback map.
struct SongMapSheet: View {
    let grid: BeatGrid
    let position: Double
    let onJump: (Double) -> Void
    var onPractice: ((ClosedRange<Double>) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var first = 1
    @State private var last = 1

    private var range: ClosedRange<Double>? { grid.barRange(first: first, last: last) }

    var body: some View {
        NavigationStack {
            Form {
                if !grid.sections.isEmpty {
                    Section("Sections") {
                        ForEach(grid.sections) { section in
                            Button {
                                first = section.startBar; last = section.endBar
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(section.title).foregroundStyle(.primary)
                                        Text("Bars \(section.startBar)–\(section.endBar) · \(mmss(section.start))–\(mmss(section.end))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if first == section.startBar && last == section.endBar {
                                        Image(systemName: "checkmark").foregroundStyle(Color.spotifyGreen)
                                    }
                                }
                            }.buttonStyle(.plain).accessibilityIdentifier("song-section-\(section.label)-\(section.occurrence)")
                        }
                    }
                }
                Section("Bar range") {
                    Stepper("Start bar · \(first)", value: $first, in: 1...max(1, grid.bars.count))
                        .onChange(of: first) { _, value in last = max(last, value) }
                        .accessibilityIdentifier("bar-range-start")
                    Stepper("End bar · \(last)", value: $last, in: first...max(first, grid.bars.count))
                        .accessibilityIdentifier("bar-range-end")
                    if let range {
                        Text("\(last-first+1) bars · \(preciseTime(range.lowerBound))–\(preciseTime(range.upperBound))")
                            .monospacedDigit().accessibilityIdentifier("bar-range-times")
                    } else {
                        Text("A gap in the detected bars crosses this range. Choose bars on one side of the gap.")
                            .foregroundStyle(Palette.warning)
                    }
                }
                Section {
                    Button("Go to start", systemImage: "arrow.right.to.line") {
                        guard let range else { return }; dismiss(); onJump(range.lowerBound)
                    }.disabled(range == nil).accessibilityIdentifier("bar-jump")
                    if let onPractice {
                        Button("Record selected bars", systemImage: "mic") {
                            guard let range else { return }; dismiss(); onPractice(range)
                        }.disabled(range == nil).accessibilityIdentifier("bar-practice")
                    }
                }
                Section {
                    DisclosureGroup("About this map") {
                        Text("Bar boundaries are estimated from the audio. Matching section letters mark similar passages, not verse or chorus labels. Only complete detected bars are selectable; pickups and an unfinished ending stay outside the map.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Song map")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                first = grid.barNumber(at: position) ?? 1
                last = min(grid.bars.count, first+3)
            }
        }.tint(.spotifyGreen).preferredColorScheme(.dark)
    }

    private func preciseTime(_ value: Double) -> String {
        String(format: "%d:%04.1f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60))
    }
}

/// Raw occurrences stay editable even when sheet layout hides held or silent chords.
struct ChordCorrectionsView: View {
    @ObservedObject var store: SongSheetStore
    var range: ClosedRange<Double>? = nil
    @State private var uncertainOnly = false
    @State private var selected: ChordSegment?
    @State private var editError: String?

    private var segments: [ChordSegment] {
        (store.analysis?.chords ?? []).filter { segment in
            if uncertainOnly && store.analysis?.chordReview?.contains(where: { $0.matches(segment) && $0.needsReview }) != true { return false }
            guard let range else { return true }
            return segment.start < range.upperBound && segment.end > range.lowerBound
        }
    }

    var body: some View {
        List {
            Section {
                Text("Choose the chord at the time you want to fix. Names here use the recording's original key, before transpose or capo.")
                    .font(.footnote).foregroundStyle(.secondary)
                if store.analysis?.boundariesEdited == true { Text("This chart includes your timing edits.").font(.footnote).foregroundStyle(.secondary) }
                if store.analysis?.correctionsStale == true {
                    Text("This song has a new analysis. Earlier corrections are no longer applied; check this chart before correcting it again.")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            Section {
                if store.analysis?.canUndo == true {
                    Button("Undo last edit", systemImage: "arrow.uturn.backward") { editChart(.undo) }
                        .disabled(store.savingCorrection)
                        .accessibilityIdentifier("undo-chord-edit")
                }
                if store.analysis?.boundariesEdited == true || store.analysis?.chords.contains(where: { $0.originalLabel != nil }) == true {
                    Button("Restore analyzed chart", role: .destructive) { editChart(.restore) }
                        .disabled(store.savingCorrection)
                    Text("Restores chord names and timing. You can undo this action.").font(.footnote).foregroundStyle(.secondary)
                }
                if let editError { Text(editError).foregroundStyle(.orange) }
            }
            Section {
                NavigationLink {
                    PassageAnalysisView(store: store, range: range)
                } label: { Label("Reanalyze a passage", systemImage: "waveform.path") }.disabled(store.analysis?.chartRevision == nil || store.analysis?.isPreview == true)
                Toggle("Show uncertain chords only", isOn: $uncertainOnly)
                if store.analysis?.chordReview == nil || store.analysis?.chordReview?.isEmpty == true {
                    Text("This chart has no review evidence yet. Reanalyze a passage to inspect it.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if uncertainOnly && segments.isEmpty {
                    Text("No uncertain chords flagged in this selection.").foregroundStyle(.secondary)
                }
            }
            Section("Chords") {
                ForEach(segments) { segment in
                    Button { selected = segment } label: {
                        HStack {
                            Text("\(mmss(segment.start))–\(mmss(segment.end))")
                                .monospacedDigit().foregroundStyle(.secondary)
                            Spacer()
                            Text(segment.displayName).fontWeight(.semibold)
                            if store.analysis?.chordReview?.contains(where: { $0.matches(segment) && $0.needsReview }) == true {
                                Image(systemName: "questionmark.circle").foregroundStyle(.orange).accessibilityLabel("Worth reviewing")
                            }
                            if segment.originalLabel != nil {
                                Image(systemName: "pencil.circle.fill")
                                    .accessibilityLabel("Corrected")
                            }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .accessibilityIdentifier("correct-chord-\(segment.start)")
                }
            }
        }
        .navigationTitle("Correct chords")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.observe() }
        .sheet(item: $selected) { segment in
            ChordCorrectionEditor(store: store, segment: segment)
        }
    }

    private func editChart(_ operation: BackendClient.BoundaryEdit.Operation) {
        guard let revision = store.analysis?.chartRevision else { return }
        editError = nil
        Task {
            do { try await store.editBoundary(.init(operation: operation, chartRevision: revision)) }
            catch { editError = error.localizedDescription }
        }
    }
}

private struct ChordCorrectionEditor: View {
    @ObservedObject var store: SongSheetStore
    let segment: ChordSegment
    @State private var name: String
    @State private var revision: String
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(store: SongSheetStore, segment: ChordSegment) {
        self.store = store
        self.segment = segment
        _name = State(initialValue: segment.displayName)
        _revision = State(initialValue: store.analysis?.chartRevision ?? "")
    }

    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool { cleanName == "N.C." || Chord(display: cleanName)?.quality.intervals != nil }
    private var changed: Bool { store.analysis?.chartRevision != revision }
    private var canSave: Bool { valid && cleanName != segment.displayName && !store.savingCorrection && !changed }

    var body: some View {
        NavigationStack {
            Form {
                Section("\(mmss(segment.start))–\(mmss(segment.end)) · original key") {
                    TextField("Chord, e.g. F#m7 or Bb/D", text: $name)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { if canSave { save(cleanName) } }
                        .font(.title2.monospaced()).accessibilityIdentifier("chord-correction-name")
                    Text("Use N.C. for no chord. Only this occurrence changes.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !valid {
                        Text("Enter a chord such as C, Am7, F# or Bb/D.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                Section {
                    NavigationLink("Edit chord timing") {
                        ChordBoundaryEditor(store: store, segment: segment, revision: revision) { dismiss() }
                    }
                    .disabled(store.savingCorrection || changed)
                    .accessibilityIdentifier("edit-chord-boundary")
                }
                if let review = store.analysis?.chordReview?.first(where: { $0.matches(segment) }), !review.alternatives.isEmpty {
                    Section("Alternatives from the recording") {
                        Text(review.reason).font(.footnote).foregroundStyle(.secondary)
                        ForEach(review.alternatives, id: \.self) { label in
                            let display = Chord(label: label)?.display ?? (label == "N" ? "N.C." : label)
                            Button(display) { name = display }.disabled(changed || store.savingCorrection)
                        }
                        Text("Tap an alternative, then Save to use it.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    NavigationLink("Reanalyze around this chord") {
                        PassageAnalysisView(store: store, range: max(0, segment.start - 2)...min(store.analysis?.coverageEnd ?? segment.end, segment.end + 2))
                    }.disabled(changed || store.savingCorrection)
                }
                if let original = segment.originalLabel {
                    Section {
                        LabeledContent("Originally analyzed", value: Chord(label: original)?.display ?? "N.C.")
                        Button("Restore original chord") { save(nil) }
                            .disabled(store.savingCorrection || changed)
                            .accessibilityIdentifier("restore-chord")
                    }
                }
                if changed {
                    Text("The chart changed while this editor was open. Close it and select the chord again before saving.")
                        .foregroundStyle(.orange)
                }
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("correction-error") }
                if store.savingCorrection { ProgressView("Saving correction…") }
            }
            .navigationTitle("Correct chord")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(store.savingCorrection)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(store.savingCorrection)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(cleanName) }
                        .disabled(!canSave)
                        .accessibilityIdentifier("save-chord-correction")
                }
            }
        }
    }

    private func save(_ name: String?) {
        error = nil
        Task {
            do {
                try await store.correctChord(segment, name: name, expectedRevision: revision)
                dismiss()
            } catch {
                if let backend = error as? BackendError {
                    let object = backend.detail.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                    self.error = object?["detail"] as? String ?? backend.detail
                } else {
                    self.error = "Could not save. Your edit is still here; check the connection and try again."
                }
            }
        }
    }
}

private struct ChordBoundaryEditor: View {
    enum Action: String, CaseIterable, Identifiable {
        case start = "Move start", end = "Move end", split = "Split chord", merge = "Merge with next"
        var id: String { rawValue }
    }
    @ObservedObject var store: SongSheetStore
    let segment: ChordSegment
    let revision: String
    let onSaved: () -> Void
    @State private var action = Action.end
    @State private var at: Double
    @State private var name: String
    @State private var error: String?

    init(store: SongSheetStore, segment: ChordSegment, revision: String, onSaved: @escaping () -> Void) {
        self.store = store; self.segment = segment; self.revision = revision; self.onSaved = onSaved
        _at = State(initialValue: segment.end)
        _name = State(initialValue: segment.displayName)
    }
    private var index: Int? { store.analysis?.chords.firstIndex(where: { $0.start == segment.start && $0.end == segment.end }) }
    private var previous: ChordSegment? { index.flatMap { $0 > 0 ? store.analysis?.chords[$0 - 1] : nil } }
    private var next: ChordSegment? { index.flatMap { $0 + 1 < (store.analysis?.chords.count ?? 0) ? store.analysis?.chords[$0 + 1] : nil } }
    private var limits: ClosedRange<Double>? {
        let lo: Double, hi: Double
        switch action {
        case .start:
            guard let previous, abs(previous.end - segment.start) < 0.000001 else { return nil }
            lo = previous.start + 0.1; hi = segment.end - 0.1
        case .end, .merge:
            guard let next, abs(segment.end - next.start) < 0.000001 else { return nil }
            lo = segment.start + 0.1; hi = next.end - 0.1
        case .split: lo = segment.start + 0.1; hi = segment.end - 0.1
        }
        return lo <= hi ? lo...hi : nil
    }
    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var changed: Bool { store.analysis?.chartRevision != revision }
    private var valid: Bool {
        guard !changed, !store.savingCorrection, let limits else { return false }
        if action == .split || action == .merge {
            guard cleanName == "N.C." || Chord(display: cleanName)?.quality.intervals != nil else { return false }
        }
        if action == .merge { return true }
        return at.isFinite && limits.contains(at) && (action == .split || at != (action == .start ? segment.start : segment.end))
    }
    var body: some View {
        Form {
            Section {
                Text("\(segment.displayName) · \(mmss(segment.start))–\(mmss(segment.end))").font(.headline)
                Picker("Change", selection: $action) {
                    ForEach(Action.allCases) { Text($0.rawValue).tag($0) }
                }
                .onChange(of: action) { _, value in
                    at = value == .split ? (segment.start + segment.end)/2 : value == .start ? segment.start : segment.end
                }
            }
            Section {
                if let limits {
                    if action != .merge {
                        LabeledContent("Time in seconds") {
                            TextField("Seconds", value: $at, format: .number.precision(.fractionLength(2)))
                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                                .accessibilityIdentifier("boundary-seconds")
                        }
                        Stepper(value: $at, in: limits, step: 0.1) {
                            Text(String(format: "Change at %.2f s", at)).monospacedDigit()
                        }
                        Slider(value: $at, in: limits, step: 0.05).accessibilityLabel("Chord boundary time")
                    }
                    if action == .split || action == .merge {
                        TextField(action == .split ? "Second chord" : "Chord to keep", text: $name)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("boundary-chord-name")
                    }
                    Text(explanation).font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("This change needs an adjacent analyzed chord, or an interval long enough to split.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Apply change") { save() }.disabled(!valid)
                    .accessibilityIdentifier("save-boundary-edit")
                if store.savingCorrection { ProgressView("Saving…") }
                if changed { Text("The chart changed. Close this editor and select the chord again.").foregroundStyle(.orange) }
                if let error { Text(error).foregroundStyle(.orange) }
            }
        }
        .navigationTitle("Edit chord timing")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(store.savingCorrection)
    }
    private var explanation: String {
        switch action {
        case .start: return "The preceding chord ends where this chord starts. Both sides move together."
        case .end: return "This chord ends where the next chord starts. Both sides move together."
        case .split: return "Keep \(segment.displayName) before this time; use the second chord after it."
        case .merge: return "Replace this chord and \(next?.displayName ?? "the next chord") with one continuous chord."
        }
    }
    private func save() {
        let operation: BackendClient.BoundaryEdit.Operation = action == .split ? .split : action == .merge ? .merge : .move
        let edit = BackendClient.BoundaryEdit(operation: operation, start: segment.start, end: segment.end,
            at: action == .merge ? nil : at, edge: action == .start ? "start" : "end",
            name: action == .split || action == .merge ? cleanName : nil, chartRevision: revision)
        error = nil
        Task {
            do { try await store.editBoundary(edit); onSaved() }
            catch {
                if let backend = error as? BackendError {
                    let object = backend.detail.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                    self.error = object?["detail"] as? String ?? backend.detail
                } else { self.error = "Could not save. Your changes are still here; try again." }
            }
        }
    }
}
