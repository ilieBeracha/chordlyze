import SwiftUI

/// Follow-along mode: lyrics + chords auto-scroll in sync with the song playing
/// in the room, using the live position from the session's Shazam match.
struct LiveNowView: View {
    @ObservedObject var session: AutoSession
    let entry: AutoSession.Entry
    let analysis: ChordAnalysis

    @State private var position: Double = 0
    private let clock = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Circle().fill(Color.spotifyGreen).frame(width: 8, height: 8)
                        Text("LIVE — \(timestamp(position))")
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundStyle(Color.spotifyGreen)
                        Spacer()
                        Text(entry.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ChordSheetView(analysis: analysis, title: entry.title,
                                   artist: entry.artist, currentTime: position)
                }
                .padding()
            }
            .onReceive(clock) { _ in
                guard let live = session.livePosition(for: entry.id) else { return }
                position = live
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(anchorLineID(for: live), anchor: .center)
                }
            }
        }
        .navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @State private var lineStarts: [Double] = []

    /// Nearest lyric-line id at or before the live position (ids are line start times).
    private func anchorLineID(for time: Double) -> Double? {
        nearestLineStart(time)
    }

    private func nearestLineStart(_ time: Double) -> Double? {
        // Lazily fetch line starts from the lyrics cache via the shared endpoint.
        if lineStarts.isEmpty {
            Task { @MainActor in
                if let lines = await BackendClient.lyrics(title: entry.title, artist: entry.artist) {
                    lineStarts = lines.map(\.time)
                }
            }
            return nil
        }
        return lineStarts.last(where: { $0 <= time })
    }

    private func timestamp(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(max(0, seconds)) / 60, Int(max(0, seconds)) % 60)
    }
}
