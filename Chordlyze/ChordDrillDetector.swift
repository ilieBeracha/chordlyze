import Accelerate
import Foundation

/// These are evidence states, not calibrated probabilities.
enum DrillEvidence: Equatable, Sendable {
    case quiet
    case uncertain
    case chord(String)
}

struct DrillSnapshot: Equatable, Sendable {
    let time: Double
    let evidence: DrillEvidence
    let current: String?
    let changes: Int
}

enum DrillConfigurationError: LocalizedError {
    case unsupportedChord, indistinguishableChords, unsupportedSampleRate
    var errorDescription: String? {
        switch self {
        case .unsupportedChord: return "This chord is not supported by live drills."
        case .indistinguishableChords: return "Choose two chords with different notes. Bass voicing is flexible in this drill."
        case .unsupportedSampleRate: return "This microphone format is not supported. Try another audio input."
        }
    }
}

/// Harmonic dictionary + nonnegative least squares, before octave folding.
/// This is an original implementation of the approximate-transcription approach;
/// no NNLS-Chroma/Chordino source is bundled. See docs/live-drill-detection.md.
final class DrillPitchAnalyzer {
    static let frameSize = 16384
    static let hopSize = 2048
    private let sampleRate: Double
    private let fft: FFTSetup
    private let log2Size = vDSP_Length(14)
    private let binCount: Int
    private let firstMIDI = 36
    private let noteCount = 60
    private var window = [Float](repeating: 0, count: frameSize)
    private var windowed = [Float](repeating: 0, count: frameSize)
    private var real = [Float](repeating: 0, count: frameSize / 2)
    private var imaginary = [Float](repeating: 0, count: frameSize / 2)
    private var power = [Float](repeating: 0, count: frameSize / 2)
    private var magnitude: [Float]
    private var peaked: [Float]
    private var weightedSpectrum: [Float]
    private var dictionary: [Float]
    private var weightedDictionary: [Float]
    private var weightedTranspose: [Float]
    private var gram: [Float]
    private var rhs: [Float]
    private var activation: [Float]
    private var tuningCents: Double = 0
    private var dictionaryTuning: Double = .infinity
    private var hasTuning = false

