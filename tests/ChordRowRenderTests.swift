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
                                onChordTap: { _ in }, wordPlayhead: playhead)
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
                let include = chords ? g > 112 && g > r * 1.8 && g > b * 1.3 : r > 70 && abs(r-g) < 5 && abs(r-b) < 5
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
    @MainActor static func assertMixedAnchors(_ image: CGImage, name: String, rtl: Bool = false) {
        let chords = glyphs(image, chords: true, rtl: rtl), words = glyphs(image, chords: false, rtl: rtl)
        check(chords.count == 6, "\(name): every chord must be visible once; found \(chords)")
        check(words.count == 4, "\(name): every word must be visible once; found \(words)")
        for (word, chord) in [0, 2, 4, 5].enumerated() {
            let c = chords[chord], w = words[word]
            let error = rtl ? abs(c.maxX - w.maxX) : abs(c.minX - w.minX)
            check(error <= 7, "\(name): chord \(chord) detached horizontally from word \(word): \(c) / \(w)")
            check(c.maxY < w.minY && w.minY-c.maxY < 42,
                  "\(name): chord and its word must wrap together: \(c) / \(w)")
        }
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
                    assertMixedAnchors(image, name: name)
                    images += 1
                }
            }
        }
        for time in [0.0, 2.3, 3, 5.2, 6.5] {
            let image = try render(row, width: 320, playhead: time)
            try save(image, to: output.appendingPathComponent("playing-\(time).png"))
            assertMixedAnchors(image, name: "playing \(time)")
            images += 1
        }
        for width in [280.0, 390] {
            let image = try render(mixedRow(rtl: true), width: width)
            try save(image, to: output.appendingPathComponent("rtl-\(Int(width)).png"))
            assertMixedAnchors(image, name: "RTL \(width)", rtl: true)
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
        print("Chord row rendering: \(checks) checks passed; \(images + 2) PNGs in \(output.path)")
    }
}
