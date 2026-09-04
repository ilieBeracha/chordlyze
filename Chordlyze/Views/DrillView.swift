import SwiftUI

/// One-minute-changes drill: switch between two chords as many times as
/// possible in 60 seconds; the mic counts clean changes live.
struct DrillView: View {
    let from: String
    let to: String

    @StateObject private var listener = ChordDrillListener()
    @State private var running = false
    @State private var starting = false
    @State private var drillTask: Task<Void, Never>?
    @State private var remaining = 60
    @State private var result: (score: Int, newBest: Bool)?
    @State private var error: String?
    @AppStorage private var best: Int
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(from: String, to: String) {
        self.from = from
        self.to = to
        _best = AppStorage(wrappedValue: 0, "drillBest-v2-\([from, to].sorted().joined(separator: "-"))")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                BackCircle(size: 38)
                Spacer()
                if best > 0 {
                    Text("BEST \(best)")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.0)
                        .foregroundStyle(Palette.secondary)
                }
            }

            Spacer()

            if let result {
                results(result.score, newBest: result.newBest)
            } else {
                drill
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 34)
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onDisappear { cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                cancel()
                error = "The drill stopped when the app left the screen. Start again when you’re ready."
            }
        }
        .onChange(of: listener.failure) { _, message in
            if let message { cancel(); error = message }
        }
    }

    private var drill: some View {
        VStack(spacing: 26) {
            Text(running ? "\(remaining)" : "1-minute changes")
                .font(running ? .system(size: 64, weight: .heavy, design: .rounded)
                              : .system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))

            HStack(spacing: 14) {
                chordTile(from)
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Palette.secondary)
                chordTile(to)
            }

            if running {
                VStack(spacing: 4) {
                    Text("\(listener.changes)")
                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.spotifyGreen)
                    Text("changes")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                    Text(listeningStatus)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                        .multilineTextAlignment(.center)
                        .frame(minHeight: 32)
                }
            } else {
                Text("Switch between the two chords for 60 seconds. Strum all the chord’s notes and let each chord ring briefly. Only recognized changes count.")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    guard drillTask == nil else { return }
                    starting = true
                    drillTask = Task { await start() }
                } label: {
                    Text(starting ? "Starting…" : "Start")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.vertical, 13)
                        .padding(.horizontal, 44)
                        .background(Capsule().fill(Color.spotifyGreen))
                }
                .buttonStyle(.plain)
                .disabled(drillTask != nil)
            }
            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.destructive)
            }
        }
        .padding(.horizontal, 12)
    }

    private func results(_ score: Int, newBest: Bool) -> some View {
        VStack(spacing: 16) {
            Text("\(score)")
                .font(.system(size: 84, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.spotifyGreen)
            Text(newBest ? "New best!" : "changes in a minute")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Button {
                result = nil
            } label: {
                Text("Go again")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 34)
                    .background(Capsule().fill(Color.spotifyGreen))
            }
            .buttonStyle(.plain)
        }
    }

    private func chordTile(_ name: String) -> some View {
        let active = listener.current == name && running
        return Text(name)
            .font(.system(size: 30, weight: .heavy, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(active ? .black : Color.spotifyGreen)
            .frame(width: 108, height: 84)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(active ? Color.spotifyGreen : Palette.greenTintFill)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Palette.greenTintBorder, lineWidth: 1))
            )
            .animation(.easeInOut(duration: 0.15), value: active)
    }

    private func start() async {
        error = nil
        defer { starting = false; drillTask = nil }
        do {
            try await listener.start(chordA: from, chordB: to)
            try Task.checkCancellation()
            starting = false
            running = true
            remaining = 60
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(60))
            while clock.now < deadline {
                try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(100))))
                let left = clock.now.duration(to: deadline).components
                let seconds = max(0, Int(ceil(Double(left.seconds) + Double(left.attoseconds) / 1e18)))
                if remaining != seconds { withAnimation { remaining = seconds } }
            }
            try await listener.finish()
        } catch is CancellationError {
            return
        } catch {
            listener.stop()
            running = false
            self.error = error.localizedDescription
            return
        }
        guard running else { return }
        running = false
        let score = listener.changes
        let newBest = score > best
        if newBest { best = score }
        result = (score, newBest)
    }

    private func cancel() {
        drillTask?.cancel()
        // Keep the task until its defer runs, so a late permission response
        // cannot clear a replacement task or start another microphone session.
        listener.stop()
        running = false
        starting = false
    }

    private var listeningStatus: String {
        switch listener.evidence {
        case .quiet: return "Ready for your next strum"
        case .uncertain: return "Listening for a clear chord"
        case .chord(let name):
            if listener.current != nil { return "Chord recognized" }
            if name == from || name == to { return "Let the chord ring briefly" }
            return "Hearing \(name) — play \(from) or \(to)"
        }
    }
}
