import AppKit
import Combine
import Foundation
import SwiftUI

enum Config { static let backendBaseURL = URL(string: "http://127.0.0.1:1")! }
@MainActor final class SpotifyAuth {
    func validToken(rejecting: String? = nil) async throws -> String { fatalError("Render tests must not authenticate") }
}
// The app entry point owns this color; all row, chip, theme, layout and timing
// implementations below are compiled from the production sources.
extension Color { static let spotifyGreen = Color(red: 30 / 255, green: 215 / 255, blue: 96 / 255) }

@main struct ChordRowRenderTests {
    @MainActor static var checks = 0
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { fatalError(message) }
    }
    static func analysis(starts: [Double], labels: [String]) throws -> ChordAnalysis {
        let payload: [String: Any] = ["source": "youtube", "audio_duration": starts.last!,
            "chords": labels.indices.map { ["start": starts[$0], "end": starts[$0+1], "label": labels[$0]] }]
        return try JSONDecoder().decode(ChordAnalysis.self, from: JSONSerialization.data(withJSONObject: payload))
    }
    static func mixedRow(rtl: Bool = false) throws -> SheetModel.Row {
        let text = rtl ? ["שלום", "עולם", "שקט", "יחד"] : ["Alpha", "bravo", "charlie", "delta"]
        let starts = [0.0, 2.8, 5, 6], ends = [1.0, 3.5, 5.5, 8]
        let line = LyricLine(time: 0, text: text.joined(separator: " "), words: text.indices.map {
            WordStamp(time: starts[$0], text: text[$0], end: ends[$0]) })
        let chart = try analysis(starts: [0, 2, 2.7, 4, 5, 6, 8], labels: ["C:maj", "G:maj", "A:min", "F:maj", "D:min", "E:min"])
        return SheetModel.build(analysis: chart, lines: [line], duration: 8).first!
    }
    @MainActor static func render(_ row: SheetModel.Row, width: Double, style: ChordRowView.Style = .live,
                                  transpose: Int = 0, playhead: Double? = nil) throws -> CGImage {
        let view = ChordRowView(row: row, transposeBy: transpose, playhead: playhead, style: style,
                                onChordTap: { _ in })
            .padding(16).frame(width: width, alignment: .leading).background(.black)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { throw CocoaError(.coderInvalidValue) }
        check(image.width == Int(width * 2), "Rendered content must fit the requested phone width")
        return image
    }
    static func save(_ image: CGImage, to path: URL) throws {
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: path)
    }
    // Inspect actual rendered glyphs, not a second implementation of layout.
    // Authored fixtures use separated green chord names and neutral lyric words.
    static func glyphs(_ image: CGImage, chords: Bool, rtl: Bool = false) -> [CGRect] {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var columns = [[Int]](repeating: [], count: height)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let r = Double(pixels[i]), g = Double(pixels[i+1]), b = Double(pixels[i+2])
                // Inactive chord ink is 55% green; the 50% cursor is excluded
                // so its motion cannot be mistaken for another chord glyph.
                // Auxiliary time labels are secondary gray; read the brighter
                // lyric ink separately so captions cannot masquerade as words.
                let include = chords ? g > 112 && g > r * 1.8 && g > b * 1.3 : r > 175 && abs(r-g) < 5 && abs(r-b) < 5
                if include { columns[y].append(x) }
            }
        }
        func groups(_ values: [Int]) -> [[Int]] {
            var result: [[Int]] = []
            for value in values {
                if let last = result.last?.last, value - last <= 10 { result[result.count-1].append(value) }
                else { result.append([value]) }
            }
            return result
        }
        return groups((0..<height).filter { !columns[$0].isEmpty }).flatMap { band in
            let xs = Set(band.flatMap { columns[$0] }).sorted()
            let rects = groups(xs).map { xs in CGRect(x: xs.first!, y: band.first!,
                width: xs.last! - xs.first! + 1, height: band.last! - band.first! + 1) }
                .filter { !chords || ($0.width > 6 && $0.height > 8) } // Exclude the thin cursor and its rounded corners.
            return rtl ? Array(rects.reversed()) : rects
        }
    }
    @MainActor static func assertMixedSequence(_ image: CGImage, name: String, rtl: Bool = false) {
        let chords = glyphs(image, chords: true, rtl: rtl), words = glyphs(image, chords: false, rtl: rtl)
        check(chords.count == 6, "\(name): every chord must be visible once; found \(chords)")
        check(words.count == 4, "\(name): every word must be visible once; found \(words)")
        check(chords.map(\.maxY).max()! < words.map(\.minY).min()!,
              "\(name): mixed changes stay in one readable sequence, without guessed placement above words")
    }

    /// Check full-bright ink in the actual glyph bounds; a dim chord or the
    /// thin moving cursor must not count as a sounding chord or sung word.
    static func brightGlyphs(_ image: CGImage, bounds: [CGRect], chords: Bool) -> [Int] {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bounds.indices.filter { index in
            let rect = bounds[index]
            var bright = 0
            for y in max(0, Int(rect.minY))..<min(height, Int(rect.maxY)) {
                for x in max(0, Int(rect.minX))..<min(width, Int(rect.maxX)) {
                    let at = (y * width + x) * 4
                    let r = Int(pixels[at]), g = Int(pixels[at+1]), b = Int(pixels[at+2])
                    if chords ? g > 190 && g > r * 2 && g > b : r > 225 && abs(r-g) < 5 && abs(r-b) < 5 {
                        bright += 1
                    }
                }
            }
            return bright > 4
        }
    }

    static func neutralInk(_ image: CGImage, bounds: [CGRect]) -> [Int] {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bounds.map { rect in
            var ink = 0
            for y in max(0, Int(rect.minY))..<min(height, Int(rect.maxY)) {
                for x in max(0, Int(rect.minX))..<min(width, Int(rect.maxX)) {
                    let at = (y * width + x) * 4
                    let r = Int(pixels[at]), g = Int(pixels[at+1]), b = Int(pixels[at+2])
                    if abs(r-g) < 5 && abs(r-b) < 5 { ink += r }
                }
            }
            return ink
        }
    }

    @MainActor static func chordOnlyHighlightTests(output: URL) throws -> Int {
        let words = [WordStamp(time: 19.2, text: "Alpha", end: 19.8),
                     WordStamp(time: 20.5, text: "bravo", end: 22.5),
                     WordStamp(time: 24, text: "charlie", end: 24.4)]
        let chart = try analysis(starts: [18, 20, 21, 26], labels: ["C:maj", "G:maj", "F:maj"])
        let events = SheetModel.events(chart)
        let row = SheetModel.Row(start: 18, end: 26, kind: .lyric, text: "Alpha bravo charlie", words: words,
            chords: events.map { .init(event: $0, position: 0, wordIndex: nil) }, held: nil)
        let samples: [(Double, [Int])] = [(17.9, []), (19, [0]), (19.2, [0]), (19.8, [0]),
            (20, [1]), (20.7, [1]), (21.2, [2]), (22.5, [2]), (24.1, [2]), (24.4, [2]), (26, [])]
        var images = 0
        for width in [320.0, 390] {
            let reference = try render(row, width: width, playhead: 19)
            let wordBounds = glyphs(reference, chords: false), chordBounds = glyphs(reference, chords: true)
            let referenceInk = neutralInk(reference, bounds: wordBounds)
            check(wordBounds.count == 3 && chordBounds.count == 3, "Highlight fixture preserves all words and chords")
            check(referenceInk.allSatisfy { $0 > 1000 }, "Every lyric word stays readable")
            for (time, green) in samples {
                let image = try render(row, width: width, playhead: time)
                check(neutralInk(image, bounds: wordBounds) == referenceInk,
                      "Lyrics have identical brightness at \(time): no word glow, pulse, or active-line fade")
                check(brightGlyphs(image, bounds: chordBounds, chords: true) == green,
                      "Only the sounding chord is bright green at \(time), independently of vocals")
                try save(image, to: output.appendingPathComponent("chords-only-\(Int(width))-\(time).png"))
                images += 1
            }
            var partial = words; partial[1].estimated = true
            let uncertain = SheetModel.Row(start: row.start, end: row.end, kind: row.kind, text: row.text,
                words: partial, chords: row.chords, held: nil)
            let image = try render(uncertain, width: width, playhead: 21.2)
            check(neutralInk(image, bounds: wordBounds) == referenceInk,
                  "Estimated lyric timing cannot alter text brightness")
            check(brightGlyphs(image, bounds: chordBounds, chords: true) == [2],
                  "Estimated words cannot change the sounding chord")
            let lineOnly = SheetModel.Row(start: row.start, end: row.end, kind: row.kind, text: row.text,
                words: nil, chords: row.chords, held: nil)
            let before = try render(lineOnly, width: width, playhead: 19)
            let after = try render(lineOnly, width: width, playhead: 21.2)
            let lineBounds = glyphs(before, chords: false)
            check(neutralInk(before, bounds: lineBounds) == neutralInk(after, bounds: lineBounds),
                  "Line-only lyrics stay equally readable while chords change")
        }
        let opening = SheetModel.Row(start: 0, end: 2, kind: .instrumental, text: "", words: nil,
            chords: [.init(event: .init(start: 0, end: 2, chord: Chord(display: "C")), position: 0, wordIndex: nil)], held: nil)
        let atOnset = try render(opening, width: 320, playhead: 0)
        let beforeOnset = try render(opening, width: 320, playhead: -0.5)
        let bounds = glyphs(atOnset, chords: true)
        check(brightGlyphs(beforeOnset, bounds: bounds, chords: true).isEmpty,
              "Negative calibrated chart time must not light the opening chord early")
        check(brightGlyphs(atOnset, bounds: bounds, chords: true) == [0], "The opening chord lights at its actual onset")
        return images
    }
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/chordlyze-alignment-renders")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let row = try mixedRow()
        check(row.chords.map(\.wordIndex) == [0, nil, 1, nil, 2, 3], "Fixture must exercise mixed associations")
        var images = 0
        for style in [ChordRowView.Style.sheet, .live] {
            for width in [280.0, 320, 390, 464] {
                for transpose in [0, 2] {
                    let name = "mixed-\(style)-\(Int(width))-transpose-\(transpose)"
                    let image = try render(row, width: width, style: style, transpose: transpose)
                    try save(image, to: output.appendingPathComponent(name + ".png"))
                    assertMixedSequence(image, name: name)
                    images += 1
                }
            }
        }
        for time in [0.0, 2.3, 3, 5.2, 6.5] {
            let image = try render(row, width: 320, playhead: time)
            try save(image, to: output.appendingPathComponent("playing-\(time).png"))
            assertMixedSequence(image, name: "playing \(time)")
            images += 1
        }
        for width in [280.0, 390] {
            let image = try render(mixedRow(rtl: true), width: width)
            try save(image, to: output.appendingPathComponent("rtl-\(Int(width)).png"))
            assertMixedSequence(image, name: "RTL \(width)", rtl: true)
            images += 1
        }
        // Partial timing retains every model anchor. Its visible chord changes
        // stay in one explicit sequence instead of two competing reading paths.
        let partialLine = LyricLine(time: 0, text: "Alpha bravo charlie delta", words: [
            WordStamp(time: 0, text: "Alpha", end: 1),
            WordStamp(time: 4, text: "bravo", end: 4.4),
            WordStamp(time: 3, text: "charlie", end: 3.4),
            WordStamp(time: 6, text: "delta", end: 8)])
        let partialChart = try analysis(starts: [0, 2, 4, 6, 8], labels: ["C:maj", "G:maj", "F:maj", "E:min"])
        let partialRow = SheetModel.build(analysis: partialChart, lines: [partialLine], duration: 8).first!
        check(partialRow.chords.map(\.wordIndex) == [0, nil, nil, 3], "Only supported words anchor the partial phrase")
        for width in [280.0, 320, 390, 464] {
            let image = try render(partialRow, width: width)
            let chords = glyphs(image, chords: true), words = glyphs(image, chords: false)
            check(chords.count == 4 && words.count == 4, "A partial phrase keeps every word and chord")
            check(chords.map(\.maxY).max()! < words.map(\.minY).min()!,
                  "Partial timing uses one chronological chord sequence above intact lyrics")
            try save(image, to: output.appendingPathComponent("partial-word-timing-\(Int(width)).png"))
            images += 1
        }
        let crowded = try analysis(starts: Array(0...12).map(Double.init), labels: Array(repeating: "F#:min7", count: 12))
        let long = LyricLine(time: 0, text: "Supercalifragilisticexpialidocious", words: [WordStamp(time: 0, text: "Supercalifragilisticexpialidocious", end: 8)])
        let dense = SheetModel.build(analysis: crowded, lines: [long], duration: 12).first!
        let denseImage = try render(dense, width: 280)
        try save(denseImage, to: output.appendingPathComponent("oversized-word-and-chords.png"))
        check(glyphs(denseImage, chords: true).allSatisfy { $0.minX >= 30 && $0.maxX <= 530 }, "Dense changes must stay inside the padded viewport")
        let lineOnly = SheetModel.Row(start: row.start, end: row.end, kind: row.kind, text: row.text,
            words: nil, chords: row.chords.map { .init(event: $0.event, position: $0.position, wordIndex: nil) }, held: row.held)
        let fallback = try render(lineOnly, width: 280)
        try save(fallback, to: output.appendingPathComponent("line-timing-only.png"))
        check(glyphs(fallback, chords: true).count == 6 && glyphs(fallback, chords: false).count == 4,
              "Line-only fallback must keep all words and changes")
        // Authored words with the verified no-catalog intro geometry. The old
        // malformed onset put six instrumental changes above this lyric.
        let introChart = try analysis(starts: [0, 0.74, 4.68, 8.58, 12.52, 16.44, 20.9, 24.32, 27.48],
            labels: ["N", "D#:maj", "C#:maj", "F:min", "D#:maj", "A#:min7", "F:min", "D#:maj"])
        let introWords = ["We", "could", "walk", "along", "this", "shore"]
        let introTimes = [18.6, 20, 20.14, 20.98, 23.32, 23.86]
        let introEnds = [20.0, 20.4, 20.98, 23.32, 23.86, 25.68]
        let recoveredLine = LyricLine(time: 18.6, text: introWords.joined(separator: " "), words: introWords.indices.map {
            WordStamp(time: introTimes[$0], text: introWords[$0], end: introEnds[$0]) })
        let recoveredRows = SheetModel.build(analysis: introChart, lines: [recoveredLine], duration: 27.48)
        let vocal = recoveredRows.first { !$0.text.isEmpty }!
        check(vocal.start == 18.6 && vocal.chords.map(\.wordIndex) == [2, 5], "Recovered intro keeps only vocal changes over the lyric")
        check(recoveredRows.filter { $0.text.isEmpty }.flatMap(\.chords).count == 6, "All six intro changes remain before the vocal")
        check(recoveredRows.flatMap(\.chords).map(\.event) == SheetModel.events(introChart), "Recovered intro preserves the entire musical timeline")
        for width in [280.0, 320, 390, 464] {
            let image = try render(vocal, width: width)
            let chords = glyphs(image, chords: true), words = glyphs(image, chords: false)
            check(chords.count == 3 && words.count == 6, "Recovered phrase retains each word, vocal change and held entrance cue")
            for (chord, word) in [2, 5].enumerated() {
                check(abs(chords[chord + 1].minX - words[word].minX) <= 7, "Recovered onset preserves chord/word placement")
                check(chords[chord + 1].maxY < words[word].minY && words[word].minY - chords[chord + 1].maxY < 42,
                      "Recovered words and their chords wrap together")
            }
            try save(image, to: output.appendingPathComponent("recovered-intro-\(Int(width)).png"))
            images += 1
        }
        // Guessed word positions must have no effect on chord placement. Keep
        // exact chord timestamps while changing every presentation estimate.
        let estimatedChart = try analysis(starts: [0, 1.18, 2.36, 3.54, 4.72, 9], labels: ["B:min", "C#:min", "E:maj", "F#:min", "D:maj"])
        let estimatedWords = ["Alpha", "bravo", "charlie", "delta"]
        func estimatedRow(_ times: [Double]) -> SheetModel.Row {
            let words = estimatedWords.indices.map { WordStamp(time: times[$0], text: estimatedWords[$0], estimated: true) }
            return SheetModel.build(analysis: estimatedChart, lines: [LyricLine(time: 0,
                text: estimatedWords.joined(separator: " "), words: words)], duration: 9).first!
        }
        for width in [280.0, 320, 390, 464] {
            let early = try render(estimatedRow([0, 1, 2, 3]), width: width, playhead: 2.5)
            let late = try render(estimatedRow([0, 6, 7, 8]), width: width, playhead: 2.5)
            check(glyphs(early, chords: true) == glyphs(late, chords: true), "Estimated word times cannot move a chord glyph")
            check(glyphs(early, chords: false) == glyphs(late, chords: false), "Estimated word times cannot insert gaps in lyrics")
            check(glyphs(early, chords: true).count == 5 && glyphs(early, chords: false).count == 4,
                  "Unknown word placement preserves the full chord sequence and every lyric word")
            let bounds = glyphs(early, chords: true)
            check(brightGlyphs(early, bounds: bounds, chords: true) == [2], "Estimated text cannot affect the exact sounding chord")
            try save(early, to: output.appendingPathComponent("estimated-sequence-\(Int(width)).png"))
            images += 1
        }
        check(ChordRowView.timestamp(32.37) == "0:32.37" && ChordRowView.timestamp(59.999) == "1:00.00",
              "Chord timestamps distinguish nearby changes and carry minutes correctly")
        // The fully-unsynced presentation has a separate real-time chord
        // summary and plain lyrics. It never places chords over guessed words.
        for width in [280.0, 390] {
            let lyric = SheetModel.Row(start: 0, end: 9, kind: .lyric,
                text: estimatedWords.joined(separator: " "), words: nil, chords: [], held: nil)
            let view = VStack(alignment: .leading, spacing: 24) {
                IndependentChordSummary(events: SheetModel.events(estimatedChart), position: 2.5,
                                        onChordTap: { _ in })
                ChordRowView(row: lyric, playhead: 2.5, style: .live)
            }
            .padding(16).frame(width: width, alignment: .leading).background(.black)
            .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage else { throw CocoaError(.coderInvalidValue) }
            let chords = glyphs(image, chords: true), words = glyphs(image, chords: false)
            check(chords.count == 2 && words.count == 4, "Unsynced lyrics show only independent current/next chords")
            check(brightGlyphs(image, bounds: chords, chords: true) == [0], "Only current chord is bright in the independent summary")
            check(chords.map(\.maxY).max()! < words.map(\.minY).min()!, "Current/next guidance remains separate from untimed lyric text")
            try save(image, to: output.appendingPathComponent("independent-summary-\(Int(width)).png"))
            images += 1
        }
        images += try chordOnlyHighlightTests(output: output)
        print("Chord row rendering: \(checks) checks passed; \(images + 2) PNGs in \(output.path)")
    }
}
