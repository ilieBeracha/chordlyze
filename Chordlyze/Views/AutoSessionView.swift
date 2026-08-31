import SwiftUI

/// Status-first hands-free session screen (design 2f).
struct AutoSessionView: View {
    @ObservedObject private var session = AutoSession.shared

    private var nowEntry: AutoSession.Entry? {
        session.nowPlayingKey.flatMap { key in session.entries.first(where: { $0.id == key }) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                BackCircle()
                Spacer()
                Button {
                    Task {
                        if session.isRunning { session.stop() }
                        else { await session.start() }
                    }
                } label: {
                    Text(session.isRunning ? "Stop" : "Start")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(session.isRunning ? Palette.destructive : .black)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 18)
                        .background(Capsule().fill(session.isRunning
                            ? Palette.destructive.opacity(0.14)
                            : Color.spotifyGreen))
                }
                .buttonStyle(.plain)
            }

            // Hero
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .stroke(Palette.greenTintBorder, lineWidth: 2)
                        .frame(width: 108, height: 108)
                    Circle()
                        .fill(Color.spotifyGreen.opacity(0.12))
                        .frame(width: 84, height: 84)
                    Image(systemName: "infinity")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.spotifyGreen)
                }
                VStack(spacing: 6) {
                    Text(session.isRunning ? "SESSION LIVE" : "SESSION IDLE")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(session.isRunning ? Color.spotifyGreen : Palette.tertiary)
                    Text(nowEntry?.title ?? (session.isRunning ? "Listening…" : "Chords while you listen"))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Text(nowEntry?.artist ?? (session.isRunning
                        ? "Play anything out loud."
                        : "Start, then play your music out loud."))
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.secondary)
                }
                if let entry = nowEntry, let analysis = entry.analysis {
                    NavigationLink {
                        LiveNowView(session: session, entry: entry, analysis: analysis)
                    } label: {
                        HStack(spacing: 8) {
                            Circle().fill(.black).frame(width: 7, height: 7)
                            Text("Follow live")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.black)
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 22)
                        .background(Capsule().fill(Color.spotifyGreen))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 54)

            Spacer()

            if !session.entries.isEmpty {
                SectionLabel("This session")
                    .padding(.bottom, 14)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(session.entries) { entry in
                            entryRow(entry)
                        }
                    }
                }
                .frame(maxHeight: 280)
            } else if !session.statusLine.isEmpty {
                Text(session.statusLine)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 40)
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private func entryRow(_ entry: AutoSession.Entry) -> some View {
        let isNow = entry.id == session.nowPlayingKey
        let row = HStack(spacing: 14) {
            Circle()
                .fill(isNow ? Color.spotifyGreen : Palette.gray5)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle(entry))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
            }
            Spacer()
            trailing(entry, isNow: isNow)
        }
        .padding(.vertical, 10)

        if let analysis = entry.analysis {
            NavigationLink {
                AnalysisTabsView(analysis: analysis, title: entry.title, artist: entry.artist)
            } label: {
                row
            }
            .buttonStyle(.plain)
        } else {
            row
        }
    }

    private func subtitle(_ entry: AutoSession.Entry) -> String {
        let artist = entry.artist.uppercased()
        if let key = entry.analysis?.key {
            return artist.isEmpty ? key : "\(artist) · \(key)"
        }
        return artist
    }

    @ViewBuilder
    private func trailing(_ entry: AutoSession.Entry, isNow: Bool) -> some View {
        if isNow {
            Text("now")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.spotifyGreen)
        } else {
            switch entry.status {
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Palette.successCheck)
            case .analyzing:
                ProgressView().controlSize(.small)
            case .capturing:
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 15))
                    .foregroundStyle(.blue)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.orange)
            }
        }
    }
}
