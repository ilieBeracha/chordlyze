import SwiftUI

/// The tab bars played during one sheet row: a quiet card under the row's
/// chords, string names in a left gutter, every line justified to the same
/// width so bar lines align from line to line.
struct TabStripView: View {
    let tab: SongTab
    let measures: [SongTab.Measure]
    @State private var width: CGFloat = 0

    static let gutter: CGFloat = 16
    static let inset: CGFloat = 12

    /// Highest string first; the top string is lowercase when it repeats the
    /// bottom one's name (e … E), as tab is written.
    private var stringNames: [String] {
        let names = tab.tuning.map { Chord.names[(($0 % 12) + 12) % 12] }
        guard let first = names.first, names.count > 1, first == names.last else { return names }
        return [first.lowercased()] + names.dropFirst()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(TabLayout.rows(measures, width: max(width - Self.gutter, 1), justify: true).enumerated()),
                    id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 0) {
                    TabStringNames(names: stringNames, top: TabRowView.top(for: row))
                        .frame(width: Self.gutter, alignment: .leading)
                    TabRowView(row: row, measures: measures, strings: tab.strings)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .padding(Self.inset)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.card))
        .accessibilityElement()
        .accessibilityLabel("Guitar tab")
    }
}

/// String names beside each line, centred on their staff lines.
private struct TabStringNames: View {
    let names: [String]
    let top: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                Text(name).font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.tertiary)
                    .frame(height: TabRowView.lineGap)
            }
        }
        .padding(.top, top - TabRowView.lineGap / 2)
        .accessibilityHidden(true)
    }
}

/// One line of tab: hairline staff and bar lines, fret numbers on their
/// strings, and section names above where a section begins.
struct TabRowView: View {
    let row: TabLayout.Row
    let measures: [SongTab.Measure]
    let strings: Int

    static let lineGap: CGFloat = 14
    /// Room above the staff: a section name, or just breathing space.
    static func top(for row: TabLayout.Row) -> CGFloat { row.markers.isEmpty ? 8 : 24 }

    private var count: Int { max(strings, 1) }
    private var top: CGFloat { Self.top(for: row) }
    private var height: CGFloat { top + CGFloat(count - 1) * Self.lineGap + 8 }

    var body: some View {
        Canvas { context, _ in
            let y = { (s: Int) in top + CGFloat(s) * Self.lineGap }
            var staff = Path()
            for s in 0..<count {
                staff.move(to: CGPoint(x: 0, y: y(s)))
                staff.addLine(to: CGPoint(x: row.width, y: y(s)))
            }
            context.stroke(staff, with: .color(Palette.faint.opacity(0.9)), lineWidth: 0.6)
            var bars = Path()
            for x in row.bars {
                bars.move(to: CGPoint(x: x, y: y(0)))
                bars.addLine(to: CGPoint(x: x, y: y(count - 1)))
            }
            context.stroke(bars, with: .color(Palette.tertiary), lineWidth: 1)

            for marker in row.markers {
                // Songsterr prefixes section names with form letters ("[A'] Verse 1").
                let name = marker.text.replacingOccurrences(of: #"^\s*\[[^\]]*\]\s*"#, with: "", options: .regularExpression)
                context.draw(Text((name.isEmpty ? marker.text : name).uppercased())
                                .font(.system(size: 10, weight: .bold)).tracking(0.8)
                                .foregroundColor(.spotifyGreen),
                             at: CGPoint(x: marker.x + 2, y: 0), anchor: .topLeading)
            }
            for placed in row.beats {
                let beat = measures[placed.measure].beats[placed.beat]
                for note in beat.notes where note.string < count {
                    let text = context.resolve(Text(note.label)
                        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundColor(note.tie == true ? Palette.tertiary : Palette.nearWhite))
                    let size = text.measure(in: CGSize(width: 60, height: 20))
                    let center = CGPoint(x: placed.x, y: y(note.string))
                    // Clear the staff behind the number, in the card's colour.
                    context.fill(Path(roundedRect: CGRect(x: center.x - size.width / 2 - 2, y: center.y - 6,
                                                          width: size.width + 4, height: 12), cornerRadius: 3),
                                 with: .color(Palette.card))
                    context.draw(text, at: center, anchor: .center)
                }
            }
        }
        .frame(width: row.width, height: height)
        .accessibilityHidden(true)
    }
}
