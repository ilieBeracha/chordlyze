import SwiftUI

/// Explicit microphone ownership: merely opening this screen never interrupts playback.
struct LiveChordRecognitionView: View {
    @StateObject private var listener = ChordDrillListener()
    @Environment(\.scenePhase) private var phase
    @State private var listening = false
    @State private var starting = false
    @State private var startTask: Task<Void, Never>?
    @State private var error: String?
    @State private var diagram: String?

    // Retain a dimmed, explicitly labelled last confirmation during a transition.
    // Quiet input still clears the card; provisional labels never become history.
    private var displayChord: String? {
        listener.current ?? (listening && listener.evidence != .quiet ? listener.recent.last : nil)
    }
    private var showingPrevious: Bool { listener.current == nil && displayChord != nil }

    private var status: String {
        if starting { return "Opening microphone…" }
        if !listening { return "Ready when you are" }
        if showingPrevious { return "Listening · last confirmed chord" }
        switch listener.evidence {
        case .quiet: return "Waiting for your instrument"
        case .uncertain: return "Listening for a clearer chord"
        case .chord: return listener.current == nil ? "Confirming chord…" : "Chord detected"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Recognize a chord").font(.largeTitle.bold())
                Text("Play a chord on your instrument.").foregroundStyle(Palette.secondary)
                VStack(spacing: 18) {
                    Image(systemName: listening ? "waveform" : "mic").font(.title).foregroundStyle(Color.spotifyGreen)
                    Button { diagram = displayChord } label: {
                        Text(displayChord ?? "—")
                            .foregroundStyle(showingPrevious ? Palette.secondary : .white)
                            .font(.system(size: 76, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.35).lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 110)
                    }.buttonStyle(.plain).disabled(displayChord == nil)
                        .accessibilityLabel(displayChord.map { "\($0), \(showingPrevious ? "last confirmed chord, " : "")show fingering" } ?? "No chord detected")
                    Text(status).font(.subheadline).foregroundStyle(Palette.secondary)
                }.padding(24).frame(maxWidth: .infinity)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 24))
                Button(action: toggle) {
                    Label(listening || starting ? "Stop listening" : "Listen", systemImage: listening || starting ? "stop.fill" : "mic.fill")
                        .font(.headline).foregroundStyle(.black).frame(maxWidth: .infinity, minHeight: 56)
                        .background(Color.spotifyGreen, in: Capsule())
                }.buttonStyle(.plain).accessibilityIdentifier("recognize-listen")
                if let message = error ?? listener.failure {
                    Text(message).foregroundStyle(Palette.warning)
                }
                if !listener.recent.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Recent chords").font(.headline)
                        ScrollView(.horizontal) {
                            HStack(spacing: 10) {
                                ForEach(Array(listener.recent.enumerated()), id: \.offset) { _, chord in
                                    Button(chord) { diagram = chord }
                                        .font(.title3.bold()).padding(14)
                                        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
                                }
                            }
                        }
                    }
                }
                Text("Audio is processed on this phone and isn't saved. Best with one instrument and a clearly held chord.")
                    .font(.footnote).foregroundStyle(Palette.secondary)
            }.padding(22)
        }.background(Color.black.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: Binding(get: { diagram != nil }, set: { if !$0 { diagram = nil } })) {
                if let diagram { ChordDiagramSheet(chord: diagram) }
            }
            .onChange(of: listener.failure) { _, failure in if failure != nil { stop() } }
            .onChange(of: phase) { _, phase in if phase == .background { stop() } }
            .onDisappear { stop() }
    }

    private func toggle() {
        if listening || starting { stop(); return }
        error = nil; starting = true
        startTask = Task { @MainActor in
            do {
                try await listener.startListening()
                try Task.checkCancellation()
                starting = false; listening = true
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription; starting = false; listening = false }
        }
    }
    private func stop() {
        startTask?.cancel(); startTask = nil
        listener.stop(); listening = false; starting = false
    }
}
