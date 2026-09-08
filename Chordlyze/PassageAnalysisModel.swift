import Combine
import Foundation

@MainActor
final class PassageAnalysisModel: ObservableObject {
    struct Service {
        var read: (String) async throws -> PassageJob? = { try await BackendClient.passage(trackID: $0) }
        var request: (String, Double, Double, String) async throws -> PassageJob? = {
            try await BackendClient.passage(trackID: $0, start: $1, end: $2, revision: $3)
        }
        var cancel: (String, String) async throws -> PassageJob? = { try await BackendClient.cancelPassage(trackID: $0, id: $1) }
        var sleep: (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    }
    @Published private(set) var job: PassageJob?
    @Published private(set) var loaded = false
    @Published private(set) var submitting = false
    @Published private(set) var requestError: String?
    @Published private(set) var error: String?
    @Published private(set) var pollID = 0
    private var discoveringRequest = false
    private var previousJobID: String?
    private var generation = 0
    private let service: Service
    init(service: Service = .init()) { self.service = service }

    /// Read-only discovery, including after dismissal, suspension or app relaunch.
    func follow(track: String) async {
        generation += 1
        let token = generation
        var failures = 0
        while !Task.isCancelled && generation == token {
            do {
                let result = try await service.read(track)
                try Task.checkCancellation()
                guard generation == token else { return }
                if discoveringRequest, let result, result.id != previousJobID { requestError = nil; discoveringRequest = false }
                job = result; loaded = true; error = nil; failures = 0
                guard result?.pending == true else { return }
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, generation == token else { return }
                self.error = Self.message(error)
                failures += 1
                if failures >= 3 { return }
            }
            do { try await service.sleep(failures > 0 ? 5 : 2) } catch { return }
        }
    }

    func request(track: String, start: Double, end: Double, revision: String) async {
        guard loaded, !submitting, job?.pending != true else { return }
        generation += 1
        submitting = true; error = nil; requestError = nil
        previousJobID = job?.id; discoveringRequest = true
        defer { submitting = false; pollID += 1 }
        do {
            job = try await service.request(track, start, end, revision)
            discoveringRequest = false
        } catch { self.requestError = Self.message(error) }
        // Even a lost POST response is followed by GET, never an automatic second POST.
    }
    func cancel(track: String) async {
        guard let job, job.pending, !submitting else { return }
        generation += 1; submitting = true; requestError = nil
        defer { submitting = false; pollID += 1 }
        do { self.job = try await service.cancel(track, job.id) }
        catch { requestError = Self.message(error) }
    }

    func retryStatus() { error = nil; pollID += 1 }
    static func message(_ error: Error) -> String {
        if let backend = error as? BackendError {
            let data = backend.detail.data(using: .utf8)
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            return object?["detail"] as? String ?? backend.detail
        }
        return "Could not check preparation. Reconnect and check status; your chart is unchanged."
    }
}