    init(sampleRate: Double) throws {
        guard sampleRate.isFinite, (32000...96000).contains(sampleRate),
              let setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2)) else {
            throw DrillConfigurationError.unsupportedSampleRate
        }
        self.sampleRate = sampleRate
        fft = setup
        binCount = min(Self.frameSize / 2, Int(5000 * Double(Self.frameSize) / sampleRate) + 1)
        magnitude = .init(repeating: 0, count: binCount)
        peaked = magnitude
        weightedSpectrum = magnitude
        dictionary = .init(repeating: 0, count: binCount * noteCount)
        weightedDictionary = dictionary
        weightedTranspose = dictionary
        gram = .init(repeating: 0, count: noteCount * noteCount)
        rhs = .init(repeating: 0, count: noteCount)
        activation = rhs
        vDSP_hann_window(&window, vDSP_Length(Self.frameSize), Int32(vDSP_HANN_NORM))
        rebuildDictionary(cents: 0)
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    func reset() {
        hasTuning = false
        tuningCents = 0
        rebuildDictionary(cents: 0)
    }

    /// Returns approximate fundamental-note energy by pitch class. Broadband
    /// noise and near-empty spectra return nil; a single note remains one note.
    func analyze(_ samples: [Float]) -> [Float]? {
        precondition(samples.count == Self.frameSize)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(Self.frameSize))
        real.withUnsafeMutableBufferPointer { rp in
            imaginary.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.frameSize / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(Self.frameSize / 2))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, log2Size, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(Self.frameSize / 2))
            }
        }
        // Packed real FFT bin zero also contains Nyquist; neither is a note.
        magnitude[0] = 0
        var peak: Float = 0
        var sum: Double = 0
        var logSum: Double = 0
        for k in 1..<binCount {
            let value = sqrt(max(0, power[k]))
            magnitude[k] = value
            peak = max(peak, value)
            sum += Double(value)
            logSum += log(Double(value) + 1e-12)
        }
        guard peak > 1e-6, sum > 0 else { return nil }
        let flatness = exp(logSum / Double(binCount - 1)) / (sum / Double(binCount - 1))
        guard flatness < 0.45 else { return nil }
        estimateTuning(peak: peak)
        isolatePeaks(peak: peak)
        let quantized = (tuningCents / 5).rounded() * 5
        if quantized != dictionaryTuning { rebuildDictionary(cents: quantized) }

        let supported = harmonicSupport(peak: peak)

        // Local spectral standardization reduces timbre/register dominance.
        // Compute the same weights for both observations and the note model.
        var localSum: Float = 0
        let radius = 25
        for k in 0...min(radius, binCount - 1) { localSum += magnitude[k] * magnitude[k] }
        for k in 0..<binCount {
            let low = max(0, k - radius), high = min(binCount - 1, k + radius)
            let localRMS = sqrt(max(0, localSum) / Float(high - low + 1))
            let weight = 1 / pow(max(0.004, localRMS / peak), 0.3)
            let value = max(0, magnitude[k] / peak - 0.12 * localRMS / peak)
            weightedSpectrum[k] = value * weight
            for note in 0..<noteCount {
                let coefficient = supported[note] ? dictionary[note * binCount + k] * weight : 0
                weightedDictionary[note * binCount + k] = coefficient
                weightedTranspose[k * noteCount + note] = coefficient
            }
            if k - radius >= 0 { localSum -= magnitude[k - radius] * magnitude[k - radius] }
            if k + radius + 1 < binCount { localSum += magnitude[k + radius + 1] * magnitude[k + radius + 1] }
        }
        vDSP_mmul(weightedDictionary, 1, weightedTranspose, 1, &gram, 1,
                   vDSP_Length(noteCount), vDSP_Length(noteCount), vDSP_Length(binCount))
        vDSP_mmul(weightedDictionary, 1, weightedSpectrum, 1, &rhs, 1,
                   vDSP_Length(noteCount), 1, vDSP_Length(binCount))
        for i in 0..<noteCount { activation[i] = 0 }
        // Cyclic coordinate descent on the small nonnegative quadratic problem.
        // The small L1 term prevents weak residual harmonics becoming extra notes.
        let regularization = (rhs.max() ?? 0) * 0.008
        for _ in 0..<28 {
            var delta: Float = 0
            for i in 0..<noteCount {
                var explained: Float = 0
                for j in 0..<noteCount { explained += gram[i * noteCount + j] * activation[j] }
                let next = max(0, activation[i] + (rhs[i] - explained - regularization)
                               / max(gram[i * noteCount + i], 1e-9))
                delta = max(delta, abs(next - activation[i]))
                activation[i] = next
            }
            if delta < 0.0001 { break }
        }
        var chroma = [Float](repeating: 0, count: 12)
        for i in 0..<noteCount { chroma[(firstMIDI + i) % 12] += activation[i] }
        guard let maximum = chroma.max(), maximum > 0 else { return nil }
        return chroma.map { $0 / maximum }
    }

    private func estimateTuning(peak: Float) {
        var sine = 0.0, cosine = 0.0, weightSum = 0.0
        for k in 2..<(binCount - 1) {
            let frequency = Double(k) * sampleRate / Double(Self.frameSize)
            guard frequency > 100, frequency < 1600, magnitude[k] > peak * 0.07,
                  magnitude[k] > magnitude[k - 1], magnitude[k] > magnitude[k + 1] else { continue }
            let left = log(Double(magnitude[k - 1]) + 1e-12)
            let middle = log(Double(magnitude[k]) + 1e-12)
            let right = log(Double(magnitude[k + 1]) + 1e-12)
            let denominator = left - 2 * middle + right
            let offset = abs(denominator) > 1e-10 ? max(-0.5, min(0.5, 0.5 * (left - right) / denominator)) : 0
            let hz = (Double(k) + offset) * sampleRate / Double(Self.frameSize)
            let semitones = 69 + 12 * log2(hz / 440)
            let angle = 2 * Double.pi * (semitones - semitones.rounded())
            let weight = Double(magnitude[k])
            sine += sin(angle) * weight
            cosine += cos(angle) * weight
            weightSum += weight
        }
        guard weightSum > 0, hypot(sine, cosine) / weightSum > 0.65 else { return }
        let estimate = atan2(sine, cosine) * 100 / (2 * Double.pi)
        tuningCents = hasTuning ? tuningCents * 0.8 + estimate * 0.2 : estimate
        hasTuning = true
    }

    /// Guitar attacks broaden spectral peaks. Fitting those skirts as note
    /// fundamentals invents adjacent bass pitches; retain each peak's refined
    /// frequency and height but reconstruct a narrow analysis lobe.
    private func isolatePeaks(peak: Float) {
        for k in peaked.indices { peaked[k] = 0 }
        for k in 2..<(binCount - 1) {
            guard magnitude[k] > peak * 0.01,
                  magnitude[k] > magnitude[k - 1], magnitude[k] > magnitude[k + 1] else { continue }
            let left = log(Double(magnitude[k - 1]) + 1e-12)
            let middle = log(Double(magnitude[k]) + 1e-12)
            let right = log(Double(magnitude[k + 1]) + 1e-12)
            let denominator = left - 2 * middle + right
            let offset = abs(denominator) > 1e-10 ? max(-0.5, min(0.5, 0.5 * (left - right) / denominator)) : 0
            let center = Double(k) + offset
            for bin in max(1, k - 2)...min(binCount - 1, k + 2) {
                let distance = (Double(bin) - center) / 0.68
                peaked[bin] = max(peaked[bin], magnitude[k] * Float(exp(-0.5 * distance * distance)))
            }
        }
        swap(&magnitude, &peaked)
    }

    /// A pluck's broad low-frequency transient must not turn into a row of
    /// adjacent bass notes. Require separate spectral peaks at two partials,
    /// allowing string-to-string tuning differences and FFT resolution.
    private func harmonicSupport(peak: Float) -> [Bool] {
        var peaks: [Double] = []
        for k in 2..<(binCount - 1) {
            guard magnitude[k] > peak * 0.015,
                  magnitude[k] > magnitude[k - 1], magnitude[k] > magnitude[k + 1] else { continue }
            let left = log(Double(magnitude[k - 1]) + 1e-12)
            let middle = log(Double(magnitude[k]) + 1e-12)
            let right = log(Double(magnitude[k + 1]) + 1e-12)
            let denominator = left - 2 * middle + right
            let offset = abs(denominator) > 1e-10 ? max(-0.5, min(0.5, 0.5 * (left - right) / denominator)) : 0
            peaks.append((Double(k) + offset) * sampleRate / Double(Self.frameSize))
        }
        return (0..<noteCount).map { note in
            let frequency = 440 * pow(2, (Double(firstMIDI + note - 69) + dictionaryTuning / 100) / 12)
            var matches = 0
            var lowPartial = false
            for harmonic in 1...3 {
                let expected = frequency * Double(harmonic)
                guard expected < 5000 else { break }
                let tolerance = max(sampleRate / Double(Self.frameSize) * 0.9, expected * 0.0234)
                if peaks.contains(where: { abs($0 - expected) < tolerance }) {
                    matches += 1
                    if harmonic <= 2 { lowPartial = true }
                }
            }
            return matches >= 2 && lowPartial
        }
    }

    private func rebuildDictionary(cents: Double) {
        dictionaryTuning = cents
        for i in dictionary.indices { dictionary[i] = 0 }
        for note in 0..<noteCount {
            let frequency = 440 * pow(2, (Double(firstMIDI + note - 69) + cents / 100) / 12)
            for harmonic in 1...8 {
                let center = frequency * Double(harmonic) * Double(Self.frameSize) / sampleRate
                guard center < Double(binCount - 1) else { break }
                let start = max(1, Int(center) - 3), end = min(binCount - 1, Int(center) + 4)
                guard start <= end else { continue }
                for k in start...end {
                    let distance = (Double(k) - center) / 0.68
                    dictionary[note * binCount + k] += Float(exp(-0.5 * distance * distance) / Double(harmonic))
                }
            }
        }
    }
}

