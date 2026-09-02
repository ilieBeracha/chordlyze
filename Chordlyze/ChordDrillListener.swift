import Accelerate
import AVFoundation
import Foundation

/// Live detector for chord-change drills. Only distinguishes the two drilled
/// chords: mic audio -> chroma vector -> cosine match against each chord's
/// pitch-class template. Counts a change every time the stable winner flips.
@MainActor
final class ChordDrillListener: ObservableObject {
    @Published private(set) var current: String?
    @Published private(set) var changes = 0

    private let engine = AVAudioEngine()
    private var templates: [(name: String, chroma: [Float])] = []
    private var stable: String?
    private var candidate: (name: String, since: Date)?

    private static let noteIndex: [String: Int] = [
        "C": 0, "C#": 1, "Db": 1, "D": 2, "D#": 3, "Eb": 3, "E": 4, "F": 5,
        "F#": 6, "Gb": 6, "G": 7, "G#": 8, "Ab": 8, "A": 9, "A#": 10,
        "Bb": 10, "B": 11,
    ]

    /// Pitch-class template for a display name like "F#m" or "C".
    static func template(for name: String) -> [Float]? {
        var root = name
        var minor = false
        if root.hasSuffix("m") && !root.hasSuffix("dim") {
            minor = true
            root = String(root.dropLast())
        }
        guard let pc = noteIndex[root] else { return nil }
        var chroma = [Float](repeating: 0, count: 12)
        chroma[pc] = 1.0
        chroma[(pc + (minor ? 3 : 4)) % 12] = 0.9
        chroma[(pc + 7) % 12] = 0.9
        return chroma
    }

    func start(chordA: String, chordB: String) async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw NSError(domain: "Drill", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone access denied."])
        }
        guard let a = Self.template(for: chordA), let b = Self.template(for: chordB) else {
            throw NSError(domain: "Drill", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Unsupported chords for drilling."])
        }
        templates = [(chordA, a), (chordB, b)]
        changes = 0
        stable = nil
        candidate = nil

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let chroma = Self.chroma(from: buffer)
            Task { @MainActor in self.classify(chroma) }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false,
                                                       options: .notifyOthersOnDeactivation)
    }

    // MARK: - Signal

    private func classify(_ chroma: [Float]?) {
        guard let chroma else {  // silence / too quiet
            candidate = nil
            return
        }
        let scored = templates.map { ($0.name, Self.cosine(chroma, $0.chroma)) }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0.6 else {
            candidate = nil
            return
        }
        if candidate?.name != best.0 {
            candidate = (best.0, Date())
            return
        }
        // Require a quarter second of stability before accepting the chord.
        guard let candidate, Date().timeIntervalSince(candidate.since) > 0.25 else { return }
        if stable != candidate.name {
            if stable != nil { changes += 1 }
            stable = candidate.name
            current = candidate.name
        }
    }

    /// 12-bin chroma from a mono buffer; nil when the frame is near-silent.
    nonisolated static func chroma(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let data = buffer.floatChannelData?[0] else { return nil }
        let n = Int(buffer.frameLength)
        guard n >= 2048 else { return nil }
        let sampleRate = Float(buffer.format.sampleRate)

        var rms: Float = 0
        vDSP_rmsqv(data, 1, &rms, vDSP_Length(n))
        guard rms > 0.01 else { return nil }

        let log2n = vDSP_Length(floor(log2(Float(n))))
        let fftN = 1 << Int(log2n)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: fftN)
        vDSP_hann_window(&window, vDSP_Length(fftN), Int32(vDSP_HANN_NORM))
        var windowed = [Float](repeating: 0, count: fftN)
        vDSP_vmul(data, 1, window, 1, &windowed, 1, vDSP_Length(fftN))

        var real = [Float](repeating: 0, count: fftN / 2)
        var imag = [Float](repeating: 0, count: fftN / 2)
        var magnitudes = [Float](repeating: 0, count: fftN / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftN / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftN / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(fftN / 2))
            }
        }

        var chroma = [Float](repeating: 0, count: 12)
        let binHz = sampleRate / Float(fftN)
        for bin in 1..<(fftN / 2) {
            let freq = Float(bin) * binHz
            guard freq > 70, freq < 1100 else { continue }
            let midi = 69 + 12 * log2(freq / 440)
            let pc = ((Int(midi.rounded()) % 12) + 12) % 12
            chroma[pc] += magnitudes[bin]
        }
        var total: Float = 0
        vDSP_sve(chroma, 1, &total, 12)
        guard total > 0 else { return nil }
        return chroma.map { $0 / total }
    }

    nonisolated static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, 12)
        vDSP_svesq(a, 1, &na, 12)
        vDSP_svesq(b, 1, &nb, 12)
        guard na > 0, nb > 0 else { return 0 }
        return dot / (sqrt(na) * sqrt(nb))
    }
}
