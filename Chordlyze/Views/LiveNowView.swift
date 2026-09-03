import SwiftUI

/// Teleprompter follow-along: the current timeline row centered with its
/// chords (the sounding one highlighted), context rows dimmed above/below,
/// progress rail at the bottom. Rows come from SheetModel, shared with the
/// sheet; chords are resolved from song time, never from the lyrics.
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
    @State private var rows: [SheetModel.Row] = []
    @State private var lyricLines: [LyricLine] = []
    @State private var noLyrics = false
    @State private var selectedChord: SelectedChord?
    @State private var seekDenied = false
    @State private var lyricsNote: String?
    /// Roughly-timed lyrics (synthesized): line taps re-anchor instead of seek.
    @State private var resyncable = false
    /// User correction on the synthesized lyric timeline ("this line is now").
    /// Moves the lyrics onto song time; the chords never move.
    @State private var lyricsOffset: Double = 0

    struct SelectedChord: Identifiable {
        let name: String
        var id: String { name }
    }
    /// Static: an instance timer is recreated (and its countdown reset) every
    /// time the parent re-renders, which in practice mode is every second.
    /// 100 ms ticks keep the display within one decoder frame of the clock.
    private static let clock = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    private var currentIndex: Int? {
        rows.lastIndex(where: { $0.start <= position })
    }
    private var duration: Double {
        trackDuration ?? max(rows.last?.end ?? 0, analysis.coverageEnd, 1)
    }
    /// What the chords do and do not cover, said up front instead of guessed past.
    private var coverageNote: String? {
        if analysis.isPreview {
            return "Chords from a 30-second preview — not synced to this playback."
        }
        if let trackDuration, analysis.coverageEnd + 5 < trackDuration {
            return "Chords analyzed up to \(timestamp(analysis.coverageEnd)); the rest of the song has none."
        }
        return nil
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
            if let coverageNote {
                Text(coverageNote)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
            if analysis.isPreview {
                previewChords
                    .padding(.top, 10)
            }

            Spacer()

            if noLyrics {
                chordFollow
            } else if rows.isEmpty {
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
            guard let live = livePosition() else { return }
            // Animate only when the current row changes; the position itself
            // must not lag behind the clock.
            let next = rows.lastIndex(where: { $0.start <= live })
            if next != currentIndex {
                withAnimation(.easeInOut(duration: 0.35)) { position = live }
            } else {
                position = live
            }
        }
        .onChange(of: lyricsOffset) { _, _ in rebuildRows() }
        .sheet(item: $selectedChord) { selected in
            ChordDiagramSheet(chord: selected.name)
        }
        .task {
            guard let result = await BackendClient.lyrics(title: title, artist: artist,
                                                          duration: trackDuration, album: album) else {
                noLyrics = true
                return
            }
            lyricLines = result.lines
            rebuildRows()
            if result.synced {
                lyricsNote = result.betaNote
            } else {
                // Synthesized timing drifts — the user re-anchors by tapping.
                resyncable = true
                lyricsNote = "lyrics roughly timed — tap the sung line to sync · beta"
            }
        }
    }

    /// Rows on song time: a resync shifts the lyric lines onto it, so the
    /// chords stay where the audio put them.
    private func rebuildRows() {
        let shifted = lyricLines.map { line in
            LyricLine(time: line.time - lyricsOffset, text: line.text,
                      words: line.words?.map { WordStamp(time: $0.time - lyricsOffset, text: $0.text) })
        }
        rows = SheetModel.build(analysis: analysis, lines: shifted, duration: trackDuration)
    }

    /// Tap a context row: on rough timing it re-anchors the lyrics ("this
    /// line is now"); on real sync it jumps playback there.
    private func lineTapped(_ row: SheetModel.Row) {
        if resyncable {
            // The row sits at lyric time (row.start + lyricsOffset); make that "now".
            withAnimation(.easeInOut(duration: 0.35)) { lyricsOffset = row.start + lyricsOffset - position }
            return
        }
        guard let onSeek else { return }
        Task {
            if await onSeek(row.start) {
                seekDenied = false
                withAnimation(.easeInOut(duration: 0.35)) { position = row.start }
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
            // 2 previous rows, fading out upward; tap to jump back
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(rows[max(0, index - 2)..<index].enumerated()), id: \.element.id) { offset, row in
                    Button { lineTapped(row) } label: {
                        Text(contextText(row))
                            .font(.system(size: 17, design: .rounded))
                            .foregroundStyle(Palette.secondary)
                            .opacity(offset == 0 && index >= 2 ? 0.22 : 0.4)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity,
                                   alignment: row.text.isRTLText ? .trailing : .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(!resyncable && onSeek == nil)
                }
            }

            // Current row
            if index < rows.count {
                let current = rows[index]
                VStack(alignment: current.text.isRTLText ? .trailing : .leading, spacing: 12) {
                    ChordRowView(row: current, playhead: position, style: .live,
                                 onChordTap: { selectedChord = SelectedChord(name: $0) })
                    if current.isInstrumental {
                        let left = max(0, Int((current.end - position).rounded(.up)))
                        if left > 0, left <= 30, index + 1 < rows.count, !rows[index + 1].text.isEmpty {
                            Text("lyrics in \(left)s")
                                .font(.system(size: 14, design: .rounded))
                                .foregroundStyle(Palette.secondary)
                        }
                    }
                }
                .id(current.id)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .frame(maxWidth: .infinity, alignment: current.text.isRTLText ? .trailing : .leading)
                .padding(.vertical, 26)
            }

            // 3 next rows; tap to jump ahead
            VStack(alignment: .leading, spacing: 16) {
                ForEach(rows[min(rows.count, index + 1)..<min(rows.count, index + 4)]) { row in
                    Button { lineTapped(row) } label: {
                        VStack(alignment: row.text.isRTLText ? .trailing : .leading, spacing: 3) {
                            if !row.chords.isEmpty {
                                Text(summary(row.chords))
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .tracking(0.8)
                                    .foregroundStyle(Palette.faint)
                            }
                            Text(contextText(row))
                                .font(.system(size: 18, design: .rounded))
                                .foregroundStyle(Palette.secondaryAlt)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity,
                               alignment: row.text.isRTLText ? .trailing : .leading)
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

    /// One-line stand-in for a row in the dimmed context lists.
    private func contextText(_ row: SheetModel.Row) -> String {
        if !row.text.isEmpty { return row.text }
        switch row.kind {
        case .instrumental: return "♪ Instrumental \(ChordRowView.span(row))"
        case .uncovered: return "? Not analyzed \(ChordRowView.span(row))"
        case .lyric: return "… \(ChordRowView.span(row))"
        }
    }

    // MARK: - Preview excerpt (chords known, position in the song unknown)

    /// The excerpt's progression as a static strip: what the song plays,
    /// without pretending to know when.
    private var previewChords: some View {
        var loop: [String] = []
        for seg in analysis.chords where seg.label != "N" && loop.last != seg.displayName {
            if loop.count == 8 { break }
            loop.append(seg.displayName)
        }
        return FlowLayout(spacing: 6) {
            ForEach(Array(loop.enumerated()), id: \.offset) { _, name in
                ChordChip(name: name, style: .sheet) { selectedChord = SelectedChord(name: $0) }
            }
        }
    }

    // MARK: - Chord-only follow (no synced lyrics)

    private var chordFollow: some View {
        let events = SheetModel.events(analysis)
        let covered = !analysis.isPreview && position < analysis.coverageEnd
        let current = covered ? SheetModel.activeEvent(events, at: position) : nil
        let upcoming: [SheetModel.Event] = {
            guard covered else { return [] }
            let after = events.filter { $0.start > position && $0.chord != nil }
            return Array(after.prefix(3))
        }()
        return VStack(spacing: 30) {
            Text(analysis.isPreview ? "No synced lyrics."
                 : covered ? "No synced lyrics — follow the chords."
                 : "Past the analyzed part of the song.")
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondary)
            if !analysis.isPreview {
                Button {
                    if let current { selectedChord = SelectedChord(name: current.display(transposedBy: 0)) }
                } label: {
                    Text(current?.display(transposedBy: 0) ?? (covered ? "…" : "—"))
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
            }
            if !upcoming.isEmpty {
                HStack(spacing: 12) {
                    Text("NEXT")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(Palette.tertiary)
                    ForEach(upcoming) { event in
                        Text(event.display(transposedBy: 0))
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(Palette.secondaryAlt)
                    }
                }
            }
        }
    }

    /// "C#m ×2   B" for the dimmed upcoming rows.
    private func summary(_ chords: [SheetModel.Placed]) -> String {
        var out: [(name: String, count: Int)] = []
        for placed in chords {
            let name = placed.event.display(transposedBy: 0)
            if let last = out.last, last.name == name {
                out[out.count - 1].count += 1
            } else {
                out.append((name, 1))
            }
        }
        return out.map { $0.count > 1 ? "\($0.name) ×\($0.count)" : $0.name }
            .joined(separator: "   ")
    }

    private func timestamp(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(max(0, seconds)) / 60, Int(max(0, seconds)) % 60)
    }
}
