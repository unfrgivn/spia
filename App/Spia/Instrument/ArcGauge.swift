import SpiaKit
import SwiftUI

/// A dial like the app icon's: a 270° arc, nine ticks, and a needle that sweeps to the value
/// when it appears. Coloured by what the value means, not by how big it is.
struct ArcGauge: View {
    /// Nil draws the dial at rest: nothing read yet.
    let value: Double?
    let range: ClosedRange<Double>
    let tone: Tone
    var size: CGFloat = 44

    @State private var sweep = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let stroke = StrokeStyle(lineWidth: size * 0.1, lineCap: .round)
        ZStack {
            DialArc(fraction: 1).stroke(Palette.gaugeTrack, style: stroke)
            DialArc(fraction: sweep).stroke(tone.color, style: stroke)
            ForEach(0..<9, id: \.self) { tick in
                Capsule()
                    .fill(Palette.tertiary)
                    .frame(width: max(1, size * 0.025), height: size * 0.09)
                    .offset(y: -size * 0.27)
                    .rotationEffect(DialArc.angle(at: Double(tick) / 8) + .degrees(90))
            }
            Needle(fraction: sweep)
                .fill(value == nil ? Palette.tertiary : tone.color)
            Circle()
                .fill(Palette.primary)
                .frame(width: size * 0.16, height: size * 0.16)
        }
        .frame(width: size, height: size)
        .onAppear { settle(on: fraction) }
        .onChange(of: fraction) { _, target in settle(on: target) }
        .accessibilityHidden(true)
    }

    private var fraction: Double {
        guard let value else { return 0 }
        let span = range.upperBound - range.lowerBound
        return min(1, max(0, (value - range.lowerBound) / span))
    }

    private func settle(on target: Double) {
        if reduceMotion {
            sweep = target
        } else {
            withAnimation(.easeOut(duration: 0.6)) { sweep = target }
        }
    }
}

/// The dial's arc from its start (bottom left) through `fraction` of its 270°.
private struct DialArc: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    /// Where on the dial a fraction of the range sits: 135° at the start, 405° at the end.
    static func angle(at fraction: Double) -> Angle { .degrees(135 + 270 * fraction) }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: min(rect.width, rect.height) * 0.42,
            startAngle: Self.angle(at: 0), endAngle: Self.angle(at: fraction), clockwise: false)
        return path
    }
}

/// A tapered needle from the hub towards the arc, pointing at `fraction` of the dial.
private struct Needle: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let length = min(rect.width, rect.height) * 0.36
        let base = length * 0.09
        let angle = DialArc.angle(at: fraction).radians
        let tip = CGPoint(x: center.x + cos(angle) * length, y: center.y + sin(angle) * length)
        let side = angle + .pi / 2
        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: center.x + cos(side) * base, y: center.y + sin(side) * base))
        path.addLine(to: CGPoint(x: center.x - cos(side) * base, y: center.y - sin(side) * base))
        path.closeSubpath()
        return path
    }
}

#Preview("Gauges", traits: .sizeThatFitsLayout) {
    HStack(spacing: 24) {
        ArcGauge(value: 11.7, range: 10...16, tone: .bad)
        ArcGauge(value: 12.6, range: 10...16, tone: .good, size: 72)
        ArcGauge(value: nil, range: 10...16, tone: .neutral, size: 120)
    }
    .padding()
    .background(Palette.panel)
}