struct DrillChordClassifier {
    struct Candidate {
        let name: String
        let mask: UInt16
        let required: [Int]
        let notes: [Int]
    }
    let targets: [String]
    private let targetMasks: [UInt16]
    private let vocabulary: [Candidate]

    /// Two drill targets, which must be distinct chords.
    init(chordA: String, chordB: String) throws {
        try self.init(targets: [chordA, chordB])
        guard targetMasks[0] != targetMasks[1] else { throw DrillConfigurationError.indistinguishableChords }
    }

    /// Named targets are reported under their own spelling; every other
    /// recognized chord is reported by its vocabulary name. No targets means
    /// every chord in the vocabulary is a candidate, as in practice feedback.
    init(targets: [String]) throws {
        self.targets = targets
        var masks: [UInt16] = []
        for name in targets {
            guard let chord = Chord(display: name)?.withoutBass,
                  let notes = chord.pitchClasses, Set(notes).count >= 3 else {
                throw DrillConfigurationError.unsupportedChord
            }
            masks.append(Self.mask(notes))
        }
        targetMasks = masks
        let qualities = ["maj", "min", "dim", "aug", "sus2", "sus4", "7", "maj7", "min7",
                         "minmaj7", "dim7", "hdim7", "maj6", "min6", "9", "maj9", "min9", "11", "13", "sus4(b7)"]
        var byMask: [UInt16: Candidate] = [:]
        for root in 0..<12 {
            for quality in qualities {
                let chord = Chord(label: "\(Chord.names[root]):\(quality)")!
                let notes = Array(Set(chord.pitchClasses!)).sorted()
                let mask = Self.mask(notes)
                // A perfect fifth may be omitted from a chord with an extension.
                let required = notes.count >= 4 ? notes.filter { $0 != (root + 7) % 12 } : notes
                if byMask[mask] == nil {
                    byMask[mask] = Candidate(name: chord.display, mask: mask, required: required, notes: notes)
                }
            }
        }
        vocabulary = byMask.values.sorted { $0.mask < $1.mask }
    }

