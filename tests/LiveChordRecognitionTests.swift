import Foundation

func render(_ chords: [[Int]], strum: Double, release: Double, gap: Double, sr: Double, step: Double = 1.6) -> [Float] {
    var audio = [Float](repeating: 0, count: Int((Double(chords.count)*step+release+0.4)*sr))
    for (chordIndex, notes) in chords.enumerated() {
        for (stringIndex, note) in notes.enumerated() {
            let onset = Double(chordIndex)*step+Double(stringIndex)*strum
            let releaseAt = Double(chordIndex+1)*step-gap
            let frequency = 440*pow(2,Double(note-69)/12)
            for i in max(0,Int(onset*sr))..<min(audio.count, Int((releaseAt+release)*sr)) {
                let time = Double(i)/sr
                let age = time-onset
                guard age >= 0 else { continue }
                let tail = time < releaseAt ? 1 : (release > 0 ? exp(-6*(time-releaseAt)/release) : 0)
                let envelope = min(1,age/0.008)*exp(-0.6*age)*tail
                var value = 0.0
                for harmonic in 1...6 {
                    value += sin(2 * .pi * frequency * Double(harmonic) * age)/Double(harmonic)
                }
                audio[i] += Float(value*envelope*0.14/Double(notes.count))
            }
        }
    }
    return audio
}

private func feed(_ detector: ChordDrillDetector, _ audio: [Float], start: Int64 = 0) -> [DrillSnapshot] {
    var result: [DrillSnapshot] = []
    audio.withUnsafeBufferPointer { samples in
        for offset in stride(from: 0, to: samples.count, by: 1024) {
            result += detector.append(.init(start: samples.baseAddress! + offset, count: min(1024, samples.count-offset)),
                                      sampleTime: start + Int64(offset))
        }
    }
    return result
}
private func history(_ frames: [DrillSnapshot]) -> [String] {
    frames.compactMap(\.current).reduce(into: []) { if $0.last != $1 { $0.append($1) } }
}
private var checks = 0
private func check(_ value: Bool, _ message: String) {
    checks += 1
    if !value { fatalError(message) }
}

@main struct LiveChordRecognitionTests {
    private static func sensitivityTests() throws {
        for sr in [44100.0, 48000.0] {
            func scaled(_ input: [Float], rms: Float) -> [Float] {
                let sample = input[Int(sr*0.08)..<Int(sr*0.18)]
                let actual = sqrt(sample.reduce(Float(0)) { $0 + $1*$1 } / Float(sample.count))
                return input.map { $0 * rms / actual }
            }
            for (label, notes) in [("Am", [45,52,57,60,64]), ("C", [48,52,55,60,64]), ("G", [43,47,50,55,59,67])] {
                for decay in [0.0, 3.0] {
                    let raw = render([notes], strum: 0.02, release: 0.2, gap: 0, sr: sr).enumerated().map { i, value in
                        value * Float(exp(-decay * Double(i)/sr))
                    }
                    for level: Float in [0.002, 0.001, 0.0005] {
                        let frames = feed(try ChordDrillDetector(sampleRate: sr, mode: .liveRecognition), scaled(raw, rms: level))
                        check(history(frames) == [label], "Soft/fading \(label) at \(sr), RMS \(level), decay \(decay): \(history(frames))")
                        check((frames.first { $0.current == label }?.time ?? 99) < 0.85, "Soft-chord confirmation remains bounded")
                        check(frames.last?.current == nil, "A fading chord eventually clears")
                    }
                }
            }
            var seed: UInt64 = 24601
            let noise: [Float] = (0..<Int(sr*2)).map { _ in
                seed = seed &* 6364136223846793005 &+ 1
                return (Float(seed >> 40) / Float(1 << 24) - 0.5) * sqrt(12)
            }
            for rms: Float in [0.00005, 0.0002, 0.002, 0.02] {
                let frames = feed(try ChordDrillDetector(sampleRate: sr, mode: .liveRecognition), noise.map { $0*rms })
                check(history(frames).isEmpty, "More sensitive input must not turn background noise into chords")
            }
            // Noise learning must allow a later soft chord with a clear signal-to-noise ratio.
            let detector = try ChordDrillDetector(sampleRate: sr, mode: .liveRecognition)
            let background = noise.map { $0*0.00005 }
            check(history(feed(detector, background)).isEmpty, "Calibration noise stays out of history")
            let tone = scaled(render([[48,52,55]], strum: 0.02, release: 0.2, gap: 0, sr: sr), rms: 0.0005)
            let mixture = tone.enumerated().map { i, sample in sample + background[i % background.count] }
            check(history(feed(detector, mixture, start: Int64(background.count))) == ["C"], "Soft chord remains detectable over learned low room noise")
            // A muted brief strum must not be confirmed from stale FFT content after it ends.
            let abrupt = Array(scaled(render([[48,52,55]], strum: 0, release: 0, gap: 0, sr: sr), rms: 0.004).prefix(Int(sr*0.5)))
            let stopped = abrupt + noise.map { $0*0.0002 }
            check(history(feed(try ChordDrillDetector(sampleRate: sr, mode: .liveRecognition), stopped)).isEmpty,
                  "A muted candidate cannot finish confirmation on residual window content plus noise")
            let single = scaled(render([[48]], strum: 0, release: 0.2, gap: 0, sr: sr), rms: 0.0005)
            check(history(feed(try ChordDrillDetector(sampleRate: sr, mode: .liveRecognition), single)).isEmpty,
                  "Soft single notes remain rejected")
        }
    }

