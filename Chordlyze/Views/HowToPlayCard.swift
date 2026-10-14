import SwiftUI

/// "How to play this": the few things worth knowing before you play the
/// song, each worked out from its chart and tab, with the hardest change one
/// tap from its drill.
struct HowToPlayCard: View {
    let guide: HowToPlay

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HOW TO PLAY THIS").font(.system(size: 11, weight: .heavy)).tracking(1.4)
                .foregroundStyle(MusicStyle.accent)
            line("music.note.list", firstChords)
            if let hands = hands { line("hand.raised", hands) }
            if let change = guide.change {
                HStack(alignment: .center, spacing: 10) {
                    line("arrow.left.arrow.right",
                         "\(change.from) → \(change.to) is the change to practice: \(change.count)× in the song, \(HowToPlay.seconds(change.fastest)) to switch.")
                    NavigationLink { DrillView(from: change.from, to: change.to) } label: {
                        Text("Drill").font(.subheadline.weight(.semibold)).foregroundStyle(MusicStyle.accent)
                            .padding(.horizontal, 14).frame(minHeight: 44)
                            .background(Color.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(MusicPressStyle())
                    .accessibilityIdentifier("how-to-play-drill")
                }
            }
            if let strum = guide.strum {
                VStack(alignment: .leading, spacing: 8) {
                    line("metronome", "Strum at about \(Int(strum.bpm)) BPM" + (strum.share < 0.6 ? "; the song varies it, so treat this as the backbone." : "."))
                    StrumStrip(strum: strum).padding(.leading, 30)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MusicStyle.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("how-to-play")
    }

    private var firstChords: String {
        let first = guide.firstChords
        if guide.chords.count <= first.names.count {
            return "You need \(guide.chords.count) chord\(guide.chords.count == 1 ? "" : "s"): \(HowToPlay.list(first.names))."
        }
        return "Learn \(HowToPlay.list(first.names)) first: \(first.percent)% of the song."
    }

    private var hands: String? {
        let capo = guide.capo > 0 ? "Capo on fret \(guide.capo)." : nil
        let parts = [capo, guide.anchorLine].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func line(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).font(.footnote.weight(.semibold)).foregroundStyle(MusicStyle.secondary)
                .frame(width: 20)
            Text(text).font(.subheadline).foregroundStyle(MusicStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One bar of the strum: four beats of four sixteenths, down and up strokes
/// where you strike, beat numbers underneath.
struct StrumStrip: View {
    let strum: HowToPlay.Strum

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { beat in
                HStack(spacing: 1) {
                    ForEach(0..<4, id: \.self) { sub in
                        let stroke = strum.slots[beat * 4 + sub]
                        VStack(spacing: 3) {
                            Image(systemName: stroke == .down ? "arrow.down" : stroke == .up ? "arrow.up" : "circle.fill")
                                .font(.system(size: stroke == nil ? 3 : 12, weight: .bold))
                                .foregroundStyle(stroke == nil ? MusicStyle.rule : MusicStyle.ink)
                                .frame(maxWidth: .infinity, minHeight: 16)
                            Text(sub == 0 ? "\(beat + 1)" : sub == 2 ? "&" : "")
                                .font(.system(size: 10, weight: sub == 0 ? .bold : .regular, design: .rounded))
                                .foregroundStyle(MusicStyle.secondary)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let counts = ["", "e", "and", "a"]
        let hits = strum.slots.enumerated().compactMap { i, stroke -> String? in
            guard let stroke else { return nil }
            let count = i % 4 == 0 ? "\(i / 4 + 1)" : counts[i % 4]
            return "\(stroke == .down ? "down" : "up") on \(count)"
        }
        return "Strum pattern: " + hits.joined(separator: ", ")
    }
}
