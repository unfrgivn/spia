import SpiaKit
import SwiftUI

/// A warning lamp: a glyph in a disc, lit in the colour of what it reports, with a caption and
/// a reading beside it. Neutral means unlit: not read yet, so neither good nor bad.
struct Lamp: View {
    let tone: Tone
    let symbol: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            LampDisc(tone: tone, symbol: symbol)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).instrumentCaption()
                Text(value)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tone == .neutral ? Palette.secondary : Palette.primary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

/// A lamp's lit disc on its own, for cards that carry their own headline.
struct LampDisc: View {
    let tone: Tone
    let symbol: String

    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 24
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let lit = tone != .neutral
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .bold))
            .foregroundStyle(lit ? tone.color : Palette.tertiary)
            .frame(width: size, height: size)
            .background(Circle().fill(lit ? tone.color.opacity(0.18) : .clear))
            .overlay(
                Circle().strokeBorder(
                    lit ? tone.color.opacity(0.45) : Palette.tertiary.opacity(0.5))
            )
            // Lamps glow at night; in daylight a glow would only muddy the card.
            .shadow(
                color: lit && colorScheme == .dark ? tone.color.opacity(0.5) : .clear, radius: 6
            )
            .overlay {
                if tone == .working { PulseRing(color: tone.color) }
            }
            .accessibilityHidden(true)
    }
}

/// A ring that swells out of a lamp while Spia is busy; still, when motion is reduced.
private struct PulseRing: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Circle().strokeBorder(color, lineWidth: 1.5)
        } else {
            Circle()
                .strokeBorder(color, lineWidth: 1.5)
                .phaseAnimator([false, true]) { ring, swelling in
                    ring.scaleEffect(swelling ? 1.45 : 1).opacity(swelling ? 0 : 0.9)
                } animation: { swelling in
                    swelling ? .easeOut(duration: 1.2) : nil
                }
        }
    }
}

#Preview("Lamps", traits: .sizeThatFitsLayout) {
    VStack(alignment: .leading, spacing: 14) {
        Lamp(tone: .good, symbol: "engine.combustion", label: "Check engine", value: "Off")
        Lamp(tone: .bad, symbol: "exclamationmark.octagon", label: "Codes", value: "3")
        Lamp(
            tone: .attention, symbol: "exclamationmark.triangle", label: "Adapter",
            value: "Reconnect")
        Lamp(tone: .working, symbol: "play.rectangle", label: "Adapter", value: "Reading")
        Lamp(tone: .neutral, symbol: "engine.combustion", label: "Check engine", value: "Not read")
    }
    .padding()
    .background(Palette.panel)
}
