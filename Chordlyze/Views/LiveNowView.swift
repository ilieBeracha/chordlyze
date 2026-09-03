import SwiftUI

/// Teleprompter follow-along: current lyric centered with its chords, context
/// lines dimmed above/below, progress rail at the bottom. Repeated chords are
/// collapsed into one chip with a ×N badge.
struct LiveNowView: View {
    let title: String
    let artist: String
    let analysis: ChordAnalysis
    /// Full song length when known (Spotify); analysis may cover only an excerpt.
    var trackDuration: TimeInterval? = nil
    /// Album name, used to match the exact lyrics version.
    var album: String? = nil
    /// Jump playback to a time; false when the player refuses (e.g. no Premium).
    var onSeek: ((Double) async -> Bool)? = nil
    /// Live playback position source (Spotify poll or mic session anchor).
    let livePosition: () -> TimeInterval?

    @State private var position: Double = 0
    @State private var lines: [SheetModel.RenderLine] = []
    @State private var noLyrics = false
    @State private var selectedChord: SelectedChord?
    @State private var seekDenied = false
    @State private var lyricsNote: String?
    /// Roughly-timed lyrics (synthesized): line taps re-anchor instead of seek.
    @State private var resyncable = false
    /// User correction on the synthesized lyric timeline ("this line is now").
    @State private var lyricsOffset: Double = 0

    struct SelectedChord: Identifiable {
        let name: String
        var id: String { name }
    }
    /// Static: an instance timer is recreated (and its countdown reset) every
    /// time the parent re-renders, which in practice mode is every 0.5 s.
    private static let clock = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    /// Position on the lyric timeline (song position plus manual re-anchor).
    private var lyricPosition: Double { position + lyricsOffset }
    private var currentIndex: Int? {
        lines.lastIndex(where: { $0.id <= lyricPosition })
    }
    private var duration: Double {
        trackDuration ?? max(lines.last?.end ?? 0, analysis.chords.last?.end ?? 0, 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let lyricsNote {
                Text(lyricsNote)
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.faint)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 6)
            }

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
        .onReceive(Self.clock) { _ in
            if let live = livePosition() {
                withAnimation(.easeInOut(duration: 0.35)) { position = live }
            }
        }
        .sheet(item: $selectedChord) { selected in
            ChordDiagramSheet(chord: selected.name)
        }
        .task {
            guard let result = await BackendClient.lyrics(title: title, artist: artist,
                                                          duration: trackDuration, album: album) else {
                noLyrics = true
                return
            }
            lines = SheetModel.build(analysis: analysis, lines: result.lines)
            if result.synced {
                lyricsNote = result.betaNote
            } else {
                // Synthesized timing drifts — the user re-anchors by tapping.
                resyncable = true
                lyricsNote = "lyrics roughly timed — tap the sung line to sync · beta"
            }
        }
    }

    /// Tap a context line: on rough timing it re-anchors the lyrics ("this
    /// line is now"); on real sync it jumps playback there.
    private func lineTapped(_ time: Double) {
        if resyncable {
            withAnimation(.easeInOut(duration: 0.35)) { lyricsOffset = time - position }
            return
        }
        guard let onSeek else { return }
        Task {
            if await onSeek(time) {
                seekDenied = false
                withAnimation(.easeInOut(duration: 0.35)) { position = time }
            } else {
                seekDenied = true
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
            // 2 previous lines, fading out upward; tap to jump back
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(lines[max(0, index - 2)..<index].enumerated()), id: \.element.id) { offset, line in
                    Button { lineTapped(line.id) } label: {
                        Text(line.text)
                            .font(.system(size: 17, design: .rounded))
                            .foregroundStyle(Palette.secondary)
                            .opacity(offset == 0 && index >= 2 ? 0.22 : 0.4)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity,
                                   alignment: line.text.isRTLText ? .trailing : .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(!resyncable && onSeek == nil)
                }
            }

            // Current block
            if index < lines.count {
                let current = lines[index]
                let rtl = current.text.isRTLText
                Group {
                    if current.isInstrumental {
                        VStack(alignment: .leading, spacing: 16) {
                            if !current.chords.isEmpty {
                                FlowLayout(spacing: 8) {  // wraps: long breaks carry many chords
                                    ForEach(grouped(current.chords)) { group in
                                        chordChip(group)
                                    }
                                }
                            }
                            HStack(spacing: 8) {
                                Image(systemName: "music.quarternote.3")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Instrumental")
                                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                                let left = max(0, Int((current.end - lyricPosition).rounded(.up)))
                                if left > 0, left <= 30 {
                                    Text("· lyrics in \(left)s")
                                        .font(.system(size: 14, design: .rounded))
                                        .foregroundStyle(Palette.secondary)
                                }
                            }
                            .foregroundStyle(Palette.secondaryAlt)
                        }
                    } else if rtl {
                        // Word-level pinning is ambiguous in RTL — keep chips above the line.
                        VStack(alignment: .trailing, spacing: 14) {
                            if !current.chords.isEmpty {
                                FlowLayout(spacing: 8) {
                                    ForEach(grouped(current.chords).reversed()) { group in
                                        chordChip(group)
                                    }
                                }
                            }
                            Text(current.text)
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .lineSpacing(30 * 0.22)
                                .multilineTextAlignment(.trailing)
                        }
                    } else {
                        // Each chord pinned above the word it lands on.
                        ChordLyricLine(text: current.text, chords: current.chords,
                                       onChordTap: { selectedChord = SelectedChord(name: $0) })
                    }
                }
                .id(current.id)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
                .padding(.vertical, 26)
            }

            // 3 next lines; tap to jump ahead
            VStack(alignment: .leading, spacing: 16) {
                ForEach(lines[min(lines.count, index + 1)..<min(lines.count, index + 4)]) { line in
                    Button { lineTapped(line.id) } label: {
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
                    .buttonStyle(.plain)
                    .disabled(!resyncable && onSeek == nil)
                }
            }
            if seekDenied {
                Text("Jumping needs Spotify Premium.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.tertiary)
                    .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chordChip(_ group: ChordGroup) -> some View {
        Button {
            selectedChord = SelectedChord(name: group.name)
        } label: {
            chipLabel(group)
        }
        .buttonStyle(.plain)
    }

    private func chipLabel(_ group: ChordGroup) -> some View {
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
        let span = real.last?.end ?? 0
        // Analysis may cover only an excerpt (e.g. 30s preview): once playback
        // passes the analyzed window, loop the progression as an estimate.
        let looped = span > 0 && position >= span
        let t = looped ? position.truncatingRemainder(dividingBy: span) : position
        let index = real.lastIndex(where: { $0.start <= t })
        let current = index.map { real[$0] }
        let upcoming: [ChordSegment] = {
            guard let index, !real.isEmpty else { return Array(real.prefix(3)) }
            return (1...3).compactMap { step in
                let next = index + step
                if next < real.count { return real[next] }
                return looped ? real[next % real.count] : nil
            }
        }()
        return VStack(spacing: 30) {
            Text(looped ? "No synced lyrics — progression loops (estimate)."
                        : "No synced lyrics — follow the chords.")
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondary)
            Button {
                if let current { selectedChord = SelectedChord(name: current.displayName) }
            } label: {
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
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.2), value: current?.id)
            if !upcoming.isEmpty {
                HStack(spacing: 12) {
                    Text("NEXT")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(Palette.tertiary)
                    // Positional ids: looping can repeat the same segment.
                    ForEach(Array(upcoming.enumerated()), id: \.offset) { _, chord in
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
