import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// Design tokens from the Chordlyze redesign handoff.
enum Palette {
    static let card = Color(hex: 0x141414)
    /// Home cards (design 8a).
    static let homeCard = Color(hex: 0x101010)
    static let elevated = Color(hex: 0x1C1C1E)
    static let gray5 = Color(hex: 0x2C2C2E)
    static let nearWhite = Color(hex: 0xE5E5EA)
    static let secondary = Color(hex: 0x8E8E93)
    static let secondaryAlt = Color(hex: 0x98989F)
    /// Lyric lines that are not the one being sung, in Live.
    static let lyricDim = Color(hex: 0xAEAEB2)
    static let tertiary = Color(hex: 0x636366)
    static let faint = Color(hex: 0x48484A)
    static let barGray = Color(hex: 0x232325)
    static let destructive = Color(hex: 0xFF453A)
    static let successCheck = Color(hex: 0x30D158)
    static let heroBackground = Color(hex: 0x0E2917)
    static let heroSub = Color(hex: 0x8FBF9F)
    static let greenTintFill = Color.spotifyGreen.opacity(0.13)
    static let greenTintBorder = Color.spotifyGreen.opacity(0.35)
    static let separator = Color(red: 84 / 255, green: 84 / 255, blue: 88 / 255).opacity(0.4)
    /// Disclosure chevron on list rows.
    static let chevron = Color(hex: 0x5A5A5E)
    static let warning = Color(hex: 0xFFD60A)

    /// Difficulty dot: "easy" | "medium" | "hard".
    static func difficulty(_ level: String) -> Color {
        switch level {
        case "easy": return successCheck
        case "medium": return warning
        default: return destructive
        }
    }
}

extension String {
    /// True when the first strongly-directional character is right-to-left
    /// (Hebrew/Arabic), so the line should lay out RTL.
    var isRTLText: Bool {
        for scalar in unicodeScalars {
            switch scalar.value {
            case 0x0590...0x05FF, 0x0600...0x06FF, 0x0750...0x077F,
                 0xFB1D...0xFDFF, 0xFE70...0xFEFF:
                return true
            case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F:
                return false
            default:
                continue
            }
        }
        return false
    }
}

/// Uppercase section label: 13pt/700, 0.1em tracking.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 13, weight: .bold))
            .tracking(1.3)
            .foregroundStyle(Palette.secondary)
    }
}

/// Circular back button used by the custom headers.
struct BackCircle: View {
    var size: CGFloat = 44
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(Palette.elevated))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
    }
}

/// Chord picked for its diagram sheet, from any screen that shows chords.
struct SelectedChord: Identifiable {
    let name: String
    var id: String { name }
}

/// "3:07" from seconds; negative clamps to 0:00.
func mmss(_ seconds: Double) -> String {
    String(format: "%d:%02d", Int(max(0, seconds)) / 60, Int(max(0, seconds)) % 60)
}

/// List row for a song: artwork, title over artist, and whatever goes on
/// the right (key badge, chevron). Library and Search share it.
struct SongRow<Trailing: View>: View {
    let artworkURL: URL?
    let title: String
    let artist: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 13) {
            AsyncImage(url: artworkURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                LinearGradient(colors: [Palette.gray5, Palette.elevated],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !artist.isEmpty {
                    Text(artist)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing()
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 20)
        .contentShape(Rectangle())
    }
}

/// Song key as a large root over a small mode ("A#" / "minor"), with the
/// difficulty dot beside the root when known.
struct KeyBadge: View {
    let key: String
    var difficulty: String? = nil

    var body: some View {
        let (root, mode) = Self.split(key)
        VStack(alignment: .trailing, spacing: 0) {
            HStack(spacing: 5) {
                if let difficulty {
                    Circle()
                        .fill(Palette.difficulty(difficulty))
                        .frame(width: 6, height: 6)
                }
                Text(root)
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.spotifyGreen)
            }
            if !mode.isEmpty {
                Text(mode)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Palette.tertiary)
            }
        }
    }

    /// "A# minor" -> ("A#", "minor"); keeps sharps/flats as the backend sent them.
    private static func split(_ key: String) -> (root: String, mode: String) {
        let parts = key.split(separator: " ", maxSplits: 1)
        guard let first = parts.first else { return (key, "") }
        return (String(first), parts.count > 1 ? parts[1].lowercased() : "")
    }
}
