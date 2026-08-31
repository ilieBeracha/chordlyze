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
    static let elevated = Color(hex: 0x1C1C1E)
    static let gray5 = Color(hex: 0x2C2C2E)
    static let nearWhite = Color(hex: 0xE5E5EA)
    static let secondary = Color(hex: 0x8E8E93)
    static let secondaryAlt = Color(hex: 0x98989F)
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
        }
        .buttonStyle(.plain)
    }
}