    func classify(_ chroma: [Float]?) -> DrillEvidence {
        guard let chroma, chroma.count == 12, chroma.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return .uncertain }
        let strong = chroma.indices.filter { chroma[$0] >= 0.14 }
        guard strong.count >= 3 else { return .uncertain }
        let energy = chroma.map { $0 < 0.14 ? 0 : sqrt($0) }
        let total = energy.reduce(0, +)
        let norm = sqrt(energy.reduce(0) { $0 + $1 * $1 })
        guard total > 0, norm > 0 else { return .uncertain }
        var ranked: [(Candidate, Float)] = []
        for chord in vocabulary {
            guard chord.required.allSatisfy({ chroma[$0] >= 0.14 }) else { continue }
            let inside = chord.notes.reduce(Float(0)) { $0 + energy[$1] }
            let coverage = inside / total
            guard coverage >= 0.84 else { continue }
            let cosine = inside / (sqrt(Float(chord.notes.count)) * norm)
            ranked.append((chord, cosine + 0.25 * coverage))
        }
        ranked.sort { $0.1 > $1.1 }
        guard let best = ranked.first, best.1 >= 1.04,
              ranked.count == 1 || best.1 - ranked[1].1 >= 0.035 else { return .uncertain }
        if let index = targetMasks.firstIndex(of: best.0.mask) { return .chord(targets[index]) }
        return .chord(best.0.name)
    }

    private static func mask(_ notes: [Int]) -> UInt16 {
        notes.reduce(0) { $0 | (UInt16(1) << $1) }
    }
}

