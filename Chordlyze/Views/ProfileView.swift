import SwiftUI

/// Profile & settings: Spotify account, reconnect, disconnect.
struct ProfileView: View {
    @EnvironmentObject var auth: SpotifyAuth
    @State private var profile: SpotifyAPI.Profile?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack { BackCircle(); Spacer() }

                Text("Settings")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 20)
                    .padding(.bottom, 24)

                // Account card
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(Palette.greenTintFill).frame(width: 52, height: 52)
                        Text(initial)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.spotifyGreen)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile?.displayName ?? "Spotify account")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(profile.map { "@\($0.id)" } ?? "Connected")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.secondary)
                    }
                    Spacer()
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.card))
                .padding(.bottom, 26)

                SectionLabel("Account")
                    .padding(.bottom, 10)
                VStack(spacing: 0) {
                    settingsRow(icon: "arrow.triangle.2.circlepath", label: "Reconnect Spotify",
                                tint: Color.spotifyGreen) {
                        auth.login()
                    }
                    Rectangle().fill(Palette.separator).frame(height: 0.5).padding(.leading, 52)
                    settingsRow(icon: "rectangle.portrait.and.arrow.right", label: "Disconnect",
                                tint: Palette.destructive) {
                        auth.logout()
                    }
                }
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.card))
                .padding(.bottom, 26)

                SectionLabel("About")
                    .padding(.bottom, 10)
                VStack(spacing: 0) {
                    infoRow(label: "Version",
                            value: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                                + " (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"))")
                    Rectangle().fill(Palette.separator).frame(height: 0.5).padding(.leading, 16)
                    infoRow(label: "Chord engine", value: "Chordlyze cloud")
                }
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.card))

                Text("Disconnecting removes Spotify access from this device. Your analyzed songs stay saved.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.tertiary)
                    .padding(.top, 14)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            profile = try? await SpotifyAPI(auth: auth).me()
        }
    }

    private var initial: String {
        String((profile?.displayName ?? "S").prefix(1)).uppercased()
    }

    private func settingsRow(icon: String, label: String, tint: Color,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(tint)
                    .frame(width: 24)
                Text(label)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(tint)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x5A5A5E))
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 16))
                .foregroundStyle(.white)
            Spacer()
            Text(value)
                .font(.system(size: 15))
                .foregroundStyle(Palette.secondary)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
    }
}
