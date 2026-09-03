import Foundation

/// Canonical chord: pitch-class root, quality, optional slash bass. Parses the
/// backend's Harte labels ("C#:min7/b7") and display names ("C#m7/B") so
/// transposition, diagrams and drills all reason about the same thing instead
/// of each splitting strings its own way.
struct Chord: Hashable {
    struct Quality: Hashable {
        /// Harte shorthand: "maj", "min7", "7"…
        let harte: String
        /// Display suffix: "", "m7", "7"…
        let suffix: String
        /// Semitones above the root; nil for a quality this app cannot voice.
        let intervals: [Int]?
    }

    let root: Int        // pitch class, 0 = C
    let quality: Quality
    let bass: Int?       // pitch class of the slash bass; nil = root position

    static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    // Mirrors backend/chordlyze_backend/analysis/chord.py — keep the two in step.
    private static let known: [Quality] = [
        .init(harte: "maj", suffix: "", intervals: [0, 4, 7]),
        .init(harte: "min", suffix: "m", intervals: [0, 3, 7]),
        .init(harte: "dim", suffix: "°", intervals: [0, 3, 6]),
        .init(harte: "aug", suffix: "+", intervals: [0, 4, 8]),
        .init(harte: "sus2", suffix: "sus2", intervals: [0, 2, 7]),
        .init(harte: "sus4", suffix: "sus4", intervals: [0, 5, 7]),
        .init(harte: "7", suffix: "7", intervals: [0, 4, 7, 10]),
        .init(harte: "maj7", suffix: "maj7", intervals: [0, 4, 7, 11]),
        .init(harte: "min7", suffix: "m7", intervals: [0, 3, 7, 10]),
        .init(harte: "minmaj7", suffix: "mMaj7", intervals: [0, 3, 7, 11]),
        .init(harte: "dim7", suffix: "°7", intervals: [0, 3, 6, 9]),
        .init(harte: "hdim7", suffix: "ø7", intervals: [0, 3, 6, 10]),
        .init(harte: "maj6", suffix: "6", intervals: [0, 4, 7, 9]),
        .init(harte: "min6", suffix: "m6", intervals: [0, 3, 7, 9]),
        .init(harte: "9", suffix: "9", intervals: [0, 4, 7, 10, 14]),
        .init(harte: "maj9", suffix: "maj9", intervals: [0, 4, 7, 11, 14]),
        .init(harte: "min9", suffix: "m9", intervals: [0, 3, 7, 10, 14]),
    ]
    private static let byHarte = Dictionary(uniqueKeysWithValues: known.map { ($0.harte, $0) })
    private static let bySuffix = Dictionary(uniqueKeysWithValues: known.map { ($0.suffix, $0) })
    private static let letters: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
    private static let accidentals: [Character: Int] = ["#": 1, "b": -1, "♯": 1, "♭": -1]
    /// Harte bass degrees are scale degrees relative to the root ("/3", "/b7").
    private static let degrees: [Int: Int] = [1: 0, 2: 2, 3: 4, 4: 5, 5: 7, 6: 9, 7: 11, 9: 14, 11: 17, 13: 21]

    init(root: Int, quality: Quality, bass: Int? = nil) {
        self.root = root
        self.quality = quality
        self.bass = bass
    }

    /// Harte label from the backend; nil for "N" (no chord) or anything unparsable.
    init?(label: String) {
        guard label != "N", let (root, rest) = Self.note(Substring(label)) else { return nil }
        var qualityText = "maj"
        var bassText: Substring?
        if rest.first == ":" {
            let parts = rest.dropFirst().split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            qualityText = String(parts[0])
            if parts.count > 1 { bassText = parts[1] }
        } else if rest.first == "/" {
            bassText = rest.dropFirst()
        } else if !rest.isEmpty {
            return nil
        }
        guard !qualityText.isEmpty else { return nil }
        var bass: Int?
        if let bassText {
            guard let semitones = Self.degreeSemitones(bassText) else { return nil }
            bass = Self.pc(root + semitones)
        }
        self.init(root: root, quality: Self.quality(harte: qualityText), bass: bass)
    }

    /// Display name ("F#m7/A", "Bb"); nil for "N.C." or garbage.
    init?(display: String) {
        guard display != "N.C." else { return nil }
        let parts = display.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let (root, suffix) = Self.note(parts[0]) else { return nil }
        var bass: Int?
        if parts.count > 1 {
            guard let (pc, trailing) = Self.note(parts[1]), trailing.isEmpty else { return nil }
            bass = pc
        }
        let text = String(suffix)
        self.init(root: root,
                  quality: Self.bySuffix[text] ?? Quality(harte: text, suffix: text, intervals: nil),
                  bass: bass)
    }

    var display: String {
        var out = Self.names[root] + quality.suffix
        if let bass { out += "/" + Self.names[bass] }
        return out
    }

    /// Same chord in root position — the identity a diagram or drill is keyed on.
    var withoutBass: Chord { Chord(root: root, quality: quality) }

    func transposed(by semitones: Int) -> Chord {
        Chord(root: Self.pc(root + semitones), quality: quality,
              bass: bass.map { Self.pc($0 + semitones) })
    }

    /// Pitch classes sounding in the chord, root first; nil when the quality is unknown.
    var pitchClasses: [Int]? {
        guard let intervals = quality.intervals else { return nil }
        var out = intervals.map { Self.pc(root + $0) }
        if let bass, !out.contains(bass) { out.append(bass) }
        return out
    }

    // MARK: - Parsing

    private static func quality(harte: String) -> Quality {
        byHarte[harte] ?? Quality(harte: harte, suffix: harte, intervals: nil)
    }

    private static func pc(_ n: Int) -> Int { ((n % 12) + 12) % 12 }

    /// Leading note name -> (pitch class, rest of the text).
    private static func note(_ text: Substring) -> (Int, Substring)? {
        guard let first = text.first, let base = letters[first] else { return nil }
        var pc = base
        var index = text.index(after: text.startIndex)
        while index < text.endIndex, let shift = accidentals[text[index]] {
            pc += shift
            index = text.index(after: index)
        }
        return (Self.pc(pc), text[index...])
    }

    /// Harte bass degree ("3", "b7", "#5") -> semitones above the root.
    private static func degreeSemitones(_ text: Substring) -> Int? {
        var shift = 0
        var rest = text
        while let first = rest.first, first == "b" || first == "#" {
            shift += first == "#" ? 1 : -1
            rest = rest.dropFirst()
        }
        guard let degree = Int(rest), let semitones = degrees[degree] else { return nil }
        return pc(semitones + shift)
    }
}
