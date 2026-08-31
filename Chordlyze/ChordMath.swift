import Foundation

/// Transposition + capo suggestion over display chord names ("C", "F#m", "B°").
enum ChordMath {
    static let roots = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// Easy open-position shapes on guitar.
    private static let openShapes: Set<String> = ["C", "A", "G", "E", "D", "Am", "Em", "Dm"]

    static func parse(_ display: String) -> (root: Int, suffix: String)? {
        guard display != "N.C.", let first = display.first, first.isLetter else { return nil }
        var rootText = String(first)
        var rest = String(display.dropFirst())
        if rest.first == "#" {
            rootText.append("#")
            rest.removeFirst()
        }
        guard let index = roots.firstIndex(of: rootText) else { return nil }
        return (index, rest)
    }

    /// "F#m" shifted by −2 → "Em". Non-chords pass through untouched.
    static func transpose(_ display: String, by semitones: Int) -> String {
        guard semitones != 0, let (root, suffix) = parse(display) else { return display }
        let shifted = ((root + semitones) % 12 + 12) % 12
        return roots[shifted] + suffix
    }

    /// Capo fret (0–9) that turns the most playing time into open shapes.
    /// Display chords are the original transposed DOWN by the capo.
    static func autoCapo(names durations: [(display: String, duration: Double)]) -> Int {
        var best = (capo: 0, score: -1.0)
        for capo in 0...9 {
            var score = 0.0
            for (display, duration) in durations {
                if openShapes.contains(transpose(display, by: -capo)) {
                    score += duration
                }
            }
            if score > best.score {
                best = (capo, score)
            }
        }
        return best.capo
    }
}
