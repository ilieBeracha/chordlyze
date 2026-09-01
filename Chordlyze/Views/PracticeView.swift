import SwiftUI

/// Practice mode: song in headphones, instrument at the mic. Runs the
/// follow-along teleprompter on a local clock while recording, then uploads
/// the take for scoring against the song's chart.
struct PracticeView: View {
    let analysis: ChordAnalysis
    let title: String
    let artist: String
    let trackID: String

    private enum Phase: Equatable {
        case intro
        case countdown(Int)
        case recording
        case uploading
        case failed(String)
    }

    @StateObject private var recorder = ListenRecorder()
    @State private var phase: Phase = .intro
    @State private var startedAt: Date?
    @State private var report: BackendClient.PracticeReport?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            switch phase {
            case .intro:
                intro
            case .countdown(let n):
                countdown(n)
            case .recording:
                recordingView
            case .uploading:
                statusView("Scoring your take…", spinning: true)
            case .failed(let message):
                failedView(message)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: Binding(
            get: { report != nil },
            set: { if !$0 { report = nil } })) {
            if let report {
                ReportCardView(report: report, title: title, artist: artist)
            }
        }
    }

    // MARK: - Phases

    private var intro: some View {
        VStack(spacing: 0) {
            HStack { BackCircle(size: 38); Spacer() }
            Spacer()
            VStack(spacing: 18) {
                Image(systemName: "headphones")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.spotifyGreen)
                Text("Practice \(title)")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text("Put the song in your headphones — the mic should hear only your instrument. Play along from the top; stop whenever you like.")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await begin() }
                } label: {
                    Text("Start")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.vertical, 13)
                        .padding(.horizontal, 44)
                        .background(Capsule().fill(Color.spotifyGreen))
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
            }
            .padding(.horizontal, 30)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 34)
    }

    private func countdown(_ n: Int) -> some View {
        Text("\(n)")
            .font(.system(size: 110, weight: .heavy, design: .rounded))
            .foregroundStyle(Color.spotifyGreen)
            .contentTransition(.numericText(countsDown: true))
    }

    private var recordingView: some View {
        ZStack(alignment: .bottom) {
            LiveNowView(title: title, artist: artist, analysis: analysis) {
                startedAt.map { Date().timeIntervalSince($0) }
            }
            HStack(spacing: 10) {
                Circle().fill(Palette.destructive).frame(width: 8, height: 8)
                Text("REC")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Palette.destructive)
                Spacer()
                Button {
                    finish()
                } label: {
                    Text("Finish take")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 22)
                        .background(Capsule().fill(Color.spotifyGreen))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 64)
        }
    }

    private func statusView(_ message: String, spinning: Bool) -> some View {
        VStack(spacing: 14) {
            if spinning { ProgressView() }
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Palette.secondary)
        }
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Button {
                phase = .intro
            } label: {
                Text("Try again")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.vertical, 11)
                    .padding(.horizontal, 26)
                    .background(Capsule().fill(Color.spotifyGreen))
            }
            .buttonStyle(.plain)
            BackCircle(size: 38)
        }
    }

    // MARK: - Flow

    private func begin() async {
        guard await recorder.requestPermission() else {
            phase = .failed("Microphone access denied — enable it in Settings.")
            return
        }
        for n in [3, 2, 1] {
            withAnimation { phase = .countdown(n) }
            try? await Task.sleep(for: .seconds(1))
        }
        do {
            try recorder.start(maxDuration: 600)
            startedAt = Date()
            phase = .recording
        } catch {
            phase = .failed("Could not start recording: \(error.localizedDescription)")
        }
    }

    private func finish() {
        guard let url = recorder.stop() else {
            phase = .failed("Nothing was recorded.")
            return
        }
        phase = .uploading
        Task {
            do {
                report = try await BackendClient.submitPracticeTake(fileURL: url, trackID: trackID)
            } catch {
                phase = .failed(error.localizedDescription)
            }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
