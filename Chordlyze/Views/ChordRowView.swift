import SwiftUI

/// One timeline row — lyric line, instrumental stretch, or unanalyzed part —
/// drawn the same way in the sheet and the live view. Chords sit above the
/// word they start on when the lyrics carry word times; otherwise they are
/// spread across the row in proportion to time.
struct ChordRowView: View {
    enum Style {
        case sheet
        case live

        var chordFont: Font {
            self == .sheet ? .system(size: 13, weight: .bold, design: .rounded)
                           : .system(size: 22, weight: .heavy, design: .rounded)
        }
        var wordFont: Font {
            self == .sheet ? .system(size: 18, design: .rounded)
                           : .system(size: 30, weight: .bold, design: .rounded)
        }
        var chipPadding: (vertical: CGFloat, horizontal: CGFloat) {
            self == .sheet ? (3, 9) : (9, 16)
        }
    }

    let row: SheetModel.Row
    var transposeBy = 0
    /// Song time: highlights the sounding chord and draws the playhead on
    /// timed rows. nil in the static sheet.
    var playhead: Double? = nil
    var style: Style = .sheet
    var onChordTap: ((String) -> Void)? = nil

    private var rtl: Bool { row.text.isRTLText }

    var body: some View {
        VStack(alignment: rtl ? .trailing : .leading, spacing: style == .sheet ? 4 : 14) {
            switch row.kind {
            case .uncovered:
                Label(row.text.isEmpty ? "Chords not analyzed for \(Self.span(row))"
                                       : "Chords not analyzed past \(mmss(row.start))",
                      systemImage: "questionmark.circle")
                    .font(style == .sheet ? .caption2 : .system(size: 14))
                    .foregroundStyle(Palette.tertiary)
            case .lyric where row.words != nil && !rtl && !row.text.isEmpty:
                // Word times known: each chord above the word it starts on.
                ChordLyricLine(text: row.text, chords: row.chords, transposeBy: transposeBy,
                               playhead: playhead, style: style, onChordTap: onChordTap)
            default:
                timedRow
                if row.isInstrumental || row.text.isEmpty {
                    caption
                }
            }
            if !row.text.isEmpty, row.kind != .lyric || row.words == nil || rtl {
                Text(row.text)
                    .font(style.wordFont)
                    .foregroundStyle(style == .sheet ? Palette.nearWhite : .white)
                    .lineSpacing(style == .sheet ? 18 * 0.35 : 30 * 0.22)
                    .multilineTextAlignment(rtl ? .trailing : .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
    }

    /// Chords at time-proportional positions, with the playhead when live.
    private var timedRow: some View {
        TimedRowLayout(spacing: 6) {
            ForEach(row.chords) { placed in
                ChordChip(name: placed.event.display(transposedBy: transposeBy),
                          active: playhead.map(placed.event.contains) ?? false,
                          style: style, onTap: onChordTap)
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
                              : style == .sheet ? Color.white.opacity(0.06) : Palette.greenTintFill)
                )
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
