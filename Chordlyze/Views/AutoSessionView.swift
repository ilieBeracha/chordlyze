import SwiftUI

/// Hands-free mode: play a playlist out loud; every song gets identified and
/// its chords analyzed automatically, one after another.
struct AutoSessionView: View {
    @ObservedObject private var session = AutoSession.shared

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Button {
                        Task {
                            if session.isRunning { session.stop() }
                            else { await session.start() }
                        }
                    } label: {
                        Label(session.isRunning ? "Stop Session" : "Start Session",
                              systemImage: session.isRunning ? "stop.circle.fill" : "infinity.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(session.isRunning ? .red : .green)
                    if !session.statusLine.isEmpty {
                        Text(session.statusLine)
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("Start, then play your Spotify playlist out loud. Each song is identified and analyzed automatically.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            if let nowKey = session.nowPlayingKey,
               let entry = session.entries.first(where: { $0.id == nowKey }),
               let analysis = entry.analysis {
                Section {
                    NavigationLink {
                        LiveNowView(session: session, entry: entry, analysis: analysis)
                    } label: {
                        HStack(spacing: 10) {
                            Circle().fill(Color.spotifyGreen).frame(width: 8, height: 8)
                            VStack(alignment: .leading) {
                                Text("Follow live: \(entry.title)")
                                    .font(.headline)
                                Text("Lyrics and chords scroll with the song")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if !session.entries.isEmpty {
                Section("This session") {
                    ForEach(session.entries) { entry in
                        row(entry)
                    }
                }
            }
        }
        .navigationTitle("Auto Session")
    }

    @ViewBuilder
    private func row(_ entry: AutoSession.Entry) -> some View {
        if let analysis = entry.analysis {
            NavigationLink {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(entry.artist).font(.subheadline).foregroundStyle(.secondary)
                        AnalysisTabsView(analysis: analysis, title: entry.title, artist: entry.artist)
                    }
                    .padding()
                }
                .navigationTitle(entry.title)
                .navigationBarTitleDisplayMode(.large)
            } label: {
                label(entry)
            }
        } else {
            label(entry)
        }
    }

    private func label(_ entry: AutoSession.Entry) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(entry.title).font(.body)
                Text(entry.artist).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch entry.status {
            case .capturing:
                Label("listening", systemImage: "waveform.badge.mic")
                    .font(.caption).foregroundStyle(.blue)
            case .analyzing:
                ProgressView().controlSize(.small)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(message)
            }
        }
    }
}
