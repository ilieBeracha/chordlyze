import Foundation

/// Mid-take feedback: each chart chord in the take gets a verdict from what
/// the on-device detector heard. Deterministic and clock-free: times are
/// seconds of recorded audio, the same timeline the backend scores.
///
/// The detector is conservative (see docs/live-drill-detection.md): it
/// accepts a chord only with clear evidence, so a chord it never accepted is
/// left unjudged rather than marked wrong.
struct PracticeFeedback: Equatable {
    enum Verdict: Equatable {
        /// Matching chord heard; `offset` is seconds after the chart change
        /// (negative = early), detector latency already removed.
        case hit(offset: Double)
        /// A different chord was heard while this one should have sounded.
        case wrong(heard: String)
        /// Same chord as the previous target, which was hit; nothing new to strum.
        case held
    }
    struct Target: Equatable {
        let start: Double
        let end: Double
        let name: String
        let mask: UInt16
    }

    /// Analysis window plus dwell before the detector reports a strum.
    static let detectorLatency = 0.35
    /// A strum this far before the chart change counts for the next chord.
    static let earlyWindow = 0.5
    /// Within this of the change the strum is "on time".
    static let onTimeTolerance = 0.25

    let targets: [Target]
    private(set) var verdicts: [Int: Verdict] = [:]
    private var lastHeard: String?

    /// Sounding chords the take covers, transposed like the scoring reference.
    init(chords: [ChordSegment], start: Double, end: Double, transpose: Int = 0) {
        targets = chords.compactMap { segment in
            guard segment.end > start, segment.start < end,
                  let chord = segment.chord?.transposed(by: transpose),
                  let mask = Self.mask(chord) else { return nil }
            return Target(start: segment.start, end: segment.end, name: chord.display, mask: mask)
        }
    }

    static func mask(_ chord: Chord) -> UInt16? {
        guard let notes = chord.withoutBass.pitchClasses, Set(notes).count >= 3 else { return nil }
        return notes.reduce(0) { $0 | (UInt16(1) << $1) }
    }

    /// Feed every detector snapshot in order. A strum is the moment the
    /// detector starts reporting a chord it was not reporting just before.
    /// Returns the index of the target whose verdict changed.
    @discardableResult
    mutating func observe(current: String?, chartTime: Double) -> Int? {
        defer { lastHeard = current }
        guard let current, current != lastHeard else { return nil }
        return heard(current, at: chartTime - Self.detectorLatency)
    }

    /// A strum of `name` at chart second `time`.
    @discardableResult
    mutating func heard(_ name: String, at time: Double) -> Int? {
        guard let chord = Chord(display: name), let mask = Self.mask(chord) else { return nil }
        let sounding = targets.firstIndex { $0.start <= time && time < $0.end }
        let next = targets.firstIndex { $0.start > time && $0.start - time <= Self.earlyWindow }
        // An early strum of the coming chord belongs to it, not to the current one.
        if let next, targets[next].mask == mask, verdicts[next] == nil {
            return set(next, .hit(offset: time - targets[next].start))
        }
        guard let sounding else { return nil }
        let target = targets[sounding]
        if target.mask == mask {
            switch verdicts[sounding] {
            case .hit: return nil
            default: return set(sounding, .hit(offset: time - target.start))
            }
        }
        guard verdicts[sounding] == nil else { return nil }
        return set(sounding, .wrong(heard: name))
    }

    private mutating func set(_ index: Int, _ verdict: Verdict) -> Int {
        verdicts[index] = verdict
        if case .hit = verdict {
            var k = index + 1
            while k < targets.count, targets[k].mask == targets[index].mask, verdicts[k] == nil {
                verdicts[k] = .held
                k += 1
            }
        }
        return index
    }

    func verdict(startingAt start: Double) -> Verdict? {
        targets.firstIndex { $0.start == start }.flatMap { verdicts[$0] }
    }

    /// Targets with a hit, wrong or held verdict, in chart order.
    var judged: [(target: Target, verdict: Verdict)] {
        verdicts.keys.sorted().map { (targets[$0], verdicts[$0]!) }
    }
    var hits: Int { verdicts.values.filter { if case .wrong = $0 { return false }; return true }.count }

    static func describe(_ target: Target, _ verdict: Verdict) -> String {
        switch verdict {
        case .hit(let offset) where abs(offset) <= onTimeTolerance: return "\(target.name) on time"
        case .hit(let offset): return String(format: "%@ %@ by %.1f s", target.name, offset < 0 ? "early" : "late", abs(offset))
        case .wrong(let heard): return "\(target.name) expected, heard \(heard)"
        case .held: return "\(target.name) held"
        }
    }
}
