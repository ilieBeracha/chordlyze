import SwiftUI

struct PassageAnalysisView: View {
    @ObservedObject var store: SongSheetStore
    @StateObject private var model: PassageAnalysisModel
    @State private var start: Double
    @State private var length: Double
    @State private var applying = false
    @State private var applied = false
    @State private var error: String?
    @Environment(\.scenePhase) private var phase

    init(store: SongSheetStore, range: ClosedRange<Double>? = nil, model: PassageAnalysisModel? = nil) {
        self.store = store
        _model = StateObject(wrappedValue: model ?? PassageAnalysisModel())
        let duration = store.analysis?.coverageEnd ?? 0
        let start = min(max(0, range?.lowerBound ?? 0), max(0, duration - 2))
        _start = State(initialValue: start)
        _length = State(initialValue: min(max(2, (range?.upperBound ?? (start + 12)) - start), min(30, duration - start)))
    }
    private var duration: Double { store.analysis?.coverageEnd ?? 0 }
    private var busy: Bool { model.submitting || model.job?.pending == true || applying }
    private var stale: Bool { model.job.map { $0.chartRevision != store.analysis?.chartRevision } ?? false }

    var body: some View {
        List {
            Section {
                Text("Recheck a passage").font(.title2.bold())
                Text("Compare a fresh analysis of 2–30 seconds before changing your chart.")
                    .foregroundStyle(.secondary)
            }
            Section("Passage · original recording time") {
                if duration >= 2 {
                    LabeledContent("Start", value: String(format: "%.1f s", start))
                    Slider(value: $start, in: 0...max(0.001, duration - 2), step: 0.1)
                        .accessibilityLabel("Passage start").disabled(busy)
                        .onChange(of: start) { _, value in length = min(length, duration - value) }
                    Stepper("Length: \(String(format: "%.1f", length)) seconds", value: $length,
                            in: 2...max(2, min(30, duration - start)), step: 0.5).disabled(busy)
                    Text("\(mmss(start))–\(mmss(min(duration, start + length)))")
                        .monospacedDigit().foregroundStyle(.secondary)
                    Button(model.job == nil ? "Analyze passage" : "Analyze this passage again") {
                        guard let revision = store.analysis?.chartRevision else { return }
                        error = nil; applied = false
                        Task { await model.request(track: store.song.id, start: start, end: min(duration, start + length), revision: revision) }
                    }.disabled(!model.loaded || busy || store.savingCorrection)
                        .accessibilityIdentifier("analyze-passage")
                } else { Text("A complete song chart is needed first.") }
            }
            if !model.loaded && model.error == nil { ProgressView("Checking preparation…") }
            if let job = model.job {
                Section("\(mmss(job.start))–\(mmss(job.end))") {
                    if applied || job.applied == true {
                        Label("Passage applied", systemImage: "checkmark.circle.fill").foregroundStyle(Color.spotifyGreen)
                        Text("Your song sheet now uses this result.").font(.footnote)
                    } else if stale || job.state == "stale" {
                        Text("The chart changed. Analyze the passage again to compare against your latest edits.")
                    } else if job.pending {
                        ProgressView(job.message ?? "Preparing passage…")
                        Text("You can leave and return. Preparation also checks that the recording matches this chart.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if job.state == "ready", let proposed = job.segments {
                        Text("Ready to compare").font(.headline)
                        if (job.protectedCount ?? 0) > 0 {
                            Text("Your \(job.protectedCount!) edited chord intervals will be kept.").font(.footnote)
                        }
                        Text("Current").font(.subheadline.bold())
                        ForEach((store.analysis?.chords ?? []).filter { $0.start < job.end && $0.end > job.start }) { row in chordRow(row) }
                        Text("After applying").font(.subheadline.bold())
                        ForEach(proposed) { row in chordRow(row) }
                        Button(applying ? "Applying…" : "Apply passage changes") {
                            applying = true; error = nil
                            Task {
                                defer { applying = false }
                                do { try await store.applyPassage(job); applied = true; model.retryStatus() }
                                catch { self.error = PassageAnalysisModel.message(error) }
                            }
                        }.disabled(applying || store.savingCorrection).accessibilityIdentifier("apply-passage")
                    } else {
                        Text(job.message ?? "Preparation did not finish. You can try this passage again.")
                    }
                    if job.pending {
                        Button("Cancel preparation", role: .destructive) {
                            Task { await model.cancel(track: store.song.id) }
                        }.disabled(model.submitting)
                    }
                }
            }
            if let message = error ?? model.requestError ?? model.error {
                Section {
                    Text(message).foregroundStyle(.orange)
                    Button("Check status") { model.retryStatus() }.disabled(busy && model.submitting)
                }
            }
            Section {
                Text("Your manual chord and timing edits are preserved. The analysis uses more local detail, so compare by ear before applying.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Reanalyze passage").navigationBarTitleDisplayMode(.inline)
            .task(id: model.pollID) { await model.follow(track: store.song.id) }
            .task { await store.observe() }
            .onChange(of: phase) { _, phase in if phase == .active { model.retryStatus() } }
    }
    private func chordRow(_ segment: ChordSegment) -> some View {
        HStack {
            Text(String(format: "%.1f–%.1f", segment.start, segment.end)).monospacedDigit().foregroundStyle(.secondary)
            Spacer()
            Text(segment.displayName).fontWeight(.semibold)
        }.accessibilityElement(children: .combine)
    }
}
