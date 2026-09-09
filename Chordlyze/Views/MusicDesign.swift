import SwiftUI

/// The app's original dark palette, shared by Home, Library and Search.
/// Artwork supplies color only in Home's upper background.
enum MusicStyle {
    static let background = Color.black
    static let surface = Palette.homeCard
    static let ink = Color.white
    static let secondary = Palette.secondaryAlt
    static let rule = Palette.separator
    static let accent = Color.spotifyGreen
    static func font(_ size: CGFloat, bold: Bool = false, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(bold ? "HelveticaNeue-Bold" : "HelveticaNeue", size: size, relativeTo: style)
    }
}

struct MusicSurface: ViewModifier {
    var ambient: Color? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background {
                ZStack(alignment: .top) {
                    MusicStyle.background
                    if let ambient, !reduceTransparency, contrast != .increased {
                        LinearGradient(stops: [
                            .init(color: ambient.opacity(0.8), location: 0),
                            .init(color: ambient.opacity(0.32), location: 0.42),
                            .init(color: .clear, location: 1)
                        ], startPoint: .top, endPoint: .bottom)
                        .frame(height: 540)
                    }
                }.ignoresSafeArea()
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: ambient)
            }
            .foregroundStyle(MusicStyle.ink)
            .font(MusicStyle.font(16))
            .tint(MusicStyle.accent)
            .environment(\.colorScheme, .dark)
            .toolbar(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .tabBar)
    }
}

struct MusicPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
    }
}

struct MusicHeader: View {
    let title: String
    let subtitle: String
    var isRoot = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.nativeBackSwipeEnabled) private var backSwipeEnabled
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !isRoot {
                Button { dismiss() } label: {
                    Label("Back", systemImage: "chevron.left").font(MusicStyle.font(15, bold: true))
                        .frame(minHeight: 44)
                }.buttonStyle(MusicPressStyle())
                    .nativeBackSwipe(isEnabled: backSwipeEnabled)
            }
            Text(title).font(MusicStyle.font(38, bold: true, relativeTo: .largeTitle)).tracking(-1.3)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle).font(MusicStyle.font(15)).foregroundStyle(MusicStyle.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MusicSearchField: View {
    let prompt: String
    @Binding var text: String
    var submit: () -> Void = {}
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(MusicStyle.secondary)
            TextField(prompt, text: $text)
                .font(MusicStyle.font(16)).submitLabel(.search)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onSubmit(submit)
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(MusicStyle.secondary)
                        .frame(width: 44, height: 44)
                }.accessibilityLabel("Clear search").buttonStyle(MusicPressStyle())
            }
        }
        .padding(.leading, 14).padding(.trailing, text.isEmpty ? 14 : 0)
        .frame(minHeight: 52)
        .background(MusicStyle.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct MusicFilters: View {
    @Binding var selection: MusicFilter
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MusicFilter.allCases) { filter in
                    Button { selection = filter } label: {
                        Text(filter.rawValue).font(MusicStyle.font(14, bold: true))
                            .padding(.horizontal, 16).frame(minHeight: 44)
                            .foregroundStyle(selection == filter ? .black : MusicStyle.ink)
                            .background(selection == filter ? MusicStyle.accent : MusicStyle.surface, in: Capsule())
                    }.buttonStyle(MusicPressStyle())
                        .accessibilityAddTraits(selection == filter ? .isSelected : [])
                }
            }
        }
    }
}

struct MusicArtwork: View {
    let url: URL?
    var size: CGFloat = 56
    var body: some View {
        AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: {
            ZStack {
                MusicStyle.surface
                Image(systemName: "music.note").font(.system(size: size * 0.3)).foregroundStyle(MusicStyle.secondary)
            }
        }.frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
    }
}

struct MusicSongRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let artist: String
    let artwork: URL?
    var key: String? = nil
    var detail: String? = nil
    var body: some View {
        (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .center, spacing: 14))) {
            MusicArtwork(url: artwork)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(MusicStyle.font(16, bold: true)).foregroundStyle(MusicStyle.ink).lineLimit(2)
                if !artist.isEmpty { Text(artist).font(MusicStyle.font(13)).foregroundStyle(MusicStyle.secondary).lineLimit(2) }
                if let detail, !detail.isEmpty {
                    Text(detail).font(MusicStyle.font(12)).foregroundStyle(MusicStyle.secondary).lineLimit(2)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let key {
                Text(key).font(MusicStyle.font(15, bold: true)).foregroundStyle(MusicStyle.accent)
                    .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : 78, alignment: typeSize.isAccessibilitySize ? .leading : .trailing)
                    .accessibilityLabel("Key, \(key)")
            } else if !typeSize.isAccessibilitySize {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MusicStyle.secondary).accessibilityHidden(true)
            }
        }.padding(.vertical, 13).contentShape(Rectangle())
    }
}

struct MusicSectionHeading: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(MusicStyle.font(22, bold: true, relativeTo: .title2)).tracking(-0.5)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let detail { Text(detail).font(MusicStyle.font(13)).foregroundStyle(MusicStyle.secondary) }
        }
    }
}

struct MusicNotice: View {
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(MusicStyle.font(18, bold: true))
            Text(message).font(MusicStyle.font(15)).foregroundStyle(MusicStyle.secondary)
            if let actionTitle {
                Button(actionTitle, action: action).font(MusicStyle.font(15, bold: true)).frame(minHeight: 44)
                    .buttonStyle(MusicPressStyle())
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(MusicStyle.surface, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct MusicRule: View {
    var body: some View { Rectangle().fill(MusicStyle.rule).frame(height: 1).accessibilityHidden(true) }
}
