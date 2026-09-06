import SwiftUI

/// Aligns the chart to the Spotify recording by ear. Two chord changes far
/// apart are each replayed until the highlight and the sound coincide; the
/// map is fitted from them, then checked on a third change that was not
/// used to fit it. The result is saved for this account with the check's
/// remaining error, so the sheet can say how far to trust it.
struct TimingCalibrationView: View {
    @ObservedObject var store: SongSheetStore
    @ObservedObject var nowPlaying: SpotifyNowPlaying = .shared
    @Environment(\.dismiss) private var dismiss

    private enum Step: Equatable { case anchor(Int), check, done }
    @State private var step: Step = .anchor(0)
    @State private var anchors: [TimingMap.Anchor] = []
    /// Spotify time the listener currently says the anchor's change happens at.
    @State private var heardAt: Double?
    @State private var fitted: TimingMap?
    @State private var checkNudge = 0.0
    @State private var message: String?
    @State private var busy = false

    /// Lead-in before the change on every replay.
    static let leadIn = 3.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Calibrate by ear").font(.largeTitle.bold()).padding(.top, 52)
                Text("The chart was measured on a different recording of this song. Match two chord changes to what you hear, and the whole chart moves with them.")
                    .font(.subheadline).foregroundStyle(Palette.secondary)
                if let targets {
                    switch step {
                    case .anchor(let index): anchorStep(index, event: index == 0 ? targets.first : targets.second)
                    case .check:
                        if let check = targets.check { checkStep(event: check) } else { saveWithoutCheck }
                    case .done: doneStep
                    }
                } else {
                    Text("This chart has too few chord changes to calibrate.").foregroundStyle(Palette.secondary)
                }
                if let message { Text(message).font(.footnote).foregroundStyle(Palette.warning) }
            }
            .padding(24)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("").toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topLeading) { BackCircle().padding(.leading, 20).padding(.top, 8) }
    }

    // MARK: - Targets

    private struct Targets {
        let first: SheetModel.Event
        let second: SheetModel.Event
        /// A change between the two, used only to check the fit; nil on a
        /// chart with just two changes.
        let check: SheetModel.Event?
    }

    /// One change after the intro, one near the end at least twenty seconds
    /// later when the song allows, and one in between to check the fit.
    private var targets: Targets? {
        let events = SheetModel.events(store.analysis).filter { $0.chord != nil && $0.start >= 3 }
        let end = store.analysis?.coverageEnd ?? 0
        guard let first = events.first(where: { $0.start >= 5 }) ?? events.first else { return nil }
        guard let second = events.last(where: { $0.start <= end * 0.85 && $0.start >= first.start + 20 })
                ?? events.last(where: { $0.start >= first.start + 20 })
                ?? events.last(where: { $0.start > first.start }) else { return nil }
        let middle = (first.start + second.start) / 2
        let check = events.filter({ $0.start != first.start && $0.start != second.start })
            .min(by: { abs($0.start - middle) < abs($1.start - middle) })
        return Targets(first: first, second: second, check: check)
    }

    /// The map in force for the current step: confirmed anchors plus the one
    /// being adjusted, or the fitted map with the check nudge applied.
    private var provisional: TimingMap {
        switch step {
        case .anchor(let index):
            var all = anchors
            if let heardAt, let event = index == 0 ? targets?.first : targets?.second {
                all.append(.init(chart: event.start, spotify: heardAt))
            }
            return TimingMap.fit(all, chartAudioSha256: nil, spotifyTrackID: nil) ?? store.timing
        case .check, .done:
            var map = fitted ?? store.timing
            map.offset += checkNudge
            return map
        }
    }

    // MARK: - Steps

    private func anchorStep(_ index: Int, event: SheetModel.Event?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Change \(index + 1) of 2").font(.headline).foregroundStyle(Palette.secondary)
            if let event {
                indicator(event)
                Text("Replay starts \(Int(Self.leadIn)) seconds before this chord. Tap Now the moment you hear it change, then nudge until the highlight lights exactly with the sound.")
                    .font(.footnote).foregroundStyle(Palette.secondary)
                HStack(spacing: 10) {
                    primary("Replay", system: "gobackward") { replay(chartTime: event.start) }
                    primary("Now", system: "hand.tap") {
                        heardAt = nowPlaying.livePosition()
                        if heardAt == nil { message = "Spotify is not playing. Tap Replay first." }
                    }
                }
                nudges { delta in
                    guard let current = heardAt else { return }
                    heardAt = current + delta
                    replay(chartTime: event.start)
                }
                if let heardAt {
                    Text(String(format: "Heard at %@ in Spotify, chart says %@: %+.2f s", mmss(heardAt), mmss(event.start), heardAt - event.start))
                        .font(.footnote).monospacedDigit().foregroundStyle(Palette.secondary)
                    Button(index == 0 ? "Next change" : "Check the fit") {
                        anchors.append(.init(chart: event.start, spotify: heardAt))
                        self.heardAt = nil
                        if index == 0 { step = .anchor(1) } else {
                            fitted = TimingMap.fit(anchors, chartAudioSha256: store.analysis?.audioSha256,
                                                   spotifyTrackID: nowPlaying.playing?.track.id ?? store.song.id)
                            checkNudge = 0
                            step = .check
                        }
                    }
                    .buttonStyle(.borderedProminent).tint(.spotifyGreen)
                }
            }
        }
    }

    private func checkStep(event: SheetModel.Event) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Check").font(.headline).foregroundStyle(Palette.secondary)
            indicator(event)
            Text("This change was not used for the fit. Replay it: if the highlight lights before the sound, tap Early; after, tap Late. When they coincide, save.")
                .font(.footnote).foregroundStyle(Palette.secondary)
            HStack(spacing: 10) {
                primary("Replay", system: "gobackward") { replay(chartTime: event.start) }
                primary("Early", system: "arrow.left") { checkNudge += 0.05; replay(chartTime: event.start) }
                primary("Late", system: "arrow.right") { checkNudge -= 0.05; replay(chartTime: event.start) }
            }
            if let fitted {
                Text(String(format: "Offset %+.2f s, speed %.3f×, check adjustment %+.2f s", fitted.offset + checkNudge, fitted.scale, checkNudge))
                    .font(.footnote).monospacedDigit().foregroundStyle(Palette.secondary)
            }
            Button("Sounds right, save") {
                guard var map = fitted else { return }
                map.offset += checkNudge
                map.verifiedError = abs(checkNudge)
                busy = true
                Task {
                    await store.setTiming(map)
                    busy = false
                    message = store.timingError
                    if store.timingError == nil { step = .done }
                }
            }
            .buttonStyle(.borderedProminent).tint(.spotifyGreen).disabled(busy)
        }
    }

    /// A chart with only two changes has nothing left to check against.
    private var saveWithoutCheck: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("This chart has no third change to check the fit on.").font(.footnote).foregroundStyle(Palette.secondary)
            Button("Save") {
                guard let map = fitted else { return }
                busy = true
                Task {
                    await store.setTiming(map)
                    busy = false
                    message = store.timingError
                    if store.timingError == nil { step = .done }
                }
            }
            .buttonStyle(.borderedProminent).tint(.spotifyGreen).disabled(busy)
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(store.timingNote ?? "Saved.", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.successCheck)
            Text("Live and Practice now read the chart through this calibration on this account. Calibrate again if the chart is re-analyzed.")
                .font(.footnote).foregroundStyle(Palette.secondary)
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent).tint(.spotifyGreen)
        }
    }

    // MARK: - Pieces

    /// The target chord, lit while the provisional map says it is sounding.
    private func indicator(_ event: SheetModel.Event) -> some View {
        TimelineView(.periodic(from: .now, by: 0.03)) { _ in
            let chart = nowPlaying.livePosition().map { provisional.chartTime($0) }
            let active = chart.map(event.contains) ?? false
            HStack(spacing: 14) {
                Text(event.display(transposedBy: store.shift))
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .foregroundStyle(active ? .black : Color.spotifyGreen)
                    .padding(.horizontal, 22).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(active ? Color.spotifyGreen : Palette.card))
                VStack(alignment: .leading, spacing: 4) {
                    Text("at \(mmss(event.start)) in the chart").font(.subheadline).foregroundStyle(Palette.secondary)
                    Text(chart.map { "Spotify now: \(mmss($0))" } ?? "Spotify idle").font(.subheadline).monospacedDigit().foregroundStyle(Palette.secondary)
                }
            }
            .animation(.linear(duration: 0.03), value: active)
        }
    }

    private func nudges(_ apply: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            ForEach([-0.2, -0.05, 0.05, 0.2], id: \.self) { delta in
                Button(String(format: "%+.2f", delta)) { apply(delta) }
                    .buttonStyle(.bordered).monospacedDigit()
            }
            Text("seconds").font(.footnote).foregroundStyle(Palette.secondary)
        }
    }

    private func primary(_ title: String, system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: system).font(.headline).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered).tint(.spotifyGreen)
    }

    /// Starts Spotify a few seconds before the change, through the map in force.
    private func replay(chartTime: Double) {
        message = nil
        let at = max(0, provisional.spotifyTime(chartTime) - Self.leadIn)
        Task {
            do { try await nowPlaying.play(trackID: store.song.id, at: at) }
            catch { message = error.localizedDescription }
        }
    }
}
