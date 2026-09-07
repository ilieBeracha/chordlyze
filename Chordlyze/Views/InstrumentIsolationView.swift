import SwiftUI
import AVFoundation

struct InstrumentIsolationView: View {
    @ObservedObject var store: SongSheetStore
    @StateObject private var player = StemPlayer()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var instrument = "guitar"
    @State private var requested = 0
    @State private var busy = false
    @State private var progress: String?
    @State private var error: String?
    @State private var showChords = false
    @State private var scrub: Double?
    @State private var loop: ClosedRange<Double>?
    private let instruments = ["guitar", "bass", "drums", "vocals", "piano"]

    var body: some View {
        VStack(spacing: 0) {
            if showChords {
                LiveNowView(store: store, onSeek: { time in player.seek(time); return true },
                            playbackNote: player.isPlaying ? "\(player.mix.rawValue) · \(instrument.capitalized)" : "Playback paused",
                            seekUsesChartTime: true, showProgressStrip: false, loopSelection: $loop, chartPosition: { player.position })
            } else {
                setup
            }
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if player.ready { controls.padding(20).background(.black) }
        }
        .task(id: requested) {
            guard requested > 0 else { return }
            await prepare()
        }
        .task {
            while !Task.isCancelled {
                player.tick()
                // Keep a selected chart loop working when the mixer is showing too.
                if !showChords, player.isPlaying, let loop, player.position >= loop.upperBound {
                    player.seek(loop.lowerBound)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .onDisappear { player.close() }
        .onChange(of: instrument) { _, _ in
            player.close(); requested = 0; progress = nil; error = nil; loop = nil
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { player.pause() } }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            if let kind = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
               kind == AVAudioSession.InterruptionType.began.rawValue { player.interrupted() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { note in
            if let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
               reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { player.interrupted() }
        }
        .observes(store)
    }

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Instrument isolation").font(.largeTitle.bold())
                    Text(store.song.title).font(.title3.weight(.semibold))
                    Text(store.song.artist).font(.subheadline).foregroundStyle(Palette.secondaryAlt)
                }
                Text("Hear your part. Then play it yourself.")
                    .font(.title2.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Instrument").font(.subheadline).foregroundStyle(Palette.secondaryAlt)
                    Picker("Instrument", selection: $instrument) {
                        ForEach(instruments, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .pickerStyle(.menu).tint(.spotifyGreen).disabled(busy)
                    .accessibilityIdentifier("isolation-instrument")
                    Text("Solo brings out the \(instrument). Without leaves room for you to play.")
                        .font(.body).foregroundStyle(Palette.secondaryAlt)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 20))
                if let progress {
                    HStack(alignment: .top, spacing: 12) {
                        if busy { ProgressView().tint(.spotifyGreen) }
                        Text(progress).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    }.accessibilityIdentifier("isolation-progress")
                }
                if let error {
                    Text(error).foregroundStyle(Palette.warning).font(.subheadline)
                        .accessibilityIdentifier("isolation-error")
                }
                if !player.ready {
                    Button {
                        busy = true; requested += 1
                    } label: {
                        Text(busy ? "Preparing \(instrument)…" : error == nil ? "Prepare \(instrument)" : "Try again")
                            .font(.headline).foregroundStyle(.black)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(Color.spotifyGreen, in: Capsule())
                    }.buttonStyle(.plain).disabled(busy).accessibilityIdentifier("isolation-prepare")
                    Text("First preparation can take several minutes. You can leave and return while it works.")
                        .font(.footnote).foregroundStyle(Palette.secondaryAlt)
                }
                Text("Separation may leave traces of other instruments, especially guitar and piano. Audio stays in its original key.")
                    .font(.footnote).foregroundStyle(Palette.secondaryAlt)
                if player.ready {
                    Label("Ready on this phone", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.spotifyGreen).font(.subheadline)
                    Text("Playback uses Chordlyze’s player and your current audio output.")
                        .font(.footnote).foregroundStyle(Palette.secondaryAlt)
                }
            }.padding(24)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack { BackCircle(); Spacer() }.padding(.horizontal, 24).padding(.vertical, 12).background(.black)
        }
    }

    private var controls: some View {
        VStack(spacing: 14) {
            if dynamicTypeSize.isAccessibilitySize {
                mixPicker.pickerStyle(.menu).font(.headline).tint(.spotifyGreen)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            } else {
                mixPicker.pickerStyle(.segmented)
            }
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                VStack(spacing: 2) {
                    Slider(value: Binding(get: { scrub ?? player.position }, set: { scrub = $0 }),
                           in: 0...max(1, player.duration), onEditingChanged: { editing in
                        if !editing, let scrub { player.seek(scrub); self.scrub = nil }
                    }).tint(.spotifyGreen).accessibilityLabel("Song position")
                    HStack {
                        Text(mmss(scrub ?? player.position)); Spacer(); Text(mmss(player.duration))
                    }.font(.caption.monospacedDigit()).foregroundStyle(Palette.secondaryAlt)
                }
            }
            HStack(spacing: 18) {
                Menu {
                    ForEach([Float(0.5), 0.75, 1.0], id: \.self) { rate in
                        Button("\(rate.formatted())×") { player.speed = rate }
                    }
                } label: { Text("\(player.speed.formatted())×").font(.headline).frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("Playback speed")
                Spacer()
                Button { player.isPlaying ? player.pause() : player.play() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2).foregroundStyle(.black).frame(width: 60, height: 60)
                        .background(Color.spotifyGreen, in: Circle())
                }.accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                    .accessibilityIdentifier("isolation-play")
                Spacer()
                Button { showChords.toggle() } label: {
                    Image(systemName: showChords ? "slider.horizontal.3" : "music.note.list")
                        .font(.title3).frame(width: 44, height: 44)
                }.accessibilityLabel(showChords ? "Show mixer" : "Follow chords")
                    .accessibilityIdentifier("isolation-chords")
            }.tint(.white)
            if let message = player.message { Text(message).font(.footnote).foregroundStyle(Palette.warning) }
        }
    }