/// Deterministic streaming core. No AVAudioEngine, wall clock, UI or task queue.
/// Feed contiguous microphone sample timestamps; a gap resets all pitch history.
final class ChordDrillDetector {
    let sampleRate: Double
    private let analyzer: DrillPitchAnalyzer
    private let classifier: DrillChordClassifier
    private var ring = [Float](repeating: 0, count: DrillPitchAnalyzer.frameSize)
    private var frame = [Float](repeating: 0, count: DrillPitchAnalyzer.frameSize)
    private var writeIndex = 0
    private var filled = 0
    private var hopCount = 0
    private var recentPower: Float = 0
    private var expectedSampleTime: Int64?
    private var candidate: (name: String, since: Double)?
    private var previousAccepted: String?
    private(set) var current: String?
    private(set) var changes = 0
    private var noiseFloor: Float = 0.00015
    private var smoothedChroma: [Float]?

    convenience init(sampleRate: Double, chordA: String, chordB: String) throws {
        try self.init(sampleRate: sampleRate, classifier: DrillChordClassifier(chordA: chordA, chordB: chordB))
    }

    /// Accepts any vocabulary chord after the same dwell, for practice feedback.
    convenience init(sampleRate: Double) throws {
        try self.init(sampleRate: sampleRate, classifier: DrillChordClassifier(targets: []))
    }

    private init(sampleRate: Double, classifier: DrillChordClassifier) throws {
        self.sampleRate = sampleRate
        self.classifier = classifier
        analyzer = try DrillPitchAnalyzer(sampleRate: sampleRate)
    }

    func reset() {
        resetSignal()
        expectedSampleTime = nil
        previousAccepted = nil
        changes = 0
        noiseFloor = 0.00015
    }

    private func resetSignal() {
        filled = 0
        hopCount = 0
        writeIndex = 0
        recentPower = 0
        candidate = nil
        current = nil
        smoothedChroma = nil
        analyzer.reset()
    }

    func append(_ samples: UnsafeBufferPointer<Float>, sampleTime: Int64) -> [DrillSnapshot] {
        if let expectedSampleTime, expectedSampleTime != sampleTime { resetSignal() }
        expectedSampleTime = sampleTime + Int64(samples.count)
        var snapshots: [DrillSnapshot] = []
        for i in samples.indices {
            let value = samples[i].isFinite ? samples[i] : 0
            ring[writeIndex] = value
            writeIndex = (writeIndex + 1) % ring.count
            filled = min(ring.count, filled + 1)
            recentPower += value * value
            hopCount += 1
            guard hopCount == DrillPitchAnalyzer.hopSize else { continue }
            let rms = sqrt(recentPower / Float(hopCount))
            let time = Double(sampleTime + Int64(i) + 1) / sampleRate
            hopCount = 0
            recentPower = 0
            let quiet = rms < max(0.0006, noiseFloor * 2.8)
            if quiet {
                // A new strum must not inherit notes from before a rest.
                filled = 0
                smoothedChroma = nil
                noiseFloor = min(0.002, noiseFloor * 0.96 + rms * 0.04)
                snapshots.append(accept(.quiet, at: time))
                continue
            }
            guard filled == ring.count else {
                snapshots.append(accept(.uncertain, at: time))
                continue
            }
            for k in frame.indices { frame[k] = ring[(writeIndex + k) % ring.count] }
            var chroma = analyzer.analyze(frame)
            if let observation = chroma {
                if let previous = smoothedChroma {
                    chroma = zip(previous, observation).map { $0 * 0.5 + $1 * 0.5 }
                }
                smoothedChroma = chroma
            } else {
                smoothedChroma = nil
            }
            if chroma == nil { noiseFloor = min(0.002, noiseFloor * 0.98 + rms * 0.02) }
            snapshots.append(accept(classifier.classify(chroma), at: time))
        }
        return snapshots
    }

    private func accept(_ evidence: DrillEvidence, at time: Double) -> DrillSnapshot {
        if case .chord(let name) = evidence, classifier.targets.isEmpty || classifier.targets.contains(name) {
            if candidate?.name != name { candidate = (name, time); current = nil }
            if let candidate, time - candidate.since >= 0.07 {
                if previousAccepted != name {
                    if previousAccepted != nil { changes += 1 }
                    previousAccepted = name
                }
                current = name
            }
        } else {
            candidate = nil
            current = nil
        }
        return DrillSnapshot(time: time, evidence: evidence, current: current, changes: changes)
    }
}
