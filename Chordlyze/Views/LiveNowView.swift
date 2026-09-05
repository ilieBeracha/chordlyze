import SwiftUI

/// Live uses exactly the sheet's rows. A view-owned TimelineView drives the
/// playhead; no shared timer can disconnect when another screen disappears.
struct LiveNowView: View {
    @ObservedObject var store: SongSheetStore
    var onSeek: ((Double) async -> Bool)? = nil
    var playbackNote: String? = nil
    let livePosition: () -> TimeInterval?
    @State private var lastPosition: Double = 0
    @State private var selectedChord: SelectedChord?
    @State private var seekDenied = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollViewReader { proxy in
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let duration = store.song.duration ?? store.analysis?.coverageEnd ?? 0
                let position = max(0, min(livePosition() ?? lastPosition, duration > 0 ? duration : .infinity))
                let activeID = SheetModel.activeRow(store.rows, at: position)?.id
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        BackCircle(size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.song.title).font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(.white).lineLimit(1)
                            Text(store.song.artist).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    VStack(alignment: .leading, spacing: 8) {
                        if let playbackNote {
                            Text(playbackNote).font(.system(size: 13)).foregroundStyle(Palette.secondary)
                        }
                        if seekDenied { Text("Spotify could not seek. Check playback permissions or Premium.").font(.caption).foregroundStyle(Palette.secondary) }
                        SongSheetStatus(store: store, pill: true)
                    }.padding(.horizontal, 20).padding(.bottom, 6)
                    ScrollView {
                        ChordSheetView(store: store, playhead: position, style: .live,
                                       onChordTap: { selectedChord = SelectedChord(name: $0) },
                                       onRowTap: { row in
                                           guard let onSeek else { return }
                                           Task { seekDenied = !(await onSeek(row.start)) }
                                       })
                            .padding(.horizontal, 24).padding(.vertical, 32)
                            .padding(.bottom, 90)
                    }
                    .onChange(of: activeID, initial: true) { _, id in
                        if let id { withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) } }
                    }
                    HStack(spacing: 12) {
                        Text(mmss(position)).font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white).accessibilityIdentifier("live-position")
                        ProgressView(value: position, total: max(1, duration)).tint(.spotifyGreen)
                        Text("Live").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.secondary)
                    }
                    .padding(.horizontal, 20).padding(.bottom, 24)
                }
                .onChange(of: position) { _, value in lastPosition = value }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $selectedChord) { ChordDiagramSheet(chord: $0.name) }
        .task(id: scenePhase) {
            if scenePhase == .active { await store.observe() }
        }
    }
}
