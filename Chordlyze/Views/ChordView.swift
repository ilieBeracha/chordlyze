import SwiftUI
import UniformTypeIdentifiers

/// Track screen: shows the analysis when it exists (instant from cache or the
/// iTunes preview), else offers Listen / Import capture.
struct ChordView: View {
    let track: Track
    @State private var analysis: ChordAnalysis?
    @State private var isAnalyzing = false
    @State private var showImporter = false
    @State private var error: String?
    @StateObject private var recorder = ListenRecorder()

    var body: some View {
        Group {
            if let analysis, !recorder.isRecording {
                AnalysisTabsView(analysis: analysis, title: track.name, artist: track.artistNames,
                                 trackID: track.id)
            } else {
                captureScreen
            }
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: recorder.isRecording) { _, recording in
            if !recording, let url = recorder.fileURL, !isAnalyzing, analysis == nil {
                analyze(url)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url): analyze(url)
            case .failure(let err): error = err.localizedDescription
            }
        }
        .task {
            guard analysis == nil else { return }
            if let cached = await BackendClient.cachedAnalysis(trackID: track.id, isrc: track.isrc) {
                analysis = cached
                return
            }
            isAnalyzing = true
            analysis = await BackendClient.analyzeTrack(trackID: track.id, isrc: track.isrc,
                                                        title: track.name, artist: track.artistNames)
            isAnalyzing = false
        }
    }

    private var captureScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack { BackCircle(); Spacer() }
                Text(track.name)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(track.artistNames)
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.secondary)

                if recorder.isRecording {
                    VStack(spacing: 12) {
                        Label(String(format: "Listening… %.0fs", recorder.elapsed),
                              systemImage: "waveform.badge.mic")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .symbolEffect(.pulse)
                        Text("Play the song out loud near your device.")
                            .font(.caption).foregroundStyle(Palette.secondary)
                        Button("Stop & Analyze") { recorder.stop() }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.spotifyGreen)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else if isAnalyzing {
                    HStack {
                        ProgressView()
                        Text("Analyzing chords…").foregroundStyle(Palette.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
                } else {
                    ContentUnavailableView {
                        Label("No analysis yet", systemImage: "waveform")
                    } description: {
                        Text("This song has no iTunes preview. Listen while it plays, or import an audio file.")
                    } actions: {
                        Button {
                            startListening()
                        } label: {
                            Label("Listen", systemImage: "mic.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.spotifyGreen)
                        Button("Import Audio") { showImporter = true }
                            .buttonStyle(.bordered)
                    }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(Palette.destructive) }
            }
            .padding(20)
        }
    }

    private func startListening() {
        error = nil
        analysis = nil
        Task {
            guard await recorder.requestPermission() else {
                error = "Microphone access denied — enable it in Settings."
                return
            }
            do { try recorder.start() }
            catch { self.error = "Could not start recording: \(error.localizedDescription)" }
        }
    }

    private func analyze(_ url: URL) {
        isAnalyzing = true
        error = nil
        Task {
            defer { isAnalyzing = false }
            do {
                analysis = try await BackendClient.analyze(fileURL: url, trackID: track.id,
                                                           title: track.name, artist: track.artistNames)
            }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// Key + song map + progression + timeline (design 2e).
struct AnalysisResultView: View {
    let analysis: ChordAnalysis
    var transposeBy: Int = 0
    var embedded: Bool = false
    var onChordTap: ((String) -> Void)? = nil

    private func show(_ name: String) -> String {
        ChordMath.transpose(name, by: transposeBy)
    }

    private var timeline: [ChordSegment] {
        analysis.chords.filter { $0.label != "N" }
    }
    private var totalDuration: Double {
        analysis.chords.last?.end ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let key = analysis.key {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(key)
                        .font(.system(size: 46, weight: .heavy, design: .rounded))
                        .tracking(-1)
                        .foregroundStyle(.white)
                    if let conf = analysis.keyConfidence {
                        Text("\(Int(conf * 100))% fit")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.spotifyGreen)
                            .padding(.vertical, 4).padding(.horizontal, 10)
                            .background(Capsule().fill(Palette.greenTintFill))
                    }
                }
            }

            songMap
                .padding(.top, 18)
                .padding(.bottom, 28)

            SectionLabel("Progression")
                .padding(.bottom, 10)
            FlowLayout(spacing: 6) {
                let loop = progressionLoop()
                ForEach(Array(loop.enumerated()), id: \.offset) { index, seg in
                    if index > 0 {
                        Text("›")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: 0x3A3A3C))
                    }
                    Button {
                        onChordTap?(show(seg.displayName))
                    } label: {
                        VStack(spacing: 1) {
                            Text(show(seg.displayName))
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Text(seg.roman ?? " ")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Palette.secondary)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 13)
                        .background(RoundedRectangle(cornerRadius: 11).fill(Palette.elevated))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 28)

            SectionLabel("Timeline")
                .padding(.bottom, 10)
            let maxDur = timeline.map(\.duration).max() ?? 1
            VStack(spacing: 7) {
                ForEach(timeline) { segment in
                    HStack(spacing: 10) {
                        Text(timestamp(segment.start))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.tertiary)
                            .frame(width: 36, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(hex: 0x101010))
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Palette.greenTintFill)
                                    .overlay(RoundedRectangle(cornerRadius: 8)
                                        .stroke(Palette.greenTintBorder, lineWidth: 1))
                                    .frame(width: max(30, geo.size.width * segment.duration / maxDur))
                                HStack(spacing: 6) {
                                    Text(show(segment.displayName))
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                    Text(segment.roman ?? "")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Palette.secondary)
                                }
                                .padding(.leading, 10)
                            }
                        }
                        .frame(height: 30)
                        Text(durationText(segment.duration))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.tertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var songMap: some View {
        GeometryReader { geo in
            HStack(spacing: 1.5) {
                ForEach(analysis.chords) { segment in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(segment.label == "N" ? Palette.gray5 : Color.spotifyGreen)
                        .frame(width: max(2, geo.size.width * segment.duration / totalDuration - 1.5))
                }
            }
        }
        .frame(height: 12)
    }

    private func progressionLoop() -> [ChordSegment] {
        var loop: [ChordSegment] = []
        for seg in analysis.chords where seg.label != "N" {
            if loop.last?.displayName != seg.displayName {
                loop.append(seg)
                if loop.count == 8 { break }
            }
        }
        return loop
    }

    private func timestamp(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    private func durationText(_ seconds: Double) -> String {
        seconds >= 10 ? "\(Int(seconds))s" : String(format: "%.1fs", seconds)
    }
}

/// Minimal left-aligned wrapping layout.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                                  proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y + max(0, (rowHeight - size.height) / 2)))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - spacing)
        }
        return (CGSize(width: width, height: y + rowHeight), origins)
    }
}
