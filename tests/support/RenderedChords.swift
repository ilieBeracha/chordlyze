import Foundation

// Deterministic strums with controllable string onsets and release overlap.
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

