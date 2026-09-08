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
    @State private var showSongMap = false
    private var beatGrid: BeatGrid? { store.beatGrid }
    /// The strip of chord fingerings above the words; a bottom-bar toggle.
    @AppStorage("chordRail") private var showRail = false

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
                        if let grid = beatGrid, !grid.bars.isEmpty, onSeek != nil {
                            HeaderCircle(icon: "map", on: false, label: "Song map and bar selection", identifier: "song-map") {
                                showSongMap = true
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
                                           Task { seekDenied = !(await onSeek(store.timing.spotifyTime(row.start))) }
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
                    }
                    .padding(.horizontal, 20).padding(.bottom, 24)
                }
                .onChange(of: wordPosition) { _, value in
                    lastPosition = value
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .sheet(isPresented: $showSongMap) {
            if let grid = beatGrid, let onSeek {
                SongMapSheet(grid: grid, position: lastPosition, onJump: { time in
                    Task { seekDenied = !(await onSeek(store.timing.spotifyTime(time))) }
                })
            }
        }
        .chordDiagram($selectedChord)
        .observes(store)
    }
}
