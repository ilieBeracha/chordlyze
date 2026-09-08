import AVFoundation
import SwiftUI

/// Samples audible playback at three separated points, then commits only a
/// unique server match. All audio is temporary; leaving stops the microphone.
struct AutomaticSyncView: View {
    @ObservedObject var store: SongSheetStore
    @ObservedObject var nowPlaying: SpotifyNowPlaying
    @Environment(\.scenePhase) private var scenePhase
    @State private var recorder = TakeRecorder()
    @State private var work: Task<Void, Never>?
    @State private var message: String?
    @State private var stage = ""
    @State private var progress = 0.0
    @State private var complete = false
    @State private var listening = false
    @State private var needsSpotifyDevice = false
    @State private var automaticallyOpenSpotify = false

    private var windows: [AutomaticSyncPlan.Window] {
        AutomaticSyncPlan.windows(duration: store.song.duration ?? store.analysis?.coverageEnd ?? 0)
    }
    var body: some View {
        Form {
            Section {
                Text("Let Chordlyze hear the song")
                    .font(.title2.bold())
                Text("Play through this phone’s speaker in a quiet room. The app listens to three short passages and checks their timing together.")
                Text("Keep this screen open. Playback will jump between passages, then return to where you left it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                if work != nil {
                    ProgressView(value: progress)
                    Text(stage).accessibilityIdentifier("sync-stage")
                    Button("Cancel", role: .cancel) { cancel() }
                } else if complete {
                    Label(store.timingNote ?? "Synchronized", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(String(format: "Timing shift %+.2f s · pace %.3f×", store.timing.offset, store.timing.scale))
                        .font(.footnote).monospacedDigit()
                    Button("Synchronize again") { begin() }
                } else {
                    Button("Start automatic sync", systemImage: "waveform") { begin() }
                        .disabled(windows.isEmpty || !store.canPractice || store.analysis?.chartRevision == nil || store.savingCorrection)
                        .accessibilityIdentifier("start-auto-sync")
                }
                if windows.isEmpty {
                    Text("Automatic sync needs a song at least 45 seconds long. Use calibration by ear for this song.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if needsSpotifyDevice, work == nil {
                    SpotifyDeviceRecoveryView(nowPlaying: nowPlaying, trackID: store.song.id, retryTitle: "Start synchronization",
                                              automaticallyOpen: automaticallyOpenSpotify) { begin(allowWake: false) }
                }
                if let message { Text(message).foregroundStyle(.orange).accessibilityIdentifier("sync-message") }
            }
            Section {
                NavigationLink("Calibrate by ear") { TimingCalibrationView(store: store, nowPlaying: nowPlaying) }
            }
        }
        .navigationTitle("Automatic sync")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.observe() }
        .onDisappear { cancel() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            if listening { cancel() }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { cancel() } }
    }

    private func cancel() {
        work?.cancel()
        _ = recorder.stop()
    }

    private func begin(allowWake: Bool = true) {
        guard work == nil else { return }
        needsSpotifyDevice = false
        automaticallyOpenSpotify = allowWake
        message = nil; complete = false; progress = 0; stage = "Preparing…"
        work = Task { @MainActor in
            let idleWasDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chordlyze-sync-\(UUID().uuidString)")
            defer {
                listening = false
                _ = recorder.stop()
                UIApplication.shared.isIdleTimerDisabled = idleWasDisabled
                try? FileManager.default.removeItem(at: directory)
                work = nil
            }
            do {
                guard await recorder.requestPermission() else { throw SyncFailure("Enable microphone access in Settings to synchronize by sound.") }
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let baseline = try await BackendClient.songStatus(trackID: store.song.id)
                guard let revision = baseline.analysis?.chartRevision, revision == store.analysis?.chartRevision,
                      let timingRevision = baseline.timingRevision else {
                    throw SyncFailure("The chart changed or is not ready. Reopen the song and try again.")
                }
                let origin = nowPlaying.playing?.track.id == store.song.id ? nowPlaying.livePosition() : nil
                var clips: [BackendClient.SyncClip] = []
                for (index, window) in windows.enumerated() {
                    try Task.checkCancellation()
                    stage = "Preparing passage \(index + 1) of 3…"
                    try recorder.prime()
                    #if !targetEnvironment(simulator)
                    guard AVAudioSession.sharedInstance().currentRoute.outputs.contains(where: { $0.portType == .builtInSpeaker }) else {
                        throw SyncFailure("Use this phone’s speaker for automatic sync. The microphone needs to hear the song.")
                    }
                    #endif
                    try await nowPlaying.play(trackID: store.song.id, at: window.start)
                    try Task.checkCancellation()
                    guard let start = nowPlaying.livePosition(), nowPlaying.connectionMessage == nil else {
                        throw SyncFailure("Playback timing is unavailable. Reconnect and try again.")
                    }
                    let file = directory.appendingPathComponent("sample-\(index).m4a")
                    let began = ContinuousClock.now
                    try recorder.start(maxDuration: window.duration, at: file)
                    listening = true
                    stage = "Listening to passage \(index + 1) of 3…"
                    while true {
                        try Task.checkCancellation()
                        let elapsed = began.duration(to: .now).seconds
                        guard nowPlaying.playing?.track.id == store.song.id, nowPlaying.playing?.isPlaying == true,
                              nowPlaying.connectionMessage == nil, let position = nowPlaying.livePosition(),
                              AutomaticSyncPlan.uninterrupted(start: start, position: position, elapsed: elapsed),
                              store.analysis?.chartRevision == revision else {
                            throw SyncFailure("Playback or the chart changed while listening. Try again without seeking or pausing.")
                        }
                        progress = (Double(index) + min(1, elapsed/window.duration)) / 4
                        if elapsed >= window.duration { break }
                        if !recorder.isRecording && elapsed < window.duration - 0.2 {
                            throw SyncFailure("The microphone was interrupted. Try again.")
                        }
                        try await Task.sleep(for: .milliseconds(200))
                    }
                    listening = false
                    _ = recorder.stop()
                    clips.append(.init(file: file, spotifyStart: start))
                }
                if let origin, nowPlaying.playing?.track.id == store.song.id { _ = await nowPlaying.seek(to: origin) }
                try Task.checkCancellation()
                stage = "Matching the passages and checking drift…"
                progress = 0.8
                try await store.synchronize(clips: clips, chartRevision: revision, timingRevision: timingRevision)
                progress = 1
                complete = true
            } catch is CancellationError {
                message = "Synchronization canceled."
            } catch {
                needsSpotifyDevice = (error as? SpotifyNowPlaying.PlayError)?.needsDeviceRecovery == true
                automaticallyOpenSpotify = automaticallyOpenSpotify && (error as? SpotifyNowPlaying.PlayError)?.canWakeApp == true
                if Task.isCancelled { message = "Synchronization canceled." }
                else if let backend = error as? BackendError {
                    let body = backend.detail.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                    message = body?["detail"] as? String ?? backend.detail
                } else { message = automaticallyOpenSpotify ? nil : error.localizedDescription }
            }
        }
    }

    private struct SyncFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
