import Foundation

/// How to play a song, in a few lines worked out from its own chart and tab:
/// the chords to learn first, the fingers that never move, the change worth
/// drilling and the strum. Every line comes from the data; a line without
/// data behind it is left out.
struct HowToPlay: Equatable {
    /// A chord as this song plays it: the tab's voicing when there is one.
    struct Voicing: Equatable {
        let name: String
        let shape: ChordShapes.GuitarShape
        /// Seconds this chord sounds in the song.
        let seconds: Double
    }

    struct Change: Equatable {
        let from: String
        let to: String
        /// How often the song makes this change.
        let count: Int
        /// The least time the song gives you to make it, in seconds.
        let fastest: Double
        /// Fretted notes that move.
        let moving: Int
    }

    enum Stroke: Equatable { case down, up }

    struct Strum: Equatable {
        /// One slot per sixteenth note of a bar; nil where you do not strike.
        let slots: [Stroke?]
        let bpm: Double
        /// Bars of the song that use exactly this pattern, of all bars with chords.
        let share: Double
    }

    /// The tab's capo; chord names and shapes are relative to it.
    let capo: Int
    /// The song's chords in playing order, passing chords left out.
    let chords: [Voicing]
    /// Strings held on the same fret by every chord in the song.
    let anchors: [Int]
    /// The change that needs the most practice.
    let change: Change?
    let strum: Strum?

    static let stringNames = ["low E", "A", "D", "G", "B", "high E"]
    /// Share of the song's chord time below which a chord is a passing chord.
    static let minimumShare = 0.03

    // MARK: - Lines

    /// The chords that cover most of the song, most played first, and the
    /// percent of the song's chord time they cover.
    var firstChords: (names: [String], percent: Int) {
        let main = chords.sorted { $0.seconds > $1.seconds }
        let first = Array(main.prefix(4))
        let total = main.map(\.seconds).reduce(0, +)
        return (first.map(\.name), Int((first.map(\.seconds).reduce(0, +) / total * 100).rounded()))
    }

    /// "Keep your high E and B fingers on fret 3 for every chord", when two or more strings never move.
    var anchorLine: String? {
        guard anchors.count >= 2, chords.count >= 2 else { return nil }
        return "Keep your \(Self.list(anchors.reversed().map { Self.stringNames[$0] })) fingers on fret \(chords[0].shape.frets[anchors[0]]) for every chord."
    }

    // MARK: - Building

    /// nil when the chart names no chords a guitar shape can be found for.
    /// Without a tab, chart names are shifted by `transpose` as the sheet shows them.
    static func make(analysis: ChordAnalysis, tab: SongTab?, transpose: Int = 0) -> HowToPlay? {
        let tabVoicings = tab.map(voicings) ?? [:]
        // The tab's own chord names and timeline when it has them: what a player reads.
        let timeline: [(name: String, start: Double, end: Double)]
        if let tab, let fromTab = chordTimeline(tab), fromTab.count >= 2 {
            timeline = fromTab
        } else {
            timeline = analysis.chords.filter { $0.label != "N" }
                .map { (ChordMath.transpose($0.displayName, by: transpose), $0.start, $0.end) }
        }
        func shape(_ name: String) -> ChordShapes.GuitarShape? { tabVoicings[name] ?? ChordShapes.guitar(name) }

        var seconds: [String: Double] = [:], order: [String] = []
        for event in timeline where shape(event.name) != nil {
            if seconds[event.name] == nil { order.append(event.name) }
            seconds[event.name, default: 0] += event.end - event.start
        }
        // Passing chords (a beat here and there) are not part of learning the song.
        let total = seconds.values.reduce(0, +)
        seconds = seconds.filter { $0.value >= total * minimumShare }
        let chords = order.filter { seconds[$0] != nil }.map { Voicing(name: $0, shape: shape($0)!, seconds: seconds[$0]!) }
        guard !chords.isEmpty else { return nil }

        let anchors = (0..<6).filter { s in
            let frets = chords.map { $0.shape.frets[s] }
            return frets.allSatisfy { $0 > 0 && $0 == frets[0] }
        }

        // Changes: consecutive different chords, with the least time the song gives each one.
        var stats: [String: (count: Int, fastest: Double)] = [:]
        let known = timeline.filter { seconds[$0.name] != nil }
        for (a, b) in zip(known, known.dropFirst()) where a.name != b.name {
            let key = a.name + "\u{0}" + b.name
            let entry = stats[key] ?? (0, .infinity)
            stats[key] = (entry.count + 1, min(entry.fastest, a.end - a.start))
        }
        let byName = Dictionary(uniqueKeysWithValues: chords.map { ($0.name, $0) })
        let change = stats.compactMap { key, stat -> Change? in
            let names = key.split(separator: "\u{0}").map(String.init)
            guard let from = byName[names[0]], let to = byName[names[1]] else { return nil }
            let moving = (0..<6).filter {
                (from.shape.frets[$0] > 0 || to.shape.frets[$0] > 0) && from.shape.frets[$0] != to.shape.frets[$0]
            }.count
            return Change(from: from.name, to: to.name, count: stat.count, fastest: stat.fastest, moving: moving)
        }
        // Hardest: more fingers to move, in less time, more often.
        .filter { $0.moving > 0 }
        .min { difficulty($0) > difficulty($1) || (difficulty($0) == difficulty($1) && $0.from < $1.from) }

        return HowToPlay(capo: tab?.capo ?? 0, chords: chords, anchors: anchors, change: change, strum: tab.flatMap(strum))
    }

