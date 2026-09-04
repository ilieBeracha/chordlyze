import SwiftUI

/// Full analysis screen: sticky compact header (back, song, Original/Simple
/// toggles) over a scrolling chord sheet — or the timeline via the ⋯ menu.
struct AnalysisTabsView: View {
    let analysis: ChordAnalysis
    let title: String
    let artist: String
    /// Album name, when known: narrows the lyrics match to this version.
    var album: String? = nil
    /// Enables the Practice flow (needs the backend's reference chart key).
    var trackID: String? = nil
    /// Full song length when known: the sheet's timeline runs to the end of
    /// the song, not just to the last analyzed chord.
    var trackDuration: Double? = nil

    @State private var simple = false
    @State private var showTimeline = false
    @State private var manualShift = 0
    @State private var selectedChord: SelectedChord?

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
                    toolbox
                    .padding(.bottom, 12)
                    if showTimeline {
                        AnalysisResultView(analysis: analysis, transposeBy: shift,
                                           onChordTap: { selectedChord = SelectedChord(name: $0) })
                    } else {
                        ChordSheetView(analysis: analysis, title: title, artist: artist, album: album,
                                       trackDuration: trackDuration, transposeBy: shift,
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
    /// One contained control strip: Practice · Transpose · Capo.
    private var toolbox: some View {
        HStack(spacing: 0) {
            // A preview excerpt has no song timeline to score a take against.
            if let trackID, !analysis.isPreview {
                NavigationLink {
                    PracticeView(analysis: analysis, title: title, artist: artist,
                                 album: album, trackID: trackID)
                } label: {
                    toolCell("PRACTICE") {
                        HStack(spacing: 6) {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 12, weight: .bold))
                            Text("Start")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(Color.spotifyGreen)
                    }
                }
                .buttonStyle(.plain)
                toolDivider
            }
            toolCell("TRANSPOSE") {
                HStack(spacing: 2) {
                    Button {
                        if manualShift > -6 { manualShift -= 1 }
                    } label: {
                        Image(systemName: "minus")
                            .frame(width: 26, height: 24)
                    }
                    Button {
                        manualShift = 0
                    } label: {
                        Text(manualShift == 0 ? "±0" : String(format: "%+d", manualShift))
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(manualShift == 0 ? Palette.secondary : Color.spotifyGreen)
                            .frame(width: 30)
                    }
                    Button {
                        if manualShift < 6 { manualShift += 1 }
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 26, height: 24)
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .buttonStyle(.plain)
            }
            toolDivider
            Button {
                simple.toggle()
            } label: {
                toolCell("CAPO") {
                    Text(simple ? (capo == 0 ? "None" : "\(capo)") : "Off")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(simple ? Color.spotifyGreen : Palette.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Palette.card))
    }

    private func toolCell<Content: View>(_ label: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 5) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .tracking(1.0)
                .foregroundStyle(Palette.tertiary)
            content()
                .frame(height: 24)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private var toolDivider: some View {
        Rectangle()
            .fill(Palette.separator)
            .frame(width: 0.5, height: 34)
    }

    private var header: some View {
        HStack(spacing: 10) {
            BackCircle(size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                    if let diff = analysis.difficulty {
                        Circle()
                            .fill(Palette.difficulty(diff.level))
                            .frame(width: 5, height: 5)
                        Text(diff.level.capitalized)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.secondary)
                    }
                }
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

/// The song as timeline rows: lyric lines with their chords, timed
/// instrumental rows for intro, breaks and ending, and a marker for any part
/// past the analyzed audio. Same rows and renderer as the live view.
struct ChordSheetView: View {
    let analysis: ChordAnalysis
    let title: String
    let artist: String
    var album: String? = nil
    var trackDuration: Double? = nil
    var transposeBy: Int = 0
    var onChordTap: ((String) -> Void)? = nil

    @State private var rows: [SheetModel.Row]?
    @State private var lyricsNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if analysis.isPreview {
                coverageLabel("Chords come from a 30-second preview at an unknown point in the song, so they can't be placed on the lyrics.")
                AnalysisResultView(analysis: analysis, transposeBy: transposeBy,
                                   onChordTap: onChordTap)
            } else if let rows {
                if let lyricsNote {
                    Text(lyricsNote)
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.faint)
                        .padding(.bottom, 8)
                }
                ForEach(rows) { row in
                    ChordRowView(row: row, transposeBy: transposeBy, style: .sheet,
                                 onChordTap: onChordTap)
                        .padding(.top, 8)
                        .padding(.bottom, 10)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Color(hex: 0x2C2C2E).opacity(0.45)).frame(height: 0.5)
                        }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
            }
        }
        .task {
            guard rows == nil, !analysis.isPreview else { return }
            // Without lyrics the timeline is instrumental rows end to end.
            do {
                let result = try await BackendClient.retrying {
                    try await BackendClient.lyrics(title: title, artist: artist,
                                                   duration: trackDuration ?? analysis.coverageEnd,
                                                   album: album)
                }
                rows = SheetModel.build(analysis: analysis, lines: result?.lines ?? [],
                                        duration: trackDuration)
                lyricsNote = result == nil ? "No synced lyrics for this song." : result?.betaNote
            } catch {
                rows = SheetModel.build(analysis: analysis, lines: [], duration: trackDuration)
                lyricsNote = "Lyrics unavailable right now."
            }
        }
    }

    private func coverageLabel(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.caption2)
            .foregroundStyle(Palette.tertiary)
            .padding(.bottom, 12)
    }
}
