import Foundation
import AVFoundation

// Compile the production cache/status and player against the same backend models.
enum Config { static let backendBaseURL = URL(string: "http://127.0.0.1:1")! }
@MainActor final class SpotifyAuth { func validToken(rejecting: String? = nil) async throws -> String { fatalError("No auth in tests") } }

@main struct StemPlayerTests {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        func file(_ name: String, seconds: Int) throws -> URL {
            let url = folder.appendingPathComponent(name+".caf")
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(44100*seconds))!
            buffer.frameLength = buffer.frameCapacity
            for channel in 0..<2 {
                for index in 0..<Int(buffer.frameLength) {
                    buffer.floatChannelData![channel][index] = Float(sin(Double(index)*2*Double.pi*220/44100)) * 0.01
                }
            }
            let output = try AVAudioFile(forWriting: url, settings: format.settings)
            try output.write(from: buffer)
            return url
        }
        let first = try file("solo", seconds: 4), second = try file("backing", seconds: 4)
        let short = try file("short", seconds: 2)
        let player = StemPlayer()
        do { try player.load(solo: first, backing: short); fatalError("Accepted mismatched durations") }
        catch is IsolationError { }
        try player.load(solo: first, backing: second)
        precondition(player.ready && abs(player.duration-4) < 0.001)
        player.seek(1.5)
        player.mix = .solo; player.mix = .backing; player.mix = .full
        precondition(abs(player.position-1.5) < 0.001, "Mix switching moved the playhead")
        player.speed = 0.75
        precondition(abs(player.position-1.5) < 0.001, "Speed changes lost paused position")
        player.seek(-10); precondition(player.position == 0)
        player.seek(99); precondition(player.position == 4)
        player.seek(1)
        player.play()
        precondition(player.isPlaying, "Audio did not start")
        player.tick()
        precondition(player.isPlaying, "Scheduled start was mistaken for completion")
        try await Task.sleep(for: .milliseconds(400))
        let before = player.position
        player.mix = .solo
        precondition(player.isPlaying && abs(player.position-before) < 0.05, "Live switch restarted audio")
        player.pause()
        let paused = player.position
        try await Task.sleep(for: .milliseconds(100))
        precondition(player.position == paused && paused > 1)
        player.interrupted(); precondition(!player.isPlaying && player.message != nil)
        player.close(); precondition(!player.ready && player.position == 0)
        print("Stem player: alignment, seek, speed, scheduled start, live mix switching, pause and cleanup passed")
    }
}
