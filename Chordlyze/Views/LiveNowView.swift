import SwiftUI

/// Teleprompter follow-along (design 2g): current lyric centered with its
/// chords, context lines dimmed above/below, progress rail at the bottom.
struct LiveNowView: View {
    @ObservedObject var session: AutoSession
    let entry: AutoSession.Entry
    let analysis: ChordAnalysis

    @State private var position: Double = 0
    @State private var lines: [SheetModel.RenderLine] = []
    @State private var noLyrics = false
    private let clock = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var currentIndex: Int? {
        lines.lastIndex(where: { $0.id <= position })
    }
    private var duration: Double {
        max(lines.last?.end ?? 0, analysis.chords.last?.end ?? 0, 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Spacer()

            if noLyrics {
                Text("No synced lyrics — follow the timeline instead.")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.secondary)
            } else if lines.isEmpty {
                ProgressView()
            } else {
                teleprompter
            }

            Spacer()

            // Progress rail
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Palette.elevated)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.spotifyGreen)
                        .frame(width: geo.size.width * min(1, max(0, position / duration)))
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 40)
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onReceive(clock) { _ in
            if let live = session.livePosition(for: entry.id) {
                withAnimation(.easeInOut(duration: 0.35)) { position = live }
            }
        }
        .task {
            if let lyricLines = await BackendClient.lyrics(title: entry.title, artist: entry.artist) {
                lines = SheetModel.build(analysis: analysis, lines: lyricLines)
            } else {
                noLyrics = true
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            BackCircle(size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(entry.artist.uppercased())
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(Color.spotifyGreen).frame(width: 6, height: 6)
                Text(timestamp(position))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.spotifyGreen)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(Capsule().fill(Palette.greenTintFill))
        }
    }

    private var teleprompter: some View {
        let index = currentIndex ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            // 2 previous lines
            VStack(alignment: .leading, spacing: 10) {
                ForEach(lines[max(0, index - 2)..<index]) { line in
                    Text(line.text)
                        .font(.system(size: 17, design: .rounded))
                        .foregroundStyle(Palette.secondary)
                        .opacity(0.35)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity,
                               alignment: line.text.isRTLText ? .trailing : .leading)
                }
            }

            // Current block
            if index < lines.count {
                let current = lines[index]
                let rtl = current.text.isRTLText
                VStack(alignment: rtl ? .trailing : .leading, spacing: 12) {
                    if !current.chords.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(current.chords) { chord in
                                Text(chord.name)
                                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                                    .foregroundStyle(Color.spotifyGreen)
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 16)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Palette.greenTintFill)
                                            .overlay(RoundedRectangle(cornerRadius: 12)
                                                .stroke(Palette.greenTintBorder, lineWidth: 1))
                                    )
                            }
                        }
                        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                    }
                    Text(current.text)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineSpacing(28 * 0.25)
                        .multilineTextAlignment(rtl ? .trailing : .leading)
                }
                .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
                .padding(.vertical, 26)
            }

            // 3 next lines
            VStack(alignment: .leading, spacing: 16) {
                ForEach(lines[min(lines.count, index + 1)..<min(lines.count, index + 4)]) { line in
                    VStack(alignment: line.text.isRTLText ? .trailing : .leading, spacing: 3) {
                        if !line.chords.isEmpty {
                            Text(line.chords.map(\.name).joined(separator: "   "))
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .tracking(0.8)
                                .foregroundStyle(Palette.faint)
                        }
                        Text(line.text)
                            .font(.system(size: 18, design: .rounded))
                            .foregroundStyle(Palette.secondaryAlt)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity,
                           alignment: line.text.isRTLText ? .trailing : .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timestamp(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(max(0, seconds)) / 60, Int(max(0, seconds)) % 60)
    }
}
