import SwiftUI

/// Live uses exactly the sheet's rows. A view-owned TimelineView drives the
/// playhead; no shared timer can disconnect when another screen disappears.
struct LiveNowView: View {
    @ObservedObject var store: SongSheetStore
    var onSeek: ((Double) async -> Bool)? = nil
    var playbackNote: String? = nil
    var verdict: ((Double) -> PracticeFeedback.Verdict?)? = nil
    /// Calibrated chart time, no display lead: the caller has already put
    /// Spotify's position (or the take clock) through the song's timing map.
    let chartPosition: () -> TimeInterval?
    /// Seconds the highlight runs ahead of Spotify audio. Recognized chord
    /// boundaries land a little late and players read ahead of the beat.
    @AppStorage("chordLead") private var lead = 0.0
    @State private var lastPosition: Double = 0
    @State private var selectedChord: SelectedChord?
    @State private var seekDenied = false
    /// A–B repeat: when the song reaches the end, Spotify is sent back to the
    /// start. The range lives on the store; only the arming is view state.
    @State private var loopStart: Double?
    @State private var loopArmed = true
    /// The strip of chord fingerings above the words; a bottom-bar toggle.
    @AppStorage("liveChordRail") private var showRail = true

    var body: some View {
        ScrollViewReader { proxy in
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let duration = store.song.duration ?? store.analysis?.coverageEnd ?? 0
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
                        if onSeek != nil {
                            HeaderCircle(icon: "repeat", on: store.loop != nil || loopStart != nil,
                                         label: store.loop != nil ? "Clear loop" : loopStart == nil ? "Loop from here" : "Loop until here",
                                         identifier: store.loop != nil ? "loop-active" : "loop-start") {
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
                    if seekDenied {
                        Text("Spotify could not seek. Check playback permissions or Premium.").font(.caption)
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
                                           Task { seekDenied = !(await onSeek(store.timing.spotifyTime(row.start))) }
                                       }, onLoopRow: onSeek == nil ? nil : { row in
                                           store.loop = row.start...max(row.start + 1, row.end); loopStart = nil; loopArmed = true
                                       }, verdict: verdict, wordPlayhead: wordPosition)
                            .padding(.horizontal, 24).padding(.top, 40)
                            .padding(.bottom, 320)  // the last lines can roll up to the reading height too
                    }
                    .onChange(of: activeID, initial: true) { _, id in
                        // The line being sung settles a third of the way down, so what
                        // comes next is already in view; the roll is slow enough to follow.
                        if let id { withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.32)) } }
                    }
                    HStack(spacing: 12) {
                        Text(mmss(position)).font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white).accessibilityIdentifier("live-position")
                        ProgressView(value: position, total: max(1, duration)).tint(.spotifyGreen)
                        loopChip
                    }
                    .padding(.horizontal, 20).padding(.bottom, 24)
                }
                .onChange(of: wordPosition) { _, value in
                    lastPosition = value
                    // Back to the start once per pass; re-arm after the jump lands.
                    if let loop = store.loop, let onSeek {
                        if value >= loop.upperBound, loopArmed {
                            loopArmed = false
                            Task { seekDenied = !(await onSeek(store.timing.spotifyTime(loop.lowerBound))) }
                        } else if value < loop.upperBound - 1 {
                            loopArmed = true
                        }
                    }
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .chordDiagram($selectedChord)
        .observes(store)
    }

    /// The loop circle in the header: first tap marks A, the second marks B
    /// and starts the loop, a tap on a running loop clears it. Long-pressing
    /// a line loops that line directly.
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

    /// Under the progress line, only while a loop is being set or running.
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
