import SwiftUI

/// One-minute-changes drill: switch between two chords as many times as
/// possible in 60 seconds; the mic counts clean changes live.
struct DrillView: View {
    let from: String
    let to: String

    @StateObject private var listener = ChordDrillListener()
    @State private var running = false
    @State private var remaining = 60
    @State private var finalScore: Int?
    @State private var error: String?
    @AppStorage private var best: Int
    @Environment(\.dismiss) private var dismiss

    init(from: String, to: String) {
        self.from = from
        self.to = to
        _best = AppStorage(wrappedValue: 0, "drillBest-\([from, to].sorted().joined(separator: "-"))")
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

            if let finalScore {
                results(finalScore)
            } else {
                drill
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 34)
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onDisappear { if running { listener.stop() } }
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
                }
            } else {
                Text("Switch between the two chords as many times as you can in 60 seconds. The mic counts clean changes.")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await start() }
                } label: {
                    Text("Start")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.vertical, 13)
                        .padding(.horizontal, 44)
                        .background(Capsule().fill(Color.spotifyGreen))
                }
                .buttonStyle(.plain)
            }
            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.destructive)
            }
        }
        .padding(.horizontal, 12)
    }

    private func results(_ score: Int) -> some View {
        VStack(spacing: 16) {
            Text("\(score)")
                .font(.system(size: 84, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.spotifyGreen)
            Text(score > best ? "New best!" : "changes in a minute")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Button {
                finalScore = nil
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
        .onAppear { if score > best { best = score } }
    }

    private func chordTile(_ name: String) -> some View {
        let active = listener.current == name && running
        return Text(name)
            .font(.system(size: 30, weight: .heavy, design: .rounded))
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
        do {
            try await listener.start(chordA: from, chordB: to)
        } catch {
            self.error = error.localizedDescription
            return
        }
        running = true
        remaining = 60
        while remaining > 0, running {
            try? await Task.sleep(for: .seconds(1))
            withAnimation { remaining -= 1 }
        }
        listener.stop()
        running = false
        finalScore = listener.changes
    }
}
