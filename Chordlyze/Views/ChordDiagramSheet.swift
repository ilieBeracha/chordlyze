import SwiftUI

/// Bottom sheet: how to play one chord — guitar fingering + piano keys.
struct ChordDiagramSheet: View {
    let chord: String  // display name, e.g. "F#m"

    var body: some View {
        VStack(spacing: 24) {
            Text(chord)
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .padding(.top, 24)

            if let shape = ChordShapes.guitar[chord] {
                GuitarDiagram(shape: shape)
                    .frame(width: 190, height: 220)
            } else {
                Text("No fingering chart for this chord.")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.secondary)
            }

            if let notes = ChordShapes.pianoNotes(for: chord) {
                PianoStrip(highlighted: notes)
                    .frame(width: 238, height: 90)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color(hex: 0x111112))
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

struct GuitarDiagram: View {
    let shape: ChordShapes.GuitarShape
    private let fretCount = 4

    var body: some View {
        GeometryReader { geo in
            let topInset: CGFloat = 34
            let width = geo.size.width
            let gridHeight = geo.size.height - topInset - 8
            let stringGap = width / 5
            let fretGap = gridHeight / CGFloat(fretCount)

            ZStack(alignment: .topLeading) {
                // Nut or base-fret label
                if shape.baseFret == 1 {
                    Rectangle()
                        .fill(.white)
                        .frame(width: width, height: 4)
                        .offset(y: topInset - 4)
                } else {
                    Text("\(shape.baseFret)fr")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.secondary)
                        .offset(x: -26, y: topInset + fretGap / 2 - 8)
                }

                // Strings
                ForEach(0..<6) { s in
                    Rectangle()
                        .fill(Palette.gray5)
                        .frame(width: 1.5, height: gridHeight)
                        .offset(x: CGFloat(s) * stringGap, y: topInset)
                }
                // Frets
                ForEach(0...fretCount, id: \.self) { f in
                    Rectangle()
                        .fill(Palette.gray5)
                        .frame(width: width, height: 1.5)
                        .offset(y: topInset + CGFloat(f) * fretGap)
                }

                // Markers
                ForEach(0..<6) { s in
                    let fret = shape.frets[s]
                    let x = CGFloat(s) * stringGap
                    if fret == -1 {
                        Text("✕")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Palette.tertiary)
                            .position(x: x, y: topInset - 18)
                    } else if fret == 0 {
                        Circle()
                            .stroke(Palette.secondary, lineWidth: 1.5)
                            .frame(width: 11, height: 11)
                            .position(x: x, y: topInset - 18)
                    } else {
                        let row = fret - shape.baseFret  // 0-based row within grid
                        Circle()
                            .fill(Color.spotifyGreen)
                            .frame(width: 20, height: 20)
                            .position(x: x, y: topInset + (CGFloat(row) + 0.5) * fretGap)
                    }
                }
            }
        }
    }
}

struct PianoStrip: View {
    let highlighted: [Int]  // pitch classes, 0 = C

    private let whiteOrder: [Int] = [0, 2, 4, 5, 7, 9, 11]
    private let blackAfterWhiteIndex: [Int: Int] = [0: 1, 1: 3, 3: 6, 4: 8, 5: 10]

    var body: some View {
        GeometryReader { geo in
            let whiteW = geo.size.width / 7
            ZStack(alignment: .topLeading) {
                ForEach(0..<7) { i in
                    let pc = whiteOrder[i]
                    RoundedRectangle(cornerRadius: 3)
                        .fill(highlighted.contains(pc) ? Color.spotifyGreen : Color(hex: 0xE5E5EA))
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black, lineWidth: 1))
                        .frame(width: whiteW, height: geo.size.height)
                        .offset(x: CGFloat(i) * whiteW)
                }
                ForEach(Array(blackAfterWhiteIndex.keys.sorted()), id: \.self) { i in
                    let pc = blackAfterWhiteIndex[i]!
                    RoundedRectangle(cornerRadius: 2)
                        .fill(highlighted.contains(pc) ? Color.spotifyGreen : Color.black)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color(hex: 0x333336), lineWidth: 1))
                        .frame(width: whiteW * 0.62, height: geo.size.height * 0.6)
                        .offset(x: CGFloat(i + 1) * whiteW - whiteW * 0.31)
                }
            }
        }
    }
}
