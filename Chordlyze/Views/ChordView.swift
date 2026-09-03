import SwiftUI

/// Track screen: the analysis (saved, or fresh from the iTunes preview) as
/// the chord sheet; a placeholder until it arrives or when the song is
/// found nowhere.
struct ChordView: View {
    let track: Track
    @State private var analysis: ChordAnalysis?
    @State private var failure: String?

    var body: some View {
        Group {
            if let analysis {
                AnalysisTabsView(analysis: analysis, title: track.name, artist: track.artistNames,
                                 album: track.album.name, trackID: track.id,
                                 trackDuration: track.durationMs.map { Double($0) / 1000 })
            } else {
                WaitingView(title: track.name, subtitle: track.artistNames.uppercased(),
                            message: failure ?? "Analyzing chords…", spinning: failure == nil)
            }
        }
        .task {
            do {
                analysis = try await BackendClient.retrying { try await BackendClient.analyzeTrack(track) }
                if analysis == nil { failure = "Chords unavailable for this song." }
            } catch {
                failure = "Couldn't reach the chord service: \(error.localizedDescription)"
            }
        }
    }
}

/// Key + song map + progression + timeline (design 2e).
struct AnalysisResultView: View {
    let analysis: ChordAnalysis
    var transposeBy: Int = 0
    var onChordTap: ((String) -> Void)? = nil

    private func show(_ name: String) -> String {
        ChordMath.transpose(name, by: transposeBy)
    }

    private var timeline: [ChordSegment] {
        analysis.chords.filter { $0.label != "N" }
    }
    private var totalDuration: Double {
        analysis.chords.last?.end ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let key = analysis.key {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(key)
                        .font(.system(size: 46, weight: .heavy, design: .rounded))
                        .tracking(-1)
                        .foregroundStyle(.white)
                    if let conf = analysis.keyConfidence {
                        Text("\(Int(conf * 100))% fit")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.spotifyGreen)
                            .padding(.vertical, 4).padding(.horizontal, 10)
                            .background(Capsule().fill(Palette.greenTintFill))
                    }
                }
            }

            songMap
                .padding(.top, 18)
                .padding(.bottom, 28)

            SectionLabel("Progression")
                .padding(.bottom, 10)
            FlowLayout(spacing: 6) {
                let loop = progressionLoop()
                ForEach(Array(loop.enumerated()), id: \.offset) { index, seg in
                    if index > 0 {
                        Text("›")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: 0x3A3A3C))
                    }
                    Button {
                        onChordTap?(show(seg.displayName))
                    } label: {
                        VStack(spacing: 1) {
                            Text(show(seg.displayName))
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Text(seg.roman ?? " ")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Palette.secondary)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 13)
                        .background(RoundedRectangle(cornerRadius: 11).fill(Palette.elevated))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 28)

            SectionLabel("Timeline")
                .padding(.bottom, 10)
            let maxDur = timeline.map(\.duration).max() ?? 1
            VStack(spacing: 7) {
                ForEach(timeline) { segment in
                    HStack(spacing: 10) {
                        Text(timestamp(segment.start))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.tertiary)
                            .frame(width: 36, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(hex: 0x101010))
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Palette.greenTintFill)
                                    .overlay(RoundedRectangle(cornerRadius: 8)
                                        .stroke(Palette.greenTintBorder, lineWidth: 1))
                                    .frame(width: max(30, geo.size.width * segment.duration / maxDur))
                                HStack(spacing: 6) {
                                    Text(show(segment.displayName))
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                    Text(segment.roman ?? "")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Palette.secondary)
                                }
                                .padding(.leading, 10)
                            }
                        }
                        .frame(height: 30)
                        Text(durationText(segment.duration))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.tertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var songMap: some View {
        GeometryReader { geo in
            HStack(spacing: 1.5) {
                ForEach(analysis.chords) { segment in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(segment.label == "N" ? Palette.gray5 : Color.spotifyGreen)
                        .frame(width: max(2, geo.size.width * segment.duration / totalDuration - 1.5))
                }
            }
        }
        .frame(height: 12)
    }

    private func progressionLoop() -> [ChordSegment] {
        var loop: [ChordSegment] = []
        for seg in analysis.chords where seg.label != "N" {
            if loop.last?.displayName != seg.displayName {
                loop.append(seg)
                if loop.count == 8 { break }
            }
        }
        return loop
    }

    private func timestamp(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    private func durationText(_ seconds: Double) -> String {
        seconds >= 10 ? "\(Int(seconds))s" : String(format: "%.1fs", seconds)
    }
}

/// Minimal left-aligned wrapping layout.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                                  proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y + max(0, (rowHeight - size.height) / 2)))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - spacing)
        }
        return (CGSize(width: width, height: y + rowHeight), origins)
    }
}