    static func difficulty(_ change: Change) -> Double {
        Double(change.moving) / max(change.fastest, 0.25) * log2(Double(change.count) + 1)
    }

    /// Each chord name's voicing: the fullest strum of it in the tab.
    static func voicings(_ tab: SongTab) -> [String: ChordShapes.GuitarShape] {
        guard tab.strings == 6 else { return [:] }
        var best: [String: [SongTab.Note]] = [:]
        for measure in tab.measures {
            var current: String?
            for beat in measure.beats {
                current = beat.chord ?? current
                guard let name = current else { continue }
                let notes = beat.notes.filter { $0.dead != true && $0.tie != true }
                if notes.count >= 3, notes.count > (best[name]?.count ?? 0) { best[name] = notes }
            }
        }
        return best.mapValues { notes in
            // Tab strings run high to low; shapes run low E to high E.
            var frets = Array(repeating: -1, count: 6)
            for note in notes { frets[5 - note.string] = note.fret }
            return ChordShapes.GuitarShape(frets, base: ChordShapes.baseFret(for: frets))
        }
    }

    /// The tab's chord names on the recording's clock, in playing order.
    static func chordTimeline(_ tab: SongTab) -> [(name: String, start: Double, end: Double)]? {
        var events: [(name: String, start: Double)] = []
        var end = 0.0
        for bar in tab.bars where tab.measures.indices.contains(bar.measure) {
            let measure = tab.measures[bar.measure]
            let length = measure.beats.map(\.length).reduce(0, +)
            guard length > 0 else { continue }
            var at = 0.0
            for beat in measure.beats {
                if let name = beat.chord, events.last?.name != name {
                    events.append((name, bar.start + (bar.end - bar.start) * at / length))
                }
                at += beat.length
            }
            end = bar.end
        }
        guard !events.isEmpty else { return nil }
        return zip(events, events.dropFirst().map(\.start) + [end]).map { ($0.name, $0.start, $1) }
    }

    /// The most common strummed rhythm of a 4/4 bar, as down and up strokes on
    /// sixteenths: on-beat and "&" slots are downs, the others ups.
    static func strum(_ tab: SongTab) -> Strum? {
        var counts: [[Int]: Int] = [:], total = 0
        var seconds: [Double] = []
        for bar in tab.bars where tab.measures.indices.contains(bar.measure) {
            let measure = tab.measures[bar.measure]
            let length = measure.beats.map(\.length).reduce(0, +)
            guard abs(length - 1) < 0.001, measure.beats.contains(where: { $0.notes.count >= 2 }) else { continue }
            var onsets: [Int] = [], at = 0.0
            for beat in measure.beats {
                let struck = beat.notes.filter { $0.tie != true }
                if beat.rest != true, struck.count >= 2 {
                    let slot = at * 16
                    guard abs(slot - slot.rounded()) < 0.01 else { onsets = []; break }  // not on a sixteenth
                    onsets.append(Int(slot.rounded()))
                }
                at += beat.length
            }
            guard !onsets.isEmpty else { continue }
            counts[onsets, default: 0] += 1
            total += 1
            seconds.append(bar.end - bar.start)
        }
        guard let (pattern, count) = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key.count < $1.key.count) }),
              total > 0, count * 4 >= total else { return nil }
        let bar = seconds.sorted()[seconds.count / 2]
        var slots = [Stroke?](repeating: nil, count: 16)
        for slot in pattern where slot < 16 { slots[slot] = slot % 2 == 0 ? .down : .up }
        return Strum(slots: slots, bpm: (240 / bar).rounded(), share: Double(count) / Double(total))
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }

    static func seconds(_ value: Double) -> String {
        value < 1 ? "under a second" : String(format: "%.1f s", value)
    }
}