    private var mixPicker: some View {
        Picker("Mix", selection: $player.mix) {
            ForEach(StemPlayer.Mix.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.accessibilityIdentifier("isolation-mix")
    }

    @MainActor private func prepare() async {
        busy = true; error = nil; progress = "Connecting…"; player.close()
        defer { busy = false }
        do {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--isolation-preview") {
                let files = try Self.previewAudio()
                try player.load(solo: files.0, backing: files.1)
                progress = "Offline audio fixture"
                return
            }
            #endif
            var status = try await BackendClient.prepareIsolation(trackID: store.song.id, instrument: instrument)
            while true {
                try Task.checkCancellation()
                guard status.audioSha256 == store.analysis?.audioSha256, status.instrument == instrument else {
                    throw IsolationError("The chart’s recording changed. Reopen this song and prepare it again.")
                }
                switch status.state {
                case "ready":
                    progress = "Downloading your mixes…"
                    let files = try await IsolationCache.audio(status)
                    try Task.checkCancellation()
                    try player.load(solo: files.0, backing: files.1)
                    progress = nil
                    return
                case "failed", "expired":
                    throw IsolationError(status.message ?? "Prepare the instrument again.")
                default:
                    if !status.workerOnline { progress = "Waiting to prepare your instrument…" }
                    else {
                        progress = ["queued": "Waiting in line…", "downloading": "Finding the matching recording…",
                                    "separating": "Separating \(instrument)…", "uploading": "Finishing your mixes…"][status.stage] ?? "Preparing…"
                    }
                }
                try await Task.sleep(for: .seconds(3))
                // Temporary gateway failures do not discard a running preparation.
                var retry = 0
                while true {
                    do { status = try await BackendClient.isolationStatus(id: status.id); break }
                    catch {
                        try Task.checkCancellation()
                        let transient = (error as? BackendError).map { $0.status >= 500 } ?? (error is URLError)
                        guard transient, retry < 3 else { throw error }
                        retry += 1; progress = "Reconnecting. Your instrument is still preparing…"
                        try await Task.sleep(for: .seconds(2 * retry))
                    }
                }
            }
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled else { return }
            progress = nil
            if let backend = error as? BackendError {
                let detail = backend.detail.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                self.error = detail?["detail"] as? String ?? (backend.status >= 500 ? "Could not reach the server. Try again; prepared work is kept." : backend.detail)
            } else { self.error = error.localizedDescription }
        }
    }

    #if DEBUG
    private static func previewAudio() throws -> (URL, URL) {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let count: AVAudioFrameCount = 44100 * 40
        var urls: [URL] = []
        for (index, name) in ["solo", "backing"].enumerated() {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("isolation-preview-\(name).caf")
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
            buffer.frameLength = count
            for channel in 0..<2 {
                for frame in 0..<Int(count) {
                    buffer.floatChannelData![channel][frame] = Float(sin(Double(frame)*2*Double.pi*(index == 0 ? 220 : 110)/44100)) * 0.08
                }
            }
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer); urls.append(url)
        }
        return (urls[0], urls[1])
    }
    #endif
}
