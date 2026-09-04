import SwiftUI

/// Practice-take report: overall score, per-section accuracy, worst
/// transitions, and per-chord cleanliness (tap a chord for its diagram).
struct ReportCardView: View {
    let report: BackendClient.PracticeReport
    let title: String
    let artist: String

    @State private var selectedChord: SelectedChord?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    BackCircle(size: 38)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(artist.uppercased())
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.secondary)
                    }
                    Spacer()
                }

                // Score hero
                VStack(spacing: 6) {
                    Text("\(Int((report.accuracy * 100).rounded()))%")
                        .font(.system(size: 64, weight: .heavy, design: .rounded))
                        .foregroundStyle(scoreColor)
                    Text("chords on target")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.secondary)
                    if let error = report.avgTimingError {
                        Text(String(format: "avg change timing error %.1fs", error))
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.tertiary)
                    } else if let lag = report.avgLag {
                        Text(String(format: "avg change lag %.1fs", lag))
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.tertiary)
                    }
                    if report.comparison == "major_minor" {
                        Text("Scored at this chart’s major/minor level")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 34)

                // Sections
                SectionLabel("By section")
                    .padding(.bottom, 12)
                HStack(spacing: 8) {
                    ForEach(Array(report.sections.enumerated()), id: \.offset) { i, section in
                        VStack(spacing: 6) {
                            GeometryReader { geo in
                                VStack {
                                    Spacer(minLength: 0)
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.spotifyGreen)
                                        .frame(height: geo.size.height * (section.accuracy ?? 0))
                                }
                            }
                            .frame(height: 70)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Palette.elevated))
                            Text("\(i + 1)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Palette.secondary)
                        }
                    }
                }
                .padding(.bottom, 28)

                // Transitions
                if !report.transitions.isEmpty {
                    SectionLabel("Chord changes")
                        .padding(.bottom, 6)
                    ForEach(report.transitions) { t in
                        HStack(spacing: 10) {
                            Text("\(t.from) → \(t.to)")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Spacer()
                            if t.misses > 0 {
                                Text("\(t.misses)/\(t.count) missed")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Palette.destructive)
                            } else if let timing = t.timingLabel {
                                Text(timing)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle((t.timingError ?? 0) > 0.5 ? Palette.warning : Palette.secondary)
                            }
                            if t.misses > 0 || (t.timingError ?? 0) > 0.5 {
                                NavigationLink {
                                    DrillView(from: t.from, to: t.to)
                                } label: {
                                    Text("Drill")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.black)
                                        .padding(.vertical, 5)
                                        .padding(.horizontal, 12)
                                        .background(Capsule().fill(Color.spotifyGreen))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 9)
                    }
                    Spacer().frame(height: 20)
                }

                // Chords
                SectionLabel("Chords")
                    .padding(.bottom, 6)
                ForEach(report.perChord) { chord in
                    Button {
                        selectedChord = SelectedChord(name: chord.name)
                    } label: {
                        HStack {
                            Text(chord.name)
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.spotifyGreen)
                            Spacer()
                            Text("\(Int((chord.accuracy * 100).rounded()))%")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(chord.accuracy < 0.6 ? Palette.destructive : Palette.secondary)
                        }
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $selectedChord) { selected in
            ChordDiagramSheet(chord: selected.name)
        }
    }

    private var scoreColor: Color {
        report.accuracy >= 0.8 ? Color.spotifyGreen
            : report.accuracy >= 0.5 ? Palette.warning : Palette.destructive
    }
}
