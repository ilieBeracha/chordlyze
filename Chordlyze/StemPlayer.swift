import Foundation
import AVFoundation
import Combine
import CryptoKit

/// Both players share one scheduled audio-device start, rate and seek position.
/// Muting changes volumes only; it never restarts either file.
@MainActor final class StemPlayer: ObservableObject {
    enum Mix: String, CaseIterable { case full = "Full mix", solo = "Solo", backing = "Without" }
    @Published private(set) var ready = false
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double = 0
    @Published var mix: Mix = .backing { didSet { applyVolumes() } }
    @Published var speed: Float = 1 { didSet { changeSpeed() } }
    @Published private(set) var message: String?
    private var solo: AVAudioPlayer?
    private var backing: AVAudioPlayer?
    private var offset = 0.0
    private var scheduledStart = 0.0
    private var ownsSession = false

    var position: Double { isPlaying ? min(duration, solo?.currentTime ?? offset) : offset }

    func load(solo soloURL: URL, backing backingURL: URL) throws {
        close()
        let first = try AVAudioPlayer(contentsOf: soloURL)
        let second = try AVAudioPlayer(contentsOf: backingURL)
        guard abs(first.duration-second.duration) < 0.025, first.duration > 0 else {
            throw IsolationError("The mixes are not aligned. Prepare the instrument again.")
        }
        for player in [first, second] { player.enableRate = true; player.rate = speed; player.prepareToPlay() }
        solo = first; backing = second; duration = min(first.duration, second.duration)
        offset = 0; ready = true; message = nil; applyVolumes()
    }

    func play() {
        guard let solo, let backing else { return }
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            // Local playback replaces Spotify on this phone and uses the selected output route.
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            #endif
            ownsSession = true
            if offset >= duration - 0.02 { offset = 0 }
            solo.currentTime = offset; backing.currentTime = offset
            solo.rate = speed; backing.rate = speed
            let start = solo.deviceCurrentTime + 0.1
            scheduledStart = start
            guard solo.play(atTime: start), backing.play(atTime: start) else {
                pause(); throw IsolationError("Audio could not start. Try again.")
            }
            isPlaying = true; message = nil
        } catch { message = error.localizedDescription }
    }

    func pause() {
        offset = position
        solo?.pause(); backing?.pause(); isPlaying = false
    }

    func seek(_ seconds: Double) {
        let resume = isPlaying
        pause(); offset = min(duration, max(0, seconds))
        solo?.currentTime = offset; backing?.currentTime = offset
        if resume { play() }
    }

    func tick() {
        if isPlaying, (solo?.deviceCurrentTime ?? 0) > scheduledStart + 0.1, solo?.isPlaying == false, backing?.isPlaying == false {
            isPlaying = false; offset = duration
        }
    }

    func interrupted() { pause(); message = "Playback paused. Tap play when you’re ready." }

    func close() {
        pause(); solo = nil; backing = nil; offset = 0; duration = 0; ready = false
        #if os(iOS)
        if ownsSession { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        #endif
        ownsSession = false
    }

    private func applyVolumes() {
        solo?.volume = mix == .backing ? 0 : 1
        backing?.volume = mix == .solo ? 0 : 1
    }

    private func changeSpeed() {
        let resume = isPlaying
        pause(); solo?.rate = speed; backing?.rate = speed
        if resume { play() }
    }
}

struct IsolationError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

/// Files are downloaded with account authorization, verified, then atomically cached.
/// Failed or cancelled pairs are removed; old pairs are evicted before new downloads.
enum IsolationCache {
    static func audio(_ status: IsolationStatus) async throws -> (URL, URL) {
        guard status.id.count == 32, status.id.allSatisfy({ $0.isHexDigit }), status.state == "ready",
              status.files.count == 2 else { throw IsolationError("Invalid instrument audio. Prepare it again.") }
        let manager = FileManager.default
        let root = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Isolation", isDirectory: true)
        let directory = root.appendingPathComponent(status.id, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Keep the current pair and the two most recently used pairs (at most 288 MB).
        let others = (try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]))
            .filter { $0 != directory }.sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
                ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
        for old in others.dropFirst(2) { try? manager.removeItem(at: old) }
        do {
            for part in ["solo", "backing"] {
                try Task.checkCancellation()
                guard let info = status.files[part], info.bytes > 0, info.bytes <= 48*1024*1024 else {
                    throw IsolationError("Invalid audio size. Prepare the instrument again.")
                }
                let target = directory.appendingPathComponent(part+".m4a")
                if try valid(target, info) { continue }
                let downloaded = try await BackendClient.isolationAudio(id: status.id, part: part)
                defer { try? manager.removeItem(at: downloaded) }
                try Task.checkCancellation()
                guard try valid(downloaded, info) else { throw IsolationError("The audio download was incomplete. Try again.") }
                try? manager.removeItem(at: target)
                try manager.moveItem(at: downloaded, to: target)
            }
            try manager.setAttributes([.modificationDate: Date()], ofItemAtPath: directory.path)
            return (directory.appendingPathComponent("solo.m4a"), directory.appendingPathComponent("backing.m4a"))
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    private static func valid(_ url: URL, _ info: IsolationStatus.Audio) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize == info.bytes else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 256*1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == info.sha256
    }
}
