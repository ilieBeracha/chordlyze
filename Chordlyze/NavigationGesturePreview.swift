#if DEBUG
import SwiftUI

/// Exercises the real custom headers and native navigation without account access.
struct NavigationGesturePreview: View {
    @State private var disappearances = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                MusicHeader(title: "Gesture preview", subtitle: "Offline navigation checks")
                NavigationLink {
                    GestureDetail(disappearances: $disappearances)
                } label: {
                    Text("Open detail").frame(minHeight: 44)
                }.accessibilityIdentifier("gesture-open-detail")
                disappearanceCount
                Spacer()
            }
            .padding(24)
            .modifier(MusicSurface())
        }
    }

    private var disappearanceCount: some View {
        Text("Departures: \(disappearances)")
            .accessibilityIdentifier("gesture-disappear-count")
            .accessibilityValue(String(disappearances))
    }
}

private struct GestureDetail: View {
    @Binding var disappearances: Int
    @State private var locked = false
    @State private var settings = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                BackCircle()
                Text("Song detail").font(.title2.bold()).accessibilityIdentifier("gesture-detail")
                Spacer()
            }
            Text("Departures: \(disappearances)")
                .accessibilityIdentifier("gesture-disappear-count")
                .accessibilityValue(String(disappearances))
            Toggle("Recording protection", isOn: $locked).accessibilityIdentifier("gesture-lock-back")
            NavigationLink {
                VStack {
                    MusicHeader(title: "Nested page", subtitle: "Swipe back one page", isRoot: false)
                    Text("Nested content").accessibilityIdentifier("gesture-nested")
                    Spacer()
                }.padding(24).modifier(MusicSurface())
            } label: { Text("Open nested page").frame(minHeight: 44) }
                .accessibilityIdentifier("gesture-open-nested")
            Button("Song settings") { settings = true }
                .frame(minHeight: 44).accessibilityIdentifier("gesture-open-settings")
            NavigationLink {
                Form { Text("Standard navigation").accessibilityIdentifier("gesture-standard") }
                    .navigationTitle("Standard page")
                    .toolbar(.visible, for: .navigationBar)
            } label: { Text("Open standard page").frame(minHeight: 44) }
                .accessibilityIdentifier("gesture-open-standard")
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    ForEach(0..<30) { index in
                        Text("Lyric line \(index + 1)").font(.title2)
                    }
                    Text("End of song").accessibilityIdentifier("gesture-bottom")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.accessibilityIdentifier("gesture-lyrics")
        }
        .padding(24)
        .modifier(MusicSurface())
        .environment(\.nativeBackSwipeEnabled, !locked)
        .onDisappear { disappearances += 1 }
        .sheet(isPresented: $settings) {
            GestureSettings()
        }
    }
}

private struct GestureSettings: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form { Text("Drag down to close.") }
                .navigationTitle("Gesture settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.presentationDragIndicator(.visible)
    }
}
#endif
