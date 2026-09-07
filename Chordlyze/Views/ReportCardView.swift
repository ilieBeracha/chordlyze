import SwiftUI

/// Chord matching and timing stay distinct; detail is available without
/// making the first screen read like a scoring specification.
struct ReportCardView: View {
    let report: BackendClient.PracticeReport
    let title: String
    let artist: String
    @State private var selectedChord: SelectedChord?
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var scoreSize = 64.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                PracticeDetailHeader(context: "Practice result", title: title, subtitle: artist)
                summary
                if !report.sections.isEmpty { sections }
                if !report.transitions.isEmpty { transitions }
                if !report.perChord.isEmpty { chords }
                DisclosureGroup("About this result") {
                    Text("Matched changes count the correct chords recognized near each change. They can still be early or late. Time on target measures how long your detected chords overlap the chart. Neither measure verifies playback sync.")
                        .font(.subheadline).foregroundStyle(MusicStyle.secondary)
                        .padding(.top, 10)
                }
                .font(.subheadline.weight(.medium)).tint(MusicStyle.secondary)
            }
            .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 32)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .modifier(MusicSurface())
        .toolbar(.hidden, for: .tabBar)
        .chordDiagram($selectedChord)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 20) {
            (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 20))) {
                Text(report.displayScore, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: scoreSize, weight: .bold, design: .rounded))
                    .tracking(-2).foregroundStyle(Color.spotifyGreen)
                    .minimumScaleFactor(0.75).lineLimit(1)
                VStack(alignment: .leading, spacing: 5) {
                    Text(report.changeMatchRate == nil ? "Time on target" : "Changes matched")
                        .font(.headline)
                    if let matched = report.matchedChanges, let total = report.totalChanges, total > 0 {
                        Text("\(matched) of \(total) chord changes")
                            .font(.subheadline).foregroundStyle(MusicStyle.secondary)
                    } else {
                        Text("Time matching the chart")
                            .font(.subheadline).foregroundStyle(MusicStyle.secondary)
                    }
                }
            }.accessibilityElement(children: .combine)
            Divider().overlay(MusicStyle.rule)
            (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 20))) {
                metric(value: report.accuracy.formatted(.percent.precision(.fractionLength(0))), label: "Time on target")
                metric(value: (report.avgTimingError ?? report.avgLag).map { String(format: "%.2f s", $0) } ?? "—",
                       label: report.avgTimingError != nil ? "Avg. timing difference" : report.avgLag != nil ? "Avg. lag" : "Timing unavailable")
            }
            if let shift = report.consistentOffset {
                DisclosureGroup {
                    Text("Changes consistently land at this offset from the chart. Playback sync and playing timing can both cause it; the recording alone cannot distinguish them. No timing correction has been applied.")
                        .font(.subheadline).foregroundStyle(MusicStyle.secondary).padding(.top, 8)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "clock.badge.questionmark").foregroundStyle(Palette.warning)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(format: "Consistent offset · %+.2f s", shift.seconds))
                                .font(.subheadline.weight(.semibold))
                            Text("Playback sync may affect this.").font(.caption).foregroundStyle(MusicStyle.secondary)
                        }
                    }
                }.tint(MusicStyle.secondary)
            }
            if report.playbackRate != nil && report.playbackRate != 1 || report.transpose != nil && report.transpose != 0 {
                HStack(spacing: 12) {
                    if let rate = report.playbackRate, rate != 1 { Label("\(Int(rate * 100))% pace", systemImage: "metronome") }
                    if let shift = report.transpose, shift != 0 { Label("\(shift > 0 ? "+" : "")\(shift) semitones", systemImage: "pianokeys") }
                }.font(.caption).foregroundStyle(MusicStyle.secondary)
            }
            if report.comparison == "major_minor" {
                Text("Major/minor chart comparison").font(.caption).foregroundStyle(MusicStyle.secondary)
            }
        }.practiceCard()
    }

    private func metric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(MusicStyle.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeading("Across your take", subtitle: "Time matching the chart")
            if typeSize.isAccessibilitySize {
                ForEach(Array(report.sections.enumerated()), id: \.offset) { _, section in
                    HStack {
                        Text("\(mmss(section.start))–\(mmss(section.end))")
                        Spacer()
                        Text(section.accuracy.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "Not scored")
                    }.font(.body).padding(.vertical, 6)
                }
            } else {
                HStack(alignment: .bottom, spacing: 12) {
                    ForEach(Array(report.sections.enumerated()), id: \.offset) { _, section in
                        VStack(spacing: 10) {
                            Text(section.accuracy.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—")
                                .font(.caption.weight(.semibold)).monospacedDigit()
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 5).fill(MusicStyle.surface)
                                RoundedRectangle(cornerRadius: 5).fill(Color.spotifyGreen.opacity(0.85))
                                    .frame(height: geo.size.height * max(0, min(1, section.accuracy ?? 0)))
                                    .frame(maxHeight: .infinity, alignment: .bottom)
                            }.frame(height: 64)
                            Text("\(mmss(section.start))–\(mmss(section.end))")
                                .font(.caption2).foregroundStyle(MusicStyle.secondary).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(mmss(section.start)) to \(mmss(section.end)), \(section.accuracy.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "not scored")")
                    }
                }
            }
        }
    }

    private var transitions: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Chord changes", subtitle: "Timing relative to the chart")
            ForEach(report.transitions) { transition in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Text(transition.from).font(.title3.weight(.semibold))
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(MusicStyle.secondary)
                        Text(transition.to).font(.title3.weight(.semibold))
                        Spacer()
                        if !typeSize.isAccessibilitySize { transitionDetail(transition) }
                    }
                    if typeSize.isAccessibilitySize { transitionDetail(transition) }
                    MusicRule()
                }.padding(.top, 4)
            }
        }
    }

    private func transitionDetail(_ transition: BackendClient.PracticeReport.Transition) -> some View {
        HStack(spacing: 12) {
            Text(transition.misses > 0 ? "\(transition.misses) of \(transition.count) missed" : transition.timingLabel ?? "Not timed")
                .font(.subheadline).foregroundStyle(transition.misses > 0 ? Palette.warning : MusicStyle.secondary)
            if transition.misses > 0 || (transition.timingError ?? 0) > 0.5 {
                NavigationLink { DrillView(from: transition.from, to: transition.to) } label: {
                    Text("Drill").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16).frame(minHeight: 44)
                        .background(MusicStyle.surface, in: Capsule())
                }.buttonStyle(MusicPressStyle())
            }
        }
    }

    private var chords: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading("By chord", subtitle: "Time matching the chart · tap for fingering")
            ForEach(report.perChord) { chord in
                Button { selectedChord = SelectedChord(name: chord.name) } label: {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text(chord.name).font(.headline).foregroundStyle(.white)
                            Spacer()
                            Text(chord.accuracy, format: .percent.precision(.fractionLength(0)))
                                .font(.subheadline).monospacedDigit().foregroundStyle(MusicStyle.secondary)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(MusicStyle.secondary)
                        }
                        GeometryReader { geo in
                            Capsule().fill(MusicStyle.surface)
                            Capsule().fill(Color.spotifyGreen.opacity(0.75))
                                .frame(width: geo.size.width * max(0, min(1, chord.accuracy)))
                        }.frame(height: 4)
                    }.padding(.vertical, 6).frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(MusicPressStyle())
            }
        }
    }

    private func sectionHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.caption).foregroundStyle(MusicStyle.secondary)
        }
    }
}

