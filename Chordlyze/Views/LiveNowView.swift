import SwiftUI

/// Teleprompter follow-along: current lyric centered with its chords, context
/// lines dimmed above/below, progress rail at the bottom. Repeated chords are
/// collapsed into one chip with a ×N badge.
struct LiveNowView: View {
    let title: String
    let artist: String
    let analysis: ChordAnalysis
    /// Live playback position source (Spotify poll or mic session anchor).
    let livePosition: () -> TimeInterval?

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
                chordFollow
            } else if lines.isEmpty {
                ProgressView()
            } else {
                teleprompter
            }

            Spacer()

            progressRail
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 34)
        .background(backdrop)
        .toolbar(.hidden, for: .navigationBar)
        .onReceive(clock) { _ in
            if let live = livePosition() {
                withAnimation(.easeInOut(duration: 0.35)) { position = live }
            }
        }
        .task {
            if let lyricLines = await BackendClient.lyrics(title: title, artist: artist) {
                lines = SheetModel.build(analysis: analysis, lines: lyricLines)
            } else {
                noLyrics = true
            }
        }
    }

    // MARK: - Chrome

    private var backdrop: some View {
        ZStack {
            Color.black
            RadialGradient(colors: [Color.spotifyGreen.opacity(0.10), .clear],
                           center: .top, startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 12) {
            BackCircle(size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(artist.uppercased())
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let key = analysis.key {
                Text(key)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(Capsule().fill(Palette.elevated))
            }
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

    private var progressRail: some View {
        HStack(spacing: 10) {
            Text(timestamp(position))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.spotifyGreen)
            GeometryReader { geo in
                let fraction = min(1, max(0, position / duration))
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.elevated).frame(height: 4)
                    Capsule()
                        .fill(Color.spotifyGreen)
                        .frame(width: geo.size.width * fraction, height: 4)
                    Circle()
                        .fill(Color.spotifyGreen)
                        .frame(width: 9, height: 9)
                        .shadow(color: Color.spotifyGreen.opacity(0.7), radius: 5)
                        .offset(x: min(geo.size.width - 9, max(0, geo.size.width * fraction - 4.5)))
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 9)
            Text(timestamp(duration))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Palette.secondary)
        }
    }

    // MARK: - Teleprompter

    private var teleprompter: some View {
        let index = currentIndex ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            // 2 previous lines, fading out upward
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(lines[max(0, index - 2)..<index].enumerated()), id: \.element.id) { offset, line in
                    Text(line.text)
                        .font(.system(size: 17, design: .rounded))
                        .foregroundStyle(Palette.secondary)
                        .opacity(offset == 0 && index >= 2 ? 0.22 : 0.4)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity,
                               alignment: line.text.isRTLText ? .trailing : .leading)
                }
            }

            // Current block
            if index < lines.count {
                let current = lines[index]
                let rtl = current.text.isRTLText
                Group {
                    if rtl {
                        // Word-level pinning is ambiguous in RTL — keep chips above the line.
                        VStack(alignment: .trailing, spacing: 14) {
                            if !current.chords.isEmpty {
                                HStack(spacing: 8) {
                                    ForEach(grouped(current.chords)) { group in
                                        chordChip(group)
                                    }
                                }
                                .environment(\.layoutDirection, .rightToLeft)
                            }
                            Text(current.text)
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .lineSpacing(30 * 0.22)
                                .multilineTextAlignment(.trailing)
                        }
                    } else {
                        // Each chord pinned above the word it lands on.
                        ChordLyricLine(text: current.text, chords: current.chords)
                    }
                }
                .id(current.id)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
                .padding(.vertical, 26)
            }

            // 3 next lines
            VStack(alignment: .leading, spacing: 16) {
                ForEach(lines[min(lines.count, index + 1)..<min(lines.count, index + 4)]) { line in
                    VStack(alignment: line.text.isRTLText ? .trailing : .leading, spacing: 3) {
                        if !line.chords.isEmpty {
                            Text(summary(line.chords))
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

    private func chordChip(_ group: ChordGroup) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(group.name)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
            if group.count > 1 {
                Text("×\(group.count)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .opacity(0.75)
            }
        }
        .foregroundStyle(Color.spotifyGreen)
        .padding(.vertical, 9)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(group.estimated ? Color.clear : Palette.greenTintFill)
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Palette.greenTintBorder,
                            style: StrokeStyle(lineWidth: 1, dash: group.estimated ? [4, 3] : [])))
        )
        .opacity(group.estimated ? 0.8 : 1)
    }

    // MARK: - Chord-only follow (no synced lyrics)

    private var chordFollow: some View {
        let real = analysis.chords.filter { $0.label != "N" }
        let index = real.lastIndex(where: { $0.start <= position })
        let current = index.map { real[$0] }
        let upcoming = index.map { Array(real[min(real.count, $0 + 1)..<min(real.count, $0 + 4)]) }
            ?? Array(real.prefix(3))
        return VStack(spacing: 30) {
            Text("No synced lyrics — follow the chords.")
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondary)
            Text(current?.displayName ?? "…")
                .font(.system(size: 64, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.spotifyGreen)
                .padding(.vertical, 24)
                .padding(.horizontal, 44)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Palette.greenTintFill)
                        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Palette.greenTintBorder, lineWidth: 1))
                )
                .animation(.easeInOut(duration: 0.2), value: current?.id)
            if !upcoming.isEmpty {
                HStack(spacing: 12) {
                    Text("NEXT")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(Palette.tertiary)
                    ForEach(upcoming) { chord in
                        Text(chord.displayName)
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(Palette.secondaryAlt)
                    }
                }
            }
        }
    }

    // MARK: - Chord grouping

    private struct ChordGroup: Identifiable {
        let id = UUID()
        let name: String
        let count: Int
        let estimated: Bool
    }

    /// Collapse consecutive repeats: [C#m, C#m, B] -> [C#m ×2, B].
    private func grouped(_ chords: [SheetModel.PlacedChord]) -> [ChordGroup] {
        var out: [ChordGroup] = []
        for chord in chords {
            if let last = out.last, last.name == chord.name, last.estimated == chord.estimated {
                out[out.count - 1] = ChordGroup(name: last.name, count: last.count + 1,
                                                estimated: last.estimated)
            } else {
                out.append(ChordGroup(name: chord.name, count: 1, estimated: chord.estimated))
            }
        }
        return out
    }

    private func summary(_ chords: [SheetModel.PlacedChord]) -> String {
        grouped(chords)
            .map { $0.count > 1 ? "\($0.name) ×\($0.count)" : $0.name }
            .joined(separator: "   ")
    }

    private func timestamp(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(max(0, seconds)) / 60, Int(max(0, seconds)) % 60)
    }
}
