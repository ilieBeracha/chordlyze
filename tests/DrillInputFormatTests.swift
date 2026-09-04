import Foundation

@main
struct DrillInputFormatTests {
    static func main() throws {
        var checks = 0
        for rate in [32000.0, 96000.0] {
            let cases = [("C", [48,52,55]), ("Am", [45,48,52]), ("F", [41,45,48,53,57,60])]
            for (name, notes) in cases {
                let detector = try ChordDrillDetector(sampleRate: rate, chordA: "C", chordB: "Am")
                let audio: [Float] = (0..<Int(rate * 1.2)).map { index in
                    let t = Double(index) / rate
                    return notes.reduce(Float(0)) { sum, note in
                        let f = 440 * pow(2, Double(note - 69) / 12)
                        return sum + (1...6).reduce(Float(0)) { $0 + Float(sin(2 * .pi * f * Double($1) * t) / Double($1) * 0.02) }
                    }
                }
                let frames = audio.withUnsafeBufferPointer { detector.append($0, sampleTime: 0) }
                if name == "F" {
                    guard frames.allSatisfy({ $0.current == nil }) else { fatalError("\(rate): false target acceptance") }
                } else {
                    guard frames.last?.current == name else { fatalError("\(rate): \(name) missed") }
                }
                checks += 1
            }
        }
        print("Drill input formats: \(checks)/\(checks) checks passed")
    }
}
