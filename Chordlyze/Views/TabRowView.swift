import SwiftUI

/// The tab bars played during one sheet row, wrapped to the page width.
struct TabStripView: View {
    let tab: SongTab
    let measures: [SongTab.Measure]
    @State private var width: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            if width > 0 {
                ForEach(Array(TabLayout.rows(measures, width: width).enumerated()), id: \.offset) { _, row in
                    TabRowView(row: row, measures: measures, strings: tab.strings)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Guitar tab")
    }
}

/// One line of tab: a staff line per string, bar lines, and fret numbers
/// with chord names and section markers above.
struct TabRowView: View {
    let row: TabLayout.Row
    let measures: [SongTab.Measure]
    let strings: Int

    private static let lineGap: CGFloat = 15
    private static let top: CGFloat = 36

    private var height: CGFloat { Self.top + CGFloat(max(strings, 1) - 1) * Self.lineGap + 10 }

    var body: some View {
        Canvas { context, _ in
            let y = { (s: Int) in Self.top + CGFloat(s) * Self.lineGap }
            var lines = Path()
            for s in 0..<max(strings, 1) {
                lines.move(to: CGPoint(x: 0, y: y(s)))
                lines.addLine(to: CGPoint(x: row.width, y: y(s)))
            }
            for x in row.bars {
                lines.move(to: CGPoint(x: x, y: y(0)))
                lines.addLine(to: CGPoint(x: x, y: y(max(strings, 1) - 1)))
            }
            context.stroke(lines, with: .color(Palette.faint), lineWidth: 1)

            for marker in row.markers {
                context.draw(Text(marker.text).font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.spotifyGreen), at: CGPoint(x: marker.x, y: 0), anchor: .topLeading)
            }
            for placed in row.beats {
                let beat = measures[placed.measure].beats[placed.beat]
                if let chord = beat.chord {
                    context.draw(Text(chord).font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white), at: CGPoint(x: placed.x, y: 14), anchor: .top)
                }
                for note in beat.notes where note.string < strings {
                    let text = context.resolve(Text(note.label).font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(note.tie == true ? Palette.secondary : Palette.nearWhite))
                    let size = text.measure(in: CGSize(width: 60, height: 20))
                    let center = CGPoint(x: placed.x, y: y(note.string))
                    context.fill(Path(CGRect(x: center.x - size.width / 2 - 1, y: center.y - size.height / 2,
                                             width: size.width + 2, height: size.height)), with: .color(.black))
                    context.draw(text, at: center, anchor: .center)
                }
            }
        }
        .frame(width: row.width, height: height)
        .accessibilityHidden(true)
    }
}
