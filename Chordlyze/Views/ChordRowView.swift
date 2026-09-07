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
    var onChordTap: ((String) -> Void)? = nil
    var onLyricTap: (() -> Void)? = nil
    /// Practice: live verdict for the chord starting at this chart second.
    var verdict: ((Double) -> PracticeFeedback.Verdict?)? = nil
    /// Song time for the words, without the chord display lead.
    var wordPlayhead: Double? = nil

    private var rtl: Bool { row.text.isRTLText }
    private var active: Bool { playhead.map(row.contains) ?? false }

    var body: some View {
        VStack(alignment: rtl ? .trailing : .leading, spacing: style == .sheet ? 4 : 6) {
            if !row.text.isEmpty {
                ChordLyricLine(text: row.text, chords: row.chords, words: row.words?.map(\.text), transposeBy: transposeBy,
                               playhead: playhead, style: style, active: active, pending: row.chords.isEmpty && row.held == nil,
                               onChordTap: onChordTap, onLyricTap: onLyricTap, verdict: verdict,
                               rowStart: row.start, rowEnd: row.end, wordTimes: row.words?.map(\.time),
                               wordPlayhead: wordPlayhead, wordEnds: row.words?.map(\.end))
                    .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            } else {
                // A wordless stretch is its chords on a line, nothing more; the
                // static sheet keeps a small time span so the page can be read.
                timedRow
            }
        }
        .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
    }

    /// A wordless stretch: its chords in an even row with equal gaps, as on
    /// a printed chart, never spread across the width by time. Live, the
    /// runner walks from chord to chord on their times.
    private var timedRow: some View {
        FlowLayout(spacing: style == .sheet ? 14 : 22) {
            ForEach(Array(row.chords.enumerated()), id: \.element.id) { index, placed in
                ChordChip(name: placed.event.display(transposedBy: transposeBy),
                          active: playhead.map(placed.event.contains) ?? false,
                          style: style, playing: playhead != nil, onTap: onChordTap, verdict: verdict?(placed.event.start))
                    .anchorPreference(key: ChordAnchors.self, value: .bounds) { [index: $0] }
            }
        }
        .frame(maxWidth: .infinity, minHeight: style == .sheet ? 22 : 30, alignment: rtl ? .trailing : .leading)
        .overlayPreferenceValue(ChordAnchors.self) { anchors in
            if style == .live, let wordPlayhead, row.contains(wordPlayhead), !row.chords.isEmpty {
                GeometryReader { geo in
                    let points = LyricPlayhead.waypoints(rowStart: row.start, rowEnd: row.end, words: anchors.mapValues { geo[$0] },
                                                         wordTimes: nil,
                                                         chordStarts: row.chords.enumerated().map { ($0.element.event.start, $0.offset) }, rtl: rtl)
                    if let point = LyricPlayhead.position(at: wordPlayhead, along: points, rtl: rtl) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.spotifyGreen.opacity(0.5))
                            .frame(width: 2, height: point.height + 4)
                            .position(x: point.x, y: point.y)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
    }

    private struct ChordAnchors: PreferenceKey {
        static var defaultValue: [Int: Anchor<CGRect>] = [:]
        static func reduce(value: inout [Int: Anchor<CGRect>], nextValue: () -> [Int: Anchor<CGRect>]) {
            value.merge(nextValue(), uniquingKeysWith: { $1 })
        }
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
                .animation(.easeInOut(duration: 0.2), value: active)
                .padding(.vertical, style.chipPadding.vertical)
                .padding(.horizontal, style.chipPadding.horizontal)
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
        .animation(.easeOut(duration: 0.08), value: active)
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
