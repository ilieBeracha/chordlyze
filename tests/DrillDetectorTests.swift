import AVFoundation
import Foundation

private var failures = 0
private var checks = 0
private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { failures += 1; print("FAIL: \(message)") }
}

private func tone(_ notes: [Int], sr: Double, duration: Double = 1.3,
                  harmonics: Int = 6, gain: Double = 0.16, cents: Double = 0,
                  strum: Double = 0, decay: Double = 0) -> [Float] {
    let count = Int(sr * duration)
    var result = [Float](repeating: 0, count: count)
    for (index, note) in notes.enumerated() {
        let frequency = 440 * pow(2, (Double(note - 69) + cents / 100) / 12)
        for i in 0..<count {
            let time = Double(i) / sr - Double(index) * strum
            guard time >= 0 else { continue }
            var sample = 0.0
            for harmonic in 1...harmonics {
                sample += sin(2 * .pi * frequency * Double(harmonic) * time) / Double(harmonic)
            }
            result[i] += Float(sample * exp(-decay * time) * gain / Double(max(1, notes.count)))
        }
    }
    return result
}

private func feed(_ detector: ChordDrillDetector, _ audio: [Float], start: Int64 = 0,
                  block: Int = 1024) -> [DrillSnapshot] {
    var output: [DrillSnapshot] = []
    audio.withUnsafeBufferPointer { samples in
        for offset in stride(from: 0, to: samples.count, by: block) {
            let count = min(block, samples.count - offset)
            output += detector.append(UnsafeBufferPointer(start: samples.baseAddress! + offset, count: count),
                                      sampleTime: start + Int64(offset))
        }
    }
    return output
}

@main
struct DrillDetectorTests {
    static func main() throws {
        if CommandLine.arguments.count >= 2 {
            try analyzeManifest(CommandLine.arguments[1], legacy: CommandLine.arguments.contains("--legacy"))
            return
        }
        for sr in [44100.0, 48000.0] {
            let detector = try ChordDrillDetector(sampleRate: sr, chordA: "C", chordB: "Am")
            let rejectionCases: [(String, [Int], Int)] = [
                ("F guitar voicing", [41,45,48,53,57,60], 6),
                ("Em guitar voicing", [40,47,52,55,59,64], 6),
                ("single sine", [60], 1), ("single note overtones", [60], 8),
                ("dyad", [48,52], 6), ("silence", [], 1)
            ]
            for (name, notes, harmonics) in rejectionCases {
                detector.reset()
                let frames = feed(detector, tone(notes, sr: sr, harmonics: harmonics))
                check(frames.allSatisfy { $0.current == nil }, "\(sr) \(name) must not accept C or Am")
                check(detector.changes == 0, "\(name) must not count changes")
            }
            var generator: UInt64 = 73491
            let noise: [Float] = (0..<Int(sr * 1.3)).map { _ in
                generator = generator &* 6364136223846793005 &+ 1
                return (Float(generator >> 40) / Float(1 << 24) - 0.5) * 0.25
            }
            detector.reset()
            check(feed(detector, noise).allSatisfy { $0.current == nil }, "\(sr) white noise rejects")
            for (name, notes) in [("C", [48,52,55]), ("Am", [45,48,52])] {
                for cents in [-30.0, 0, 30] {
                    detector.reset()
                    let frames = feed(detector, tone(notes, sr: sr, cents: cents))
                    check(frames.last?.current == name, "\(sr) \(name) at \(cents) cents recognized")
                    check(frames.compactMap(\.current).allSatisfy { $0 == name }, "\(name) never becomes its rival")
                }
            }
            detector.reset()
            let c = tone([48,52,55], sr: sr)
            let a = tone([45,48,52], sr: sr)
            let sequence = c + a + c
            let frames = feed(detector, sequence)
            check(detector.changes == 2, "\(sr) C–Am–C counts exactly two changes (got \(detector.changes))")
            for (boundary, name) in [(1.3, "Am"), (2.6, "C")] {
                let event = frames.first { $0.time > boundary && $0.current == name }
                check(event != nil && event!.time - boundary < 0.75, "\(sr) \(name) accepted within 750 ms")
            }
            let end = Int64(sequence.count)
            let silent = feed(detector, [Float](repeating: 0, count: Int(sr * 0.15)), start: end)
            check(silent.last?.current == nil, "silence clears the highlighted chord promptly")
            check(detector.changes == 2, "silence preserves the score")
            detector.reset()
            _ = feed(detector, c)
            _ = feed(detector, [Float](repeating: 0, count: Int(sr * 0.2)), start: Int64(c.count))
            _ = feed(detector, c, start: Int64(c.count + Int(sr * 0.2)))
            check(detector.changes == 0, "repeated strums of one chord never count as a change")
            detector.reset()
            _ = feed(detector, c)
            let rest = [Float](repeating: 0, count: Int(sr * 0.25))
            _ = feed(detector, rest, start: Int64(c.count))
            let singleAfterRest = feed(detector, tone([48], sr: sr, duration: 0.4), start: Int64(c.count + rest.count))
            check(singleAfterRest.allSatisfy { $0.current == nil }, "a single note after a rest cannot inherit the previous chord")
            let gap = feed(detector, Array(a.prefix(1024)), start: Int64(sr * 10))
            check(detector.current == nil && gap.allSatisfy { $0.current == nil }, "a dropped-audio gap invalidates old pitch evidence")
            detector.reset()
            check(detector.current == nil && detector.changes == 0, "reset clears display and score")

            // Buffer boundaries and processing speed do not alter musical time.
            let alternate = try ChordDrillDetector(sampleRate: sr, chordA: "C", chordB: "Am")
            check(feed(alternate, sequence, block: 333) == frames, "\(sr) arbitrary tap sizes give identical events")
            let quiet = try ChordDrillDetector(sampleRate: sr, chordA: "C", chordB: "Am")
            check(feed(quiet, tone([48,52,55], sr: sr, gain: 0.008)).last?.current == "C", "quiet clean chords recognized")
            let strummed = try ChordDrillDetector(sampleRate: sr, chordA: "C", chordB: "Am")
            check(feed(strummed, tone([48,52,55,60,64], sr: sr, strum: 0.018, decay: 0.7)).last?.current == "C", "guitar strum and decay recognized")

            for (label, notes, rival) in [("Cmaj7", [48,52,55,59], "G7"),
                                          ("Dm7", [50,53,57,60], "G7"),
                                          ("Gsus4", [43,48,50], "C"),
                                          ("G7", [43,47,50,53], "Cmaj7")] {
                let rich = try ChordDrillDetector(sampleRate: sr, chordA: label, chordB: rival)
                check(feed(rich, tone(notes, sr: sr)).last?.current == label, "\(sr) extended chord \(label)")
            }
            let seventh = try ChordDrillDetector(sampleRate: sr, chordA: "Cmaj7", chordB: "G7")
            check(feed(seventh, c).allSatisfy { $0.current == nil }, "plain C does not satisfy Cmaj7")
            let mixed = zip(tone([48], sr: sr, gain: 0.05, cents: -15),
                            zip(tone([52], sr: sr, gain: 0.05, cents: 15), tone([55], sr: sr, gain: 0.05))).map { $0 + $1.0 + $1.1 }
            detector.reset()
            check(feed(detector, mixed).last?.current == "C", "moderate string-to-string tuning differences are tolerated")
            detector.reset()
            let wrong = tone([41,45,48,53,57,60], sr: sr)
            _ = feed(detector, c + wrong + c)
            check(detector.changes == 0, "a wrong chord between repeated C strums never earns a change")
            detector.reset()
            check(feed(detector, [Float](repeating: .nan, count: 8192)).allSatisfy { $0.current == nil }, "nonfinite input is rejected safely")
        }
        for (a,b) in [("C","C/E"), ("Ab","G#"), ("Am7","C6")] {
            do {
                _ = try ChordDrillDetector(sampleRate: 44100, chordA: a, chordB: b)
                check(false, "indistinguishable pair \(a)/\(b) should reject")
            } catch DrillConfigurationError.indistinguishableChords { check(true, "indistinguishable pair") }
        }
        for chord in ["", "N.C.", "Cunknown", "/E"] {
            do {
                _ = try ChordDrillDetector(sampleRate: 44100, chordA: chord, chordB: "G")
                check(false, "invalid chord \(chord) should reject")
            } catch DrillConfigurationError.unsupportedChord { check(true, "invalid chord rejected") }
        }
        for rate in [0.0, -1, .nan, .infinity, 192000] {
            do {
                _ = try ChordDrillDetector(sampleRate: rate, chordA: "C", chordB: "G")
                check(false, "invalid sample rate should reject")
            } catch DrillConfigurationError.unsupportedSampleRate { check(true, "invalid rate rejected") }
        }
        print("Drill detector: \(checks - failures)/\(checks) checks passed")
        if failures > 0 { exit(1) }
    }

