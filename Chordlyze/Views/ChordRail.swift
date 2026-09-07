import SwiftUI

/// Live: the chord being played and the ones coming, each with its
/// fingering, in a strip above the words. The sounding chord is the large
/// green card; the strip slides as the song moves so it stays at the left.
struct ChordRailView: View {
    let events: [SheetModel.Event]
    /// Chart second, chord lead included.
    let position: Double
    var transposeBy = 0
    var onTap: ((String) -> Void)? = nil

    private static let count = 8

    var body: some View {
        let changes = SheetModel.changes(events, from: position, count: Self.count)
        let currentID = changes.first?.id
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(Array(changes.enumerated()), id: \.element.id) { index, event in
                        let name = event.display(transposedBy: transposeBy)
                        ChordCard(name: name, shape: ChordShapes.guitar(name), role: index == 0 ? .now : index == 1 ? .next : .later)
                            .onTapGesture { onTap?(name) }
                            .id(event.id)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 10)
            }
            .onChange(of: currentID, initial: true) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .leading) }
            }
        }
        .accessibilityIdentifier("chord-rail")
    }
}

/// One chord in the rail: name, fingering, and where on the neck.
struct ChordCard: View {
    enum Role { case now, next, later }
    let name: String
    let shape: ChordShapes.GuitarShape?
    var role: Role = .later

    private var now: Bool { role == .now }
    private var ink: Color { now ? .black : .white }

    var body: some View {
        VStack(spacing: now ? 8 : 6) {
            Text(role == .next ? "NEXT" : " ")
                .font(.system(size: 9, weight: .heavy, design: .rounded)).tracking(1)
                .foregroundStyle(role == .next ? Color.spotifyGreen : .clear)
            Text(name)
                .font(.system(size: now ? 17 : 14, weight: .bold, design: .monospaced))
                .foregroundStyle(ink).lineLimit(1).minimumScaleFactor(0.7)
            if let shape {
                MiniFretboard(shape: shape, ink: ink.opacity(now ? 0.55 : 0.32), dot: now ? .black : .spotifyGreen, mark: ink.opacity(0.7))
                    .frame(width: now ? 58 : 46, height: now ? 62 : 50)
                Text(shape.baseFret == 1 ? " " : "\(shape.baseFret)fr")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink.opacity(0.7))
            } else {
                Text("—").font(.system(size: 22, weight: .light)).foregroundStyle(ink.opacity(0.5))
                    .frame(height: now ? 62 : 50)
                Text(" ").font(.system(size: 10))
            }
        }
        .padding(.horizontal, now ? 14 : 10).padding(.vertical, 8)
        .frame(width: now ? 96 : 78)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(now ? Color.spotifyGreen : Palette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(role == .next ? Palette.greenTintBorder : .clear, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.25), value: now)
        .accessibilityLabel("\(name)\(now ? ", playing" : role == .next ? ", next" : "")")
    }
}

/// A small fretboard: six strings, four frets, dots where the fingers go,
/// open and muted marks above the nut. Cheap to draw; the rail has many.
struct MiniFretboard: View {
    let shape: ChordShapes.GuitarShape
    var ink: Color = .white.opacity(0.35)
    var dot: Color = .spotifyGreen
    var mark: Color = .white.opacity(0.7)

    var body: some View {
        Canvas { context, size in
            // The outer strings sit in from the edge so their dots and marks are whole.
            let inset: CGFloat = 5
            let top: CGFloat = 10
            let width = size.width - inset * 2
            let gridHeight = size.height - top
            let stringGap = width / 5
            let fretGap = gridHeight / 4
            var grid = Path()
            for s in 0..<6 {
                let x = inset + CGFloat(s) * stringGap
                grid.move(to: CGPoint(x: x, y: top)); grid.addLine(to: CGPoint(x: x, y: top + gridHeight))
            }
            for f in 0...4 {
                let y = top + CGFloat(f) * fretGap
                grid.move(to: CGPoint(x: inset, y: y)); grid.addLine(to: CGPoint(x: inset + width, y: y))
            }
            context.stroke(grid, with: .color(ink), lineWidth: 1)
            if shape.baseFret == 1 {
                context.fill(Path(CGRect(x: inset - 0.5, y: top - 1.5, width: width + 1, height: 3)), with: .color(mark))
            }
            let radius = min(stringGap, fretGap) * 0.36
            for (s, fret) in shape.frets.enumerated() {
                let x = inset + CGFloat(s) * stringGap
                if fret < 0 {
                    var cross = Path()
                    cross.move(to: CGPoint(x: x - 2.5, y: 2)); cross.addLine(to: CGPoint(x: x + 2.5, y: 7))
                    cross.move(to: CGPoint(x: x + 2.5, y: 2)); cross.addLine(to: CGPoint(x: x - 2.5, y: 7))
                    context.stroke(cross, with: .color(mark), lineWidth: 1.2)
                } else if fret == 0 {
                    context.stroke(Path(ellipseIn: CGRect(x: x - 2.5, y: 2, width: 5, height: 5)), with: .color(mark), lineWidth: 1)
                } else {
                    let row = CGFloat(fret - shape.baseFret)
                    let center = CGPoint(x: x, y: top + (row + 0.5) * fretGap)
                    context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                                 with: .color(dot))
                }
            }
        }
    }
}
