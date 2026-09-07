import SwiftUI

/// Live uses exactly the sheet's rows. A view-owned TimelineView drives the
/// playhead; no shared timer can disconnect when another screen disappears.
struct LiveNowView: View {
    @ObservedObject var store: SongSheetStore
    var onSeek: ((Double) async -> Bool)? = nil
    var playbackNote: String? = nil
    var verdict: ((Double) -> PracticeFeedback.Verdict?)? = nil
    /// Local stems already use the analyzed recording’s timeline.
    var seekUsesChartTime = false
    var showProgressStrip = true
    var loopSelection: Binding<ClosedRange<Double>?>? = nil
    /// Calibrated chart time, without display lead.
    let chartPosition: () -> TimeInterval?
    /// Seconds the highlight runs ahead of Spotify audio. Recognized chord
    /// boundaries land a little late and players read ahead of the beat.
    @AppStorage("chordLead") private var lead = 0.0
    @State private var lastPosition: Double = 0
    @State private var selectedChord: SelectedChord?
    @State private var seekDenied = false
    @State private var showSongMap = false
    private var beatGrid: BeatGrid? { store.beatGrid }
    /// A–B repeat: when the song reaches the end, Spotify is sent back to the
    /// start. The range lives on the store; only the arming is view state.
    @State private var loopStart: Double?
    @State private var loopArmed = true
    /// The strip of chord fingerings above the words; a bottom-bar toggle.
    @AppStorage("chordRail") private var showRail = false

    var body: some View {
        ScrollViewReader { proxy in
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let duration = seekUsesChartTime ? (store.analysis?.audioDuration ?? store.analysis?.coverageEnd ?? 0) : (store.song.duration ?? store.analysis?.coverageEnd ?? 0)
                // Words at the calibrated time; chords a little ahead of it by the display lead.
                let wordPosition = max(0, min(chartPosition() ?? lastPosition, duration > 0 ? duration : .infinity))
                let position = max(0, min(wordPosition + lead, duration > 0 ? duration : .infinity))
                let activeID = SheetModel.activeRow(store.rows, at: wordPosition)?.id
                VStack(spacing: 0) {
                    SongSheetHeader(store: store) {
                        HeaderCircle(icon: "guitars", on: showRail, label: showRail ? "Hide chord shapes" : "Show chord shapes",
                                     identifier: "chord-rail-toggle") {
                            withAnimation(.easeInOut(duration: 0.25)) { showRail.toggle() }
                        }
                        if let grid = beatGrid, !grid.bars.isEmpty, onSeek != nil {
                            HeaderCircle(icon: "map", on: false, label: "Song map and bar loops", identifier: "song-map") {
                                showSongMap = true
                            }
                        }
                        if onSeek != nil {
                            HeaderCircle(icon: "repeat", on: playbackLoop != nil || loopStart != nil,
                                         label: playbackLoop != nil ? "Clear loop" : loopStart == nil ? "Loop from here" : "Loop until here",
                                         identifier: playbackLoop != nil ? "loop-active" : "loop-start") {
                                loopTapped(at: wordPosition)
                            }
                        }
                    }
                    // Only what changes the moment: paused, reconnecting, a refused seek.
                    // Timing and edition notes live on the sheet page, not over the words.
                    if let playbackNote {
                        Text(playbackNote).font(.system(size: 13)).foregroundStyle(Palette.secondary)
                            .padding(.horizontal, 20).padding(.bottom, 6)
                    }
                    if seekDenied, playbackNote == nil {
                        Text("Spotify did not confirm the jump. Check playback in Spotify, then try again.").font(.caption)
                            .foregroundStyle(Palette.secondary).padding(.horizontal, 20).padding(.bottom, 6)
                    }
                    if showRail {
                        ChordRailView(events: SheetModel.events(store.analysis), position: position, transposeBy: store.shift,
                                      onTap: { selectedChord = SelectedChord(name: $0) })
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    ScrollView {
                        ChordSheetView(store: store, playhead: position, style: .live,
                                       onChordTap: { selectedChord = SelectedChord(name: $0) },
                                       onRowTap: { row in
                                           guard let onSeek else { return }
                                           Task { seekDenied = !(await onSeek(seekTime(row.start))) }
                                       }, onLoopRow: onSeek == nil ? nil : { row in
                                           playbackLoop = row.start...max(row.start + 1, row.end); loopStart = nil; loopArmed = true
                                       }, verdict: verdict, wordPlayhead: wordPosition)
                            .padding(.horizontal, 24).padding(.top, 40)
                            .padding(.bottom, 320)  // the last lines can roll up to the reading height too
                    }
                    .onChange(of: activeID, initial: true) { _, id in
                        // The line being sung settles a third of the way down, so what
                        // comes next is already in view; the roll is slow enough to follow.
                        if let id { withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.32)) } }
                    }
                    if showProgressStrip {
                    HStack(spacing: 12) {
                        Text(mmss(position)).font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white).accessibilityIdentifier("live-position")
                        ProgressView(value: position, total: max(1, duration)).tint(.spotifyGreen)
                        loopChip
                    }
                    .padding(.horizontal, 20).padding(.bottom, 24)
                    } else { loopChip.padding(.bottom, 8) }
                }
                .onChange(of: wordPosition) { _, value in
                    lastPosition = value
                    // Back to the start once per pass; re-arm after the jump lands.
                    if let loop = playbackLoop, let onSeek {
                        if value >= loop.upperBound, loopArmed {
                            loopArmed = false
                            Task { seekDenied = !(await onSeek(seekTime(loop.lowerBound))) }
                        } else if value < loop.upperBound - min(1, (loop.upperBound - loop.lowerBound) / 2) {
                            loopArmed = true
                        }
                    }
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .sheet(isPresented: $showSongMap) {
            if let grid = beatGrid, let onSeek {
                SongMapSheet(grid: grid, position: lastPosition, onJump: { time in
                    playbackLoop = nil; loopStart = nil
                    Task { seekDenied = !(await onSeek(seekTime(time))) }
                }, onLoop: { range in
                    playbackLoop = range; loopStart = nil; loopArmed = true
                    Task { seekDenied = !(await onSeek(seekTime(range.lowerBound))) }
                })
            }
        }
        .chordDiagram($selectedChord)
        .observes(store)
    }

    private var playbackLoop: ClosedRange<Double>? {
        get {
            if let loopSelection { return loopSelection.wrappedValue }
            return store.loop
        }
        nonmutating set {
            if let loopSelection { loopSelection.wrappedValue = newValue }
            else { store.loop = newValue }
        }
    }

    private func seekTime(_ time: Double) -> Double {
        seekUsesChartTime ? time : store.timing.spotifyTime(time)
    }

    /// The loop circle in the header: first tap marks A, the second marks B
    /// and starts the loop, a tap on a running loop clears it. Long-pressing
    /// a line loops that line directly.
    private func loopTapped(at now: Double) {
        if playbackLoop != nil {
            playbackLoop = nil
        } else if let start = loopStart {
            guard now > start + 1 else { return }
            playbackLoop = start...now; loopStart = nil; loopArmed = true
        } else {
            loopStart = now
        }
    }

    /// Under the progress line, only while a loop is being set or running.
    @ViewBuilder private var loopChip: some View {
        if let loop = playbackLoop {
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
