import SwiftUI

/// One timeline row — lyric line, instrumental stretch, or unanalyzed part —
/// drawn the same way in the sheet and the live view. Chords sit above the
/// word they start on when reliable timestamps support it; otherwise they
/// remain a single sequence. A passage's opening chord is plain chord notation,
/// using its original event for highlighting without inventing another attack.
struct ChordRowView: View {
    enum Style {
        case sheet
        case live

        var chordFont: Font {
            self == .sheet ? .system(size: 14, weight: .semibold, design: .monospaced)
                           : .system(size: 19, weight: .bold, design: .monospaced)
        }
        var wordFont: Font { wordFont(active: false) }
        /// Live: the sung line is white and bold, the others lighter grey.
        func wordFont(active: Bool) -> Font {
            // One size for every live row: the sung line is lifted by colour and a
            // small animated scale, never by a font change that reflows the words.
            self == .sheet ? .system(size: 18, design: .rounded)
                : .system(size: 24, weight: .semibold, design: .rounded)
        }
        func wordColor(active: Bool) -> Color {
            self == .sheet ? Palette.nearWhite : (active ? .white : Palette.lyricDim)
        }
        var chipPadding: (vertical: CGFloat, horizontal: CGFloat) {
            self == .sheet ? (2, 0) : (2, 0)
        }
    }

    let row: SheetModel.Row
    var transposeBy = 0
    /// Song time: highlights the sounding chord and draws the playhead on
    /// timed rows. nil in the static sheet.
    var playhead: Double? = nil
    var style: Style = .sheet
    /// Exact timestamps belong to the explicitly opened timing reference.
    var showTiming = false
    var onChordTap: ((String) -> Void)? = nil
    var onLyricTap: (() -> Void)? = nil
    /// Practice: live verdict for the chord starting at this chart second.
    var verdict: ((Double) -> PracticeFeedback.Verdict?)? = nil

    private var rtl: Bool { row.text.isRTLText }
    private var independentChanges: Bool { row.needsChordSequence }

    var body: some View {
        VStack(alignment: rtl ? .trailing : .leading, spacing: style == .sheet ? 4 : 6) {
            if !row.text.isEmpty {
                if independentChanges {
                    timedRow
                }
                ChordLyricLine(text: row.text, chords: independentChanges ? [] : row.displayChords, words: row.words?.map(\.text), transposeBy: transposeBy,
                               playhead: playhead, style: style,
                               onChordTap: onChordTap, onLyricTap: onLyricTap, verdict: changeVerdict)
                    .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            } else {
                if showTiming {
                    Text("Chords · \(Self.span(row))")
                        .font(.caption).foregroundStyle(Palette.secondary)
                }
                timedRow
            }
        }
        .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
    }

    /// A compact flow with only the sounding chord highlighted.
    private var timedRow: some View {
        ChordLyricFlow(spacing: style == .sheet ? 14 : 22) {
            ForEach(row.displayChords) { placed in
                VStack(alignment: .leading, spacing: 2) {
                    ChordChip(name: placed.event.display(transposedBy: transposeBy),
                              active: playhead.map(placed.event.contains) ?? false,
                              style: style, playing: playhead != nil, onTap: onChordTap, verdict: changeVerdict(placed.event.start))
                    if showTiming {
                        Text(Self.timestamp(placed.event.start))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: style == .sheet ? 22 : 30, alignment: rtl ? .trailing : .leading)
        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
    }

    private func changeVerdict(_ start: Double) -> PracticeFeedback.Verdict? {
        row.chords.contains { $0.event.start == start } ? verdict?(start) : nil
    }

    static func span(_ row: SheetModel.Row) -> String {
        "\(mmss(row.start))–\(mmss(row.end))"
    }

    static func timestamp(_ time: Double) -> String {
        let hundredths = Int((max(0, time) * 100).rounded())
        return String(format: "%d:%02d.%02d", hundredths / 6000, (hundredths / 100) % 60, hundredths % 100)
    }
}

/// Chord guidance for untimed lyrics. This follows only measured chord events;
/// it has no relationship to the estimated line positions or diagram toggle.
struct IndependentChordSummary: View {
    let events: [SheetModel.Event]
    let position: Double?
    var transposeBy = 0
    var onChordTap: ((String) -> Void)? = nil

    var body: some View {
        let current = position.flatMap { SheetModel.activeEvent(events, at: $0) }
        let next = position.map { SheetModel.nextEvent(events, after: $0) }
            ?? events.first { $0.chord != nil }
        HStack(spacing: 24) {
            if let current {
                item("Playing", event: current, active: true)
            }
            if let next, position != nil {
                item("Next", event: next, active: false)
            }
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("independent-chord-summary")
    }

    private func item(_ title: String, event: SheetModel.Event, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(Palette.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ChordChip(name: event.display(transposedBy: transposeBy), active: active,
                          style: .live, playing: position != nil, onTap: onChordTap)
                Text(ChordRowView.timestamp(event.start))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondary)
            }
        }
    }
}

/// One chord label; lit while it is the sounding chord in the live view.
struct ChordChip: View {
    let name: String
    var active = false
    var style: ChordRowView.Style = .sheet
    /// The song is playing: chords not sounding sit back so the one that is stands out.
    var playing = false
    var onTap: ((String) -> Void)? = nil
    /// Practice: what the microphone made of this chord, as a corner dot.
    var verdict: PracticeFeedback.Verdict? = nil

    private var verdictColor: Color? {
        switch verdict {
        case .none: return nil
        case .hit(let offset): return abs(offset) <= PracticeFeedback.onTimeTolerance ? Palette.successCheck : Palette.warning
        case .wrong: return Palette.destructive
        case .held: return Palette.successCheck.opacity(0.5)
        }
    }

    var body: some View {
        Button {
            onTap?(name)
        } label: {
            // Plain text, as on a printed chart: the sounding chord is bright,
            // the others sit back; no boxes.
            Text(name)
                .font(style.chordFont)
                .foregroundStyle(active || !(playing || style == .live) ? Color.spotifyGreen : Color.spotifyGreen.opacity(0.55))
                .padding(.vertical, style.chipPadding.vertical)
                .padding(.horizontal, style.chipPadding.horizontal)
                .overlay(alignment: .topTrailing) {
                    if let verdictColor {
                        Circle().fill(verdictColor).frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                            .offset(x: 3, y: -3)
                            .accessibilityLabel(verdict.map { String(describing: $0) } ?? "")
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
    }
}

/// Places each subview at `Position` × row width, pushing later chips right
/// when they would overlap and wrapping when the row is full. Mirrors under a
/// right-to-left layout direction.
struct TimedRowLayout: Layout {
    struct Position: LayoutValueKey {
        static let defaultValue: Double = 0
    }

    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        return CGSize(width: width, height: arrange(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let mirrored = subviews.layoutDirection == .rightToLeft
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            let x = mirrored ? bounds.width - frame.minX - frame.width : frame.minX
            subviews[index].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + frame.minY),
                                  proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (height: CGFloat, frames: [CGRect]) {
        var frames: [CGRect] = []
        var cursorX: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let desired = CGFloat(subview[Position.self]) * max(0, width - size.width)
            var x = max(desired, cursorX)
            if x + size.width > width, cursorX > 0 {
                y += rowHeight + spacing
                rowHeight = 0
                cursorX = 0
                x = min(desired, max(0, width - size.width))
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            cursorX = x + size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (y + rowHeight, frames)
    }
}