    static func main() throws {
        let progression = [[45,52,57,60,64], [48,52,55,60,64], [43,47,50,55,59,67]]
        for sr in [44100.0, 48000.0] {
            for (name,strum,release,gap) in [("clean",0.0,0.0,0.0), ("separated",0.025,0.0,0.25),
                ("short release",0.025,0.2,0.0), ("ringing",0.025,0.5,0.0),
                ("slow strum",0.06,0.5,0.0), ("long release",0.035,0.9,0.0)] {
                let detector = try ChordDrillDetector(sampleRate: sr, mode: .liveRecognition)
                let audio = render(progression, strum: strum, release: release, gap: gap, sr: sr)
                let frames = feed(detector, audio)
                let labels = history(frames)
                check(labels == ["Am", "C", "G"], "\(sr) \(name): unexpected history \(labels)")
                check(detector.changes == 2, "Each played change counts once")
                check(frames.last?.current == nil, "Silence clears the current chord")
                var candidate: (String, Double)?
                for frame in frames {
                    if case .chord(let name) = frame.evidence {
                        if candidate?.0 != name { candidate = (name, frame.time) }
                    } else { candidate = nil }
                    if let current = frame.current {
                        check(candidate?.0 == current && frame.time - candidate!.1 >= 0.25,
                              "An unconfirmed candidate must never reach history")
                    }
                }
            }
            // Do not 'fix' transitions by excluding extensions from the vocabulary.
            for (name, notes) in [("F7",[41,45,48,51]), ("Cmaj7",[48,52,55,59]), ("D7",[50,54,57,60]), ("Cm",[48,51,55]), ("Dm9",[50,53,57,60,64]), ("C°7",[48,51,54,57])] {
                let detector = try ChordDrillDetector(sampleRate: sr, mode: .liveRecognition)
                let frames = feed(detector, render([notes], strum: 0.025, release: 0.2, gap: 0, sr: sr))
                check(history(frames) == [name], "Genuine \(name) must still be recognized: \(history(frames))")
                check((frames.first { $0.current == name }?.time ?? 99) < 0.85, "Held chord latency remains bounded")
            }
            let extensions = try ChordDrillDetector(sampleRate: sr, mode: .liveRecognition)
            let genuineChanges = render([[48,52,55], [48,52,55,59], [48,52,55]], strum: 0.025, release: 0.2, gap: 0, sr: sr)
            check(history(feed(extensions, genuineChanges)) == ["C", "Cmaj7", "C"], "A sustained real extension still changes the displayed chord")
            for transient in [[41,45,48,51], [48,52,55,59], [50,53,57,60,64], [48,51,54,57], [48,51,55]] {
                func hold(_ notes: [Int], _ seconds: Double) -> [Float] {
                    Array(render([notes], strum: 0, release: 0, gap: 0, sr: sr, step: seconds).prefix(Int(sr*seconds)))
                }
                let signal = hold([48,52,55], 1.2) + hold(transient, 0.12) + hold([48,52,55], 1.2)
                let detector = try ChordDrillDetector(sampleRate: sr, mode: .liveRecognition)
                check(history(feed(detector, signal)) == ["C"], "Brief alternate-chord bursts must not pollute sustained C history")
            }
            let detector = try ChordDrillDetector(sampleRate: sr, mode: .liveRecognition)
            let quick = render(progression, strum: 0.025, release: 0.2, gap: 0, sr: sr, step: 1.0)
            check(history(feed(detector, quick)) == ["Am", "C", "G"], "One-second chord changes remain usable")
            detector.reset()
            check(detector.current == nil && detector.changes == 0, "Restart removes prior recognition")
            let short = Array(render([[48,52,55]],strum:0,release:0,gap:0,sr:sr).prefix(Int(sr*0.5)))
            let beforeGap = feed(detector, short)
            check(history(beforeGap).isEmpty, "Brief candidate isn't accepted")
            let afterGap = feed(detector, short, start: Int64(sr*2))
            check(history(afterGap).isEmpty, "Dropped audio cannot complete a prior candidate's confirmation")
        }
        try sensitivityTests()
        // The fast policy remains the default used by practice scoring and existing drills.
        let legacy = try ChordDrillDetector(sampleRate: 44100)
        let explicit = try ChordDrillDetector(sampleRate: 44100, mode: .practiceFeedback)
        let audio = render(progression,strum:0,release:0,gap:0,sr:44100)
        let a = feed(legacy,audio), b = feed(explicit,audio)
        check(history(a) == history(b), "Default practice behavior is preserved")
        check(a.map(\.recognizedAt) == b.map(\.recognizedAt), "Practice acceptance timestamps are unchanged")
        print("Live recognition: \(checks)/\(checks) checks passed")
    }
}
