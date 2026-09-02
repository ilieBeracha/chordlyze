import Foundation

/// Guitar fingerings and piano voicings for maj/min chords.
enum ChordShapes {
    /// 6 strings low-E→high-E: -1 muted, 0 open, n = fret. `baseFret` shifts the grid.
    struct GuitarShape {
        let frets: [Int]
        let baseFret: Int

        init(_ frets: [Int], base: Int = 1) {
            self.frets = frets
            self.baseFret = base
        }
    }

    static let guitar: [String: GuitarShape] = [
        "C":  .init([-1, 3, 2, 0, 1, 0]),
        "C#": .init([-1, 4, 6, 6, 6, 4], base: 4),
        "D":  .init([-1, -1, 0, 2, 3, 2]),
        "D#": .init([-1, 6, 8, 8, 8, 6], base: 6),
        "E":  .init([0, 2, 2, 1, 0, 0]),
        "F":  .init([1, 3, 3, 2, 1, 1]),
        "F#": .init([2, 4, 4, 3, 2, 2], base: 2),
        "G":  .init([3, 2, 0, 0, 0, 3]),
        "G#": .init([4, 6, 6, 5, 4, 4], base: 4),
        "A":  .init([-1, 0, 2, 2, 2, 0]),
        "A#": .init([-1, 1, 3, 3, 3, 1]),
        "B":  .init([-1, 2, 4, 4, 4, 2], base: 2),
        "Cm":  .init([-1, 3, 5, 5, 4, 3], base: 3),
        "C#m": .init([-1, 4, 6, 6, 5, 4], base: 4),
        "Dm":  .init([-1, -1, 0, 2, 3, 1]),
        "D#m": .init([-1, 6, 8, 8, 7, 6], base: 6),
        "Em":  .init([0, 2, 2, 0, 0, 0]),
        "Fm":  .init([1, 3, 3, 1, 1, 1]),
        "F#m": .init([2, 4, 4, 2, 2, 2], base: 2),
        "Gm":  .init([3, 5, 5, 3, 3, 3], base: 3),
        "G#m": .init([4, 6, 6, 4, 4, 4], base: 4),
        "Am":  .init([-1, 0, 2, 2, 1, 0]),
        "A#m": .init([-1, 1, 3, 3, 2, 1]),
        "Bm":  .init([-1, 2, 4, 4, 3, 2], base: 2),
    ]

    /// Pitch classes (0 = C) sounding in the chord, for the piano strip.
    static func pianoNotes(for display: String) -> [Int]? {
        guard let (root, suffix) = ChordMath.parse(display) else { return nil }
        let intervals: [Int]
        switch suffix {
        case "": intervals = [0, 4, 7]
        case "m": intervals = [0, 3, 7]
        case "°": intervals = [0, 3, 6]
        default: return nil
        }
        return intervals.map { (root + $0) % 12 }
    }
}
