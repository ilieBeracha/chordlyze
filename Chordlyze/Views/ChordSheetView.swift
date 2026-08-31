import SwiftUI

/// Full analysis screen: sticky compact header (back, song, Original/Simple
/// toggles) over a scrolling chord sheet — or the timeline via the ⋯ menu.
struct AnalysisTabsView: View {
    let analysis: ChordAnalysis
    let title: String
    let artist: String

    @State private var simple = false
    @State private var showTimeline = false
    @State private var manualShift = 0
    @State private var selectedChord: SelectedChord?

    struct SelectedChord: Identifiable {
        let name: String
        var id: String { name }
    }

    private var capo: Int {
        ChordMath.autoCapo(names: analysis.chords
            .filter { $0.label != "N" }
            .map { ($0.displayName, $0.duration) })
    }
    private var shift: Int { (simple ? -capo : 0) + manualShift }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.separator).frame(height: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        if simple {
                            Text(capo == 0 ? "No capo needed" : "Capo \(capo)")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.spotifyGreen)
                                .padding(.vertical, 5).padding(.horizontal, 10)
                                .background(Capsule().fill(Palette.greenTintFill))
                        }
                        Spacer()
                        transposeStepper
                    }
                    .padding(.bottom, 12)
                    if showTimeline {
                        AnalysisResultView(analysis: analysis, transposeBy: shift, embedded: true,
                                           onChordTap: { selectedChord = SelectedChord(name: $0) })
                    } else {
                        ChordSheetView(analysis: analysis, title: title, artist: artist,
                                       transposeBy: shift,
                                       onChordTap: { selectedChord = SelectedChord(name: $0) })
                    }
                }
                .padding(.vertical, 18)
                .padding(.horizontal, 20)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $selectedChord) { selected in
            ChordDiagramSheet(chord: selected.name)
        }
    }

    /// Manual key shift for singers: −6…+6 semitones on top of capo mode.
    private var transposeStepper: some View {
        HStack(spacing: 0) {
            Button {
                if manualShift > -6 { manualShift -= 1 }
            } label: {
                Image(systemName: "minus")
                    .frame(width: 30, height: 26)
            }
            Button {
                manualShift = 0
            } label: {
                Text(manualShift == 0 ? "±0" : String(format: "%+d", manualShift))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(manualShift == 0 ? Palette.secondary : Color.spotifyGreen)
                    .frame(width: 34)
            }
            Button {
                if manualShift < 6 { manualShift += 1 }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 30, height: 26)
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .background(Capsule().fill(Palette.elevated))
    }

    private var header: some View {
        HStack(spacing: 10) {
            BackCircle(size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            togglePill("Original", selected: !simple) { simple = false }
            togglePill("Simple", selected: simple) { simple = true }
            Menu {
                Button {
                    showTimeline.toggle()
                } label: {
                    Label(showTimeline ? "Show lyrics" : "Show chord timeline",
                          systemImage: showTimeline ? "text.quote" : "chart.bar.doc.horizontal")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(Palette.secondary)
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private var subtitle: String {
        if let key = analysis.key {
            return artist.isEmpty ? key : "\(artist) · \(key)"
        }
        return artist
    }

    private func togglePill(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: selected ? .bold : .semibold))
                .foregroundStyle(selected ? .black : Palette.secondary)
                .padding(.vertical, 7)
                .padding(.horizontal, 14)
                .background(Capsule().fill(selected ? Color.spotifyGreen : Palette.elevated))
        }
        .buttonStyle(.plain)
    }
}

/// Lyrics with chord chips above each line.
struct ChordSheetView: View {
    let analysis: ChordAnalysis
    let title: String
    let artist: String
    var transposeBy: Int = 0
    var onChordTap: ((String) -> Void)? = nil

    @State private var rendered: [SheetModel.RenderLine]?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let rendered {
                if rendered.contains(where: { $0.chords.contains(where: \.estimated) }) {
                    Label("Green chords are analyzed; gray ones continue the song's loop (estimate).",
                          systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(Palette.tertiary)
                        .padding(.bottom, 12)
                }
                ForEach(rendered) { line in
                    lineView(line)
                }
            } else if failed {
                Text("No synced lyrics for this song.")
                    .font(.caption)
                    .foregroundStyle(Palette.tertiary)
                    .padding(.bottom, 10)
                AnalysisResultView(analysis: analysis, transposeBy: transposeBy, embedded: true)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
            }
        }
        .task {
            guard rendered == nil else { return }
            if let lines = await BackendClient.lyrics(title: title, artist: artist) {
                rendered = SheetModel.build(analysis: analysis, lines: lines)
            } else {
                failed = true
            }
        }
    }

    private func lineView(_ line: SheetModel.RenderLine) -> some View {
        // Hebrew/Arabic lyrics lay out right-to-left, chords included.
        let rtl = line.text.isRTLText
        return VStack(alignment: rtl ? .trailing : .leading, spacing: 0) {
            if !line.chords.isEmpty {
                HStack(spacing: 6) {
                    ForEach(line.chords) { chord in
                        let name = ChordMath.transpose(chord.name, by: transposeBy)
                        Button {
                            onChordTap?(name)
                        } label: {
                            Text(name)
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(chord.estimated ? Palette.secondary : Color.spotifyGreen)
                                .padding(.vertical, 3)
                                .padding(.horizontal, 9)
                                .background(RoundedRectangle(cornerRadius: 7)
                                    .fill(Color.white.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                .frame(minHeight: 22)
                .padding(.bottom, 4)
            }
            Text(line.text)
                .font(.system(size: 18, design: .rounded))
                .foregroundStyle(Palette.nearWhite)
                .lineSpacing(18 * 0.35)
                .multilineTextAlignment(rtl ? .trailing : .leading)
        }
        .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(hex: 0x2C2C2E).opacity(0.45)).frame(height: 0.5)
        }
    }
}
