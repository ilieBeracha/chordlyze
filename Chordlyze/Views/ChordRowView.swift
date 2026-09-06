import SwiftUI

/// One timeline row — lyric line, instrumental stretch, or unanalyzed part —
/// drawn the same way in the sheet and the live view. Chords sit above the
/// word they start on when the lyrics carry word times; otherwise they are
/// spread across the row in proportion to time. A chord held over from the
/// previous row is not drawn again.
struct ChordRowView: View {
    enum Style {
        case sheet
        case live

        var chordFont: Font {
            self == .sheet ? .system(size: 13, weight: .bold, design: .rounded)
                           : .system(size: 16, weight: .semibold, design: .rounded)
        }
        var wordFont: Font { wordFont(active: false) }
        /// Live: the sung line is white and bold, the others lighter grey.
        func wordFont(active: Bool) -> Font {
            self == .sheet ? .system(size: 18, design: .rounded)
                : .system(size: active ? 24 : 21, weight: active ? .bold : .regular, design: .rounded)
        }
        func wordColor(active: Bool) -> Color {
            self == .sheet ? Palette.nearWhite : (active ? .white : Palette.lyricDim)
        }
        var chipPadding: (vertical: CGFloat, horizontal: CGFloat) {
            self == .sheet ? (3, 9) : (4, 10)
        }
    }

    let row: SheetModel.Row
    var transposeBy = 0
    /// Song time: highlights the sounding chord and draws the playhead on
    /// timed rows. nil in the static sheet.
    var playhead: Double? = nil
    var style: Style = .sheet
    var onChordTap: ((String) -> Void)? = nil
    var onLyricTap: (() -> Void)? = nil
    /// Practice: live verdict for the chord starting at this chart second.
    var verdict: ((Double) -> PracticeFeedback.Verdict?)? = nil
    /// Song time for the words, without the chord display lead.
    var wordPlayhead: Double? = nil

    private var rtl: Bool { row.text.isRTLText }
    private var active: Bool { playhead.map(row.contains) ?? false }

    var body: some View {
        VStack(alignment: rtl ? .trailing : .leading, spacing: style == .sheet ? 4 : 12) {
            if !row.text.isEmpty {
                ChordLyricLine(text: row.text, chords: row.chords, words: row.words?.map(\.text), transposeBy: transposeBy,
                               playhead: playhead, style: style, active: active, pending: row.chords.isEmpty && row.held == nil,
                               onChordTap: onChordTap, onLyricTap: onLyricTap, verdict: verdict,
                               rowStart: row.start, rowEnd: row.end, wordTimes: row.words?.map(\.time),
                               wordPlayhead: wordPlayhead)
                    .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            } else {
                timedRow
                caption
            }
        }
        .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
        .overlay(alignment: rtl ? .trailing : .leading) {
            if style == .live, active, !row.text.isEmpty {
                RoundedRectangle(cornerRadius: 2).fill(Color.spotifyGreen)
                    .frame(width: 3).padding(.vertical, 4).offset(x: rtl ? 14 : -14)
            }
        }
    }

    /// Chords at time-proportional positions, with the playhead when live.
    private var timedRow: some View {
        TimedRowLayout(spacing: 6) {
            ForEach(row.chords) { placed in
                ChordChip(name: placed.event.display(transposedBy: transposeBy),
                          active: playhead.map(placed.event.contains) ?? false,
                          style: style, onTap: onChordTap, verdict: verdict?(placed.event.start))
                    .layoutValue(key: TimedRowLayout.Position.self, value: placed.position)
            }
        }
        .frame(maxWidth: .infinity, minHeight: style == .sheet ? 22 : 40, alignment: .leading)
        .overlay(alignment: .leading) {
            if let playhead, row.contains(playhead), row.isInstrumental || row.text.isEmpty {
                GeometryReader { geo in
                    let fraction = (playhead - row.start) / max(row.end - row.start, 0.001)
                    let x = rtl ? geo.size.width * (1 - fraction) : geo.size.width * fraction
                    Rectangle()
                        .fill(Color.spotifyGreen.opacity(0.7))
                        .frame(width: 2)
                        .offset(x: max(0, min(geo.size.width - 2, x)))
                }
            }
        }
        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
    }

    private var caption: some View {
        HStack(spacing: 8) {
            if row.isInstrumental {
                Image(systemName: "music.quarternote.3")
                Text("Instrumental")
            } else if row.kind == .uncovered {
                Text("Chords pending")
            }
            Text(Self.span(row))
                .font(.system(size: style == .sheet ? 10 : 12, design: .monospaced))
        }
        .font(.system(size: style == .sheet ? 10 : 14, weight: .semibold, design: .rounded))
        .foregroundStyle(Palette.tertiary)
    }

    static func span(_ row: SheetModel.Row) -> String {
        "\(mmss(row.start))–\(mmss(row.end))"
    }
}

/// One chord label; lit while it is the sounding chord in the live view.
struct ChordChip: View {
    let name: String
    var active = false
    var style: ChordRowView.Style = .sheet
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
            Text(name)
                .font(style.chordFont)
                .foregroundStyle(active ? .black : Color.spotifyGreen)
                .padding(.vertical, style.chipPadding.vertical)
                .padding(.horizontal, style.chipPadding.horizontal)
                .background(
                    RoundedRectangle(cornerRadius: style == .sheet ? 7 : 13, style: .continuous)
                        .fill(active ? Color.spotifyGreen
                              : style == .sheet ? Color.white.opacity(0.06) : Color.clear)
                )
                .overlay(alignment: .topTrailing) {
                    if let verdictColor {
                        Circle().fill(verdictColor).frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                            .offset(x: 3, y: -3)
                            .accessibilityLabel(verdict.map { "\($0)" } ?? "")
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
        .animation(.easeInOut(duration: 0.15), value: active)
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
