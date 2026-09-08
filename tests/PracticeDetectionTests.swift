import Foundation

enum Config { static let backendBaseURL = URL(string: "http://127.0.0.1:1")! }

@main struct PracticeDetectionTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { fatalError(message) }
        }
        for sampleRate in [44100.0, 48000.0] {
            for pace in [0.5, 1.0] {
                for gain: Float in [1, 0.02] {
                    let notes = [[45,52,57,60,64], [48,52,55,60,64], [43,47,50,55,59,67]]
                    let audio = [Float](repeating: 0, count: Int(sampleRate))
                        + render(notes, strum: 0.025, release: 0.5, gap: 0, sr: sampleRate).map { $0 * gain }
                    let chords = ["A:min", "C:maj", "G:maj"].enumerated().map { index, label in
                        ChordSegment(start: (1 + Double(index) * 1.6) * pace,
                                     end: (1 + Double(index + 1) * 1.6) * pace, label: label, roman: nil)
                    }
                    var feedback = PracticeFeedback(chords: chords, start: 0, end: 5.8 * pace)
                    let detector = try ChordDrillDetector(sampleRate: sampleRate, mode: .practiceFeedback)
                    audio.withUnsafeBufferPointer { buffer in
                        for offset in stride(from: 0, to: audio.count, by: 1024) {
                            let frames = detector.append(.init(start: buffer.baseAddress! + offset,
                                                               count: min(1024, audio.count - offset)), sampleTime: Int64(offset))
                            for frame in frames {
                                feedback.observe(current: frame.current, chartTime: frame.time * pace, chartRate: pace,
                                                 recognizedAt: frame.recognizedAt.map { $0 * pace }, detectorLatency: frame.latency)
                            }
                        }
                    }
                    check(feedback.hits == 3, "Actual practice detector must recognize Am/C/G at gain \(gain), pace \(pace), rate \(sampleRate)")
                    check(feedback.judged.count == 3, "Transition mixtures cannot add extra practice judgments")
                    for entry in feedback.judged {
                        guard case .hit(let offset) = entry.verdict else { fatalError("Expected actual observed change") }
                        check(abs(offset) < 0.5, "Longer confirmation must not be reported as an artificial late strum")
                    }
                }
            }
        }
        print("Practice audio integration: \(checks)/\(checks) checks passed")
    }
}
