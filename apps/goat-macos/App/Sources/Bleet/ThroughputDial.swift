import Caprine
import SwiftUI

/// Vector dial with an animated needle. The scale only grows during a response so
/// a slowdown visibly drops the needle instead of continually rescaling the gauge.
struct ThroughputDial: View {
    let rate: Double?
    let maximum: Double
    let estimated: Bool
    let live: Bool
    let tokens: Caprine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var validRate: Double? {
        rate.flatMap { $0.isFinite && $0 >= 0 && $0 <= 1_000_000 ? $0 : nil }
    }
    private var fraction: Double { min(1, max(0, (validRate ?? 0) / maximum)) }
    private var readout: String {
        validRate.map { "\(estimated ? "~" : "")\($0.formatted(.number.precision(.fractionLength(1))))" }
            ?? (live ? "…" : "-")
    }

    var body: some View {
        ZStack {
            Canvas { context, size in
                let dial = DialGeometry(size: size)
                var arc = Path()
                arc.addArc(
                    center: dial.center, radius: dial.radius,
                    startAngle: .degrees(150), endAngle: .degrees(390), clockwise: false)
                context.stroke(arc, with: .color(tokens.muted.opacity(0.3)), lineWidth: 8)
                for tick in 0...25 {
                    let progress = Double(tick) / 25
                    let major = tick.isMultiple(of: 5)
                    var mark = Path()
                    mark.move(to: dial.point(progress, radius: dial.radius - (major ? 13 : 8)))
                    mark.addLine(to: dial.point(progress, radius: dial.radius - 1))
                    context.stroke(
                        mark, with: .color(major ? tokens.ink : tokens.muted.opacity(0.7)),
                        lineWidth: major ? 2.5 : 1.5)
                    if major {
                        let label = Text(ContextStatus.compact(Int(maximum * progress)))
                            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(tokens.ink.opacity(0.85))
                        context.draw(label, at: dial.point(progress, radius: dial.radius - 28))
                    }
                }
                context.fill(
                    Path(ellipseIn: CGRect(x: dial.center.x - 6, y: dial.center.y - 6, width: 12, height: 12)),
                    with: .color(tokens.tint))
            }
            DialNeedle(fraction: fraction)
                .stroke(tokens.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .opacity(validRate == nil ? 0 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: fraction)
            VStack(spacing: 1) {
                Spacer()
                Text(readout)
                    .font(.title3.weight(.bold)).monospacedDigit()
                    .foregroundStyle(tokens.ink)
                Text("tok/s").font(.caption2).foregroundStyle(tokens.muted)
            }
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1.55, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(live ? "Live generation speed" : "Generation speed")
        .accessibilityValue("\(readout) tokens per second, scale zero to \(Int(maximum))")
    }
}

private struct DialGeometry {
    let center: CGPoint
    let radius: CGFloat

    init(size: CGSize) {
        radius = max(0, min(size.width / 2 - 10, (size.height - 36) / 1.5))
        center = CGPoint(x: size.width / 2, y: radius + 7)
    }

    func point(_ fraction: Double, radius: CGFloat) -> CGPoint {
        let angle = (150 + fraction * 240) * .pi / 180
        return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }
}

private struct DialNeedle: Shape {
    var fraction: Double
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let dial = DialGeometry(size: rect.size)
        var path = Path()
        path.move(to: dial.center)
        path.addLine(to: dial.point(fraction, radius: dial.radius - 13))
        return path
    }
}
