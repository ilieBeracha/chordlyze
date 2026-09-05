import SwiftUI

struct LoginView: View {
    @EnvironmentObject var auth: SpotifyAuth

    private static let bars: [(width: CGFloat, green: Bool)] = [
        (31, false), (66, true), (22, false), (48, false), (40, true), (26, false),
        (57, false), (35, true), (44, false), (24, false), (62, true), (33, false),
    ]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // Chord-bar stack, top-left
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Self.bars.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Self.bars[index].green ? Color.spotifyGreen : Palette.barGray)
                            .frame(width: Self.bars[index].width, height: 6)
                    }
                }
                .padding(.top, 28)

                Spacer()

                Text("CHORDLYZE")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .tracking(2.1)
                    .foregroundStyle(Color.spotifyGreen)
                    .padding(.bottom, 14)

                Text("Every song you love, read as chords.")
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .tracking(-1.5)
                    .lineSpacing(44 * 0.08)
                    .foregroundStyle(.white)
                    .padding(.bottom, 18)

                Text("Connect Spotify to read your music as chords\nand follow it live.")
                    .font(.system(size: 17))
                    .foregroundStyle(Palette.secondary)
                    .lineSpacing(17 * 0.45)
                    .padding(.bottom, 36)

                Button {
                    auth.login()
                } label: {
                    Text("Continue with Spotify")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Capsule().fill(Color.spotifyGreen))
                }
                .buttonStyle(.plain)

                Text("Chordlyze uses your Spotify library and playback.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)

                if let error = auth.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Palette.destructive)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
        }
    }
}