    /// A public-data benchmark invokes the exact same production streaming core.
    /// Manifest rows contain path, id, targetA, targetB, and optional start/end.
    private static func analyzeManifest(_ path: String, legacy: Bool) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let items = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        var results: [[String: Any]] = []
        for item in items {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: item["path"] as! String))
            let sr = file.processingFormat.sampleRate
            let start = item["start"] as? Double ?? 0
            let end = item["end"] as? Double ?? Double(file.length) / sr
            file.framePosition = AVAudioFramePosition(start * sr)
            let count = AVAudioFrameCount((end - start) * sr)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
            try file.read(into: buffer, frameCount: count)
            let audio = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            let detector = try ChordDrillDetector(sampleRate: sr, chordA: item["targetA"] as! String,
                                                 chordB: item["targetB"] as! String)
            let began = ProcessInfo.processInfo.systemUptime
            let frames = legacy ? LegacyDrillDetector.analyze(audio, sampleRate: sr,
                                                              chordA: item["targetA"] as! String,
                                                              chordB: item["targetB"] as! String) : feed(detector, audio)
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            let rows: [[String: Any]] = frames.map { frame in
                let label: String
                switch frame.evidence {
                case .quiet: label = "quiet"
                case .uncertain: label = "uncertain"
                case .chord(let chord): label = chord
                }
                return ["time": frame.time + start, "heard": label,
                        "accepted": frame.current as Any? ?? NSNull(), "changes": frame.changes]
            }
            results.append(["id": item["id"]!, "sample_rate": sr, "processing_seconds": elapsed, "frames": rows])
        }
        let output = try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])
        FileHandle.standardOutput.write(output)
    }
}