struct PracticeDetailHeader: View {
    let context: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                BackCircle(size: 44)
                Text(context).font(.subheadline.weight(.medium)).foregroundStyle(MusicStyle.secondary)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.largeTitle.bold()).tracking(-0.8).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if !subtitle.isEmpty { Text(subtitle).font(.subheadline).foregroundStyle(MusicStyle.secondary) }
            }
        }
    }
}

extension View {
    func practiceCard() -> some View {
        padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(MusicStyle.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
#if DEBUG
struct PracticeReportPreview: View {
    var body: some View {
        NavigationStack {
            ReportCardView(report: Self.report, title: "Practice timing preview", artist: "Offline sample")
                .environment(\.dynamicTypeSize, ProcessInfo.processInfo.arguments.contains("--practice-large-type") ? .accessibility3 : .large)
        }
    }
    static var report: BackendClient.PracticeReport {
        let data = Data("""
        {"take_id":"preview","accuracy":0.9,"avg_lag":0.4,"avg_timing_error":0.4,
         "matched_changes":3,"total_changes":3,"consistent_offset":{"seconds":0.4,"spread":0,"samples":3},
         "per_chord":[{"name":"C","accuracy":0.9,"count":1},{"name":"G","accuracy":0.9,"count":1}],
         "transitions":[{"from":"C","to":"G","avg_offset":0.4,"avg_timing_error":0.4,"misses":0,"count":3}],
         "sections":[{"start":0,"end":4,"accuracy":0.9},{"start":4,"end":8,"accuracy":0.9},
                     {"start":8,"end":12,"accuracy":0.9},{"start":12,"end":16,"accuracy":0.9}]}
        """.utf8)
        return try! JSONDecoder().decode(BackendClient.PracticeReport.self, from: data)
    }
}
#endif
