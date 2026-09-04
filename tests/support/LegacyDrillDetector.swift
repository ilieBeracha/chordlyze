// Frozen pre-upgrade baseline from 91a0c69d516942728416328b25d9b550a67f0299.
// DSP, two-target threshold, dwell and stale-highlight behavior are preserved.
// Sample timestamps substitute for Date so offline playback has real-time timing.
// This file is benchmark-only and is not included in the iOS application.
import Accelerate
import AVFoundation
import Foundation

enum LegacyDrillDetector {
    static func template(for name: String) -> [Float]? {
        guard let notes = Chord(display: name)?.pitchClasses else { return nil }
        var chroma = [Float](repeating: 0, count: 12)
        for (index, pc) in notes.enumerated() {
            chroma[pc] = max(chroma[pc], index == 0 ? 1.0 : 0.9)  // root weighs most
        }
        return chroma
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
    static func analyze(_ audio: [Float], sampleRate: Double, chordA: String, chordB: String) -> [DrillSnapshot] {
        let templates = [(chordA, template(for: chordA)!), (chordB, template(for: chordB)!)]
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        var stable: String?
        var current: String?
        var candidate: (name: String, since: Double)?
        var changes = 0
        var frames: [DrillSnapshot] = []
        audio.withUnsafeBufferPointer { samples in
            for offset in stride(from: 0, to: samples.count, by: 4096) {
                let count = min(4096, samples.count - offset)
                buffer.frameLength = AVAudioFrameCount(count)
                buffer.floatChannelData![0].update(from: samples.baseAddress! + offset, count: count)
                let time = Double(offset + count) / sampleRate
                var evidence: DrillEvidence = .quiet
                if let chroma = chroma(from: buffer) {
                    let scored = templates.map { ($0.0, cosine(chroma, $0.1)) }
                    if let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0.6 {
                        evidence = .chord(best.0)
                        if candidate?.name != best.0 {
                            candidate = (best.0, time)
                        } else if let candidate, time - candidate.since > 0.25, stable != candidate.name {
                            if stable != nil { changes += 1 }
                            stable = candidate.name
                            current = candidate.name
                        }
                    } else { candidate = nil; evidence = .uncertain }
                } else { candidate = nil }
                frames.append(DrillSnapshot(time: time, evidence: evidence, current: current, changes: changes))
            }
        }
        return frames
    }
}
