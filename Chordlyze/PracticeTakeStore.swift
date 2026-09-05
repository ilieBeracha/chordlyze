import Combine
import Foundation

/// Maps performed time to the original song timeline. Transpose describes
/// sounding pitch, never the capo's alternative fingering names.
struct PracticePlan: Codable, Equatable {
    let start: Double
    let end: Double
    let rate: Double
    let transpose: Int
    let capo: Int

    init(start: Double, end: Double, rate: Double = 1, transpose: Int = 0, capo: Int = 0) throws {
        guard start.isFinite, end.isFinite, rate.isFinite, start >= 0, end > start,
              (0.5...1).contains(rate), (-12...12).contains(transpose), (0...9).contains(capo) else {
            throw NSError(domain: "Practice", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a valid time range, key and pace before recording."])
        }
        self.start = start
        self.end = min(end, start + 600 * rate)
        self.rate = rate
        self.transpose = transpose
        self.capo = capo
    }

    var recordingDuration: Double { (end - start) / rate }
    func position(elapsed: Double) -> Double { min(end, start + max(0, elapsed) * rate) }
    func beats(_ songBeats: [Double]) -> [Double] {
        songBeats.filter { $0 >= start && $0 < end }.map { ($0 - start) / rate }
    }
}

struct PracticeTake: Codable, Identifiable {
    let id: UUID
    let song: SongDescriptor
    let createdAt: Date
    let plan: PracticePlan
    var note: String?
    var report: BackendClient.PracticeReport?
}

/// Each take owns a durable directory. Metadata is written before recording
/// starts, audio is recorded directly there, and failed uploads never delete it.
@MainActor
final class PracticeTakeStore: ObservableObject {
    static let shared = PracticeTakeStore()
    @Published private(set) var takes: [PracticeTake] = []
    @Published private(set) var uploading: Set<UUID> = []
    @Published private(set) var error: String?
    private let directory: URL
    private let submit: (URL, PracticeTake) async throws -> BackendClient.PracticeReport

    init(directory: URL? = nil,
         submit: @escaping (URL, PracticeTake) async throws -> BackendClient.PracticeReport = { url, take in
             try await BackendClient.submitPracticeTake(fileURL: url, trackID: take.song.id,
                 offset: take.plan.start, transpose: take.plan.transpose, playbackRate: take.plan.rate)
         }) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("PracticeTakes", isDirectory: true)
        self.submit = submit
        reload()
    }

    func audioURL(_ take: PracticeTake) -> URL { folder(take).appendingPathComponent("audio.m4a") }
    private func folder(_ take: PracticeTake) -> URL { directory.appendingPathComponent(take.id.uuidString) }

    func reload() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let folders = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: nil)
            var loaded: [PracticeTake] = []
            var unreadable = false
            for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
                do {
                    let take = try JSONDecoder().decode(PracticeTake.self,
                        from: Data(contentsOf: folder.appendingPathComponent("take.json")))
                    // Empty preparations are not recordings. Preserve them on disk
                    // rather than guessing whether an interrupted writer is done.
                    if let size = try? audioURL(take).resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
                        loaded.append(take)
                    }
                } catch { unreadable = true }
            }
            takes = loaded.sorted { $0.createdAt > $1.createdAt }
            error = unreadable ? "Some saved takes could not be read. Their files are still on this device." : nil
        } catch { self.error = "Could not open saved takes: \(error.localizedDescription)" }
    }

    func prepare(song: SongDescriptor, plan: PracticePlan) throws -> PracticeTake {
        let take = PracticeTake(id: UUID(), song: song, createdAt: .now, plan: plan,
            note: "Recording was interrupted. You can listen or submit the captured portion.")
        try FileManager.default.createDirectory(at: folder(take), withIntermediateDirectories: true)
        try write(take)
        return take
    }

    func finish(_ take: PracticeTake, note: String? = nil) throws {
        var saved = take
        saved.note = note
        try write(saved)
        reload()
    }

    @discardableResult
    func score(_ take: PracticeTake) async throws -> BackendClient.PracticeReport {
        guard !uploading.contains(take.id) else { throw CocoaError(.userCancelled) }
        uploading.insert(take.id)
        defer { uploading.remove(take.id) }
        let report = try await submit(audioURL(take), take)
        var saved = take
        saved.report = report
        try write(saved)
        reload()
        return report
    }

    func delete(_ take: PracticeTake) throws {
        guard !uploading.contains(take.id) else { throw CocoaError(.userCancelled) }
        try FileManager.default.removeItem(at: folder(take))
        reload()
    }

    private func write(_ take: PracticeTake) throws {
        try JSONEncoder().encode(take).write(to: folder(take).appendingPathComponent("take.json"), options: .atomic)
    }
}
