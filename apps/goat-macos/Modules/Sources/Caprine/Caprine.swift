import SwiftUI

/// Caprine v2 - the GOATed pass. Palette derived from the app icon: neon azure → violet
/// ring on deep navy. Pasture is the exception by design: browns and greens, an actual
/// pasture. See docs/DESIGN.md. Views take colors from here, never hardcoded.
public struct Caprine: Sendable {
    public enum Activity {
        public static let spacing: CGFloat = 8
        public static let inset: CGFloat = 12
        public static let radius: CGFloat = 10
        public static let font: Font = .caption
    }

    public let bg: Color
    public let surface: Color
    public let ink: Color
    public let muted: Color
    public let accent: Color  // primary neon (azure, or moss in Pasture)
    public let accent2: Color  // secondary neon (violet, or saddle brown in Pasture)
    public let glow: Color
    public let selection: Color  // sidebar/list selection tint
    private let tintOverride: Color?
    /// The interactive-control color (buttons, toggles, sliders, carets). Defaults to accent;
    /// 1337 overrides to purple so nothing reads as system blue.
    public var tint: Color { tintOverride ?? accent }
    public let washOpacity: Double
    public let bgOpacity: Double  // how much theme color sits over the window glass
    public let intensity: Double  // multiplies tints/glows - 1337 runs hot
    public let userBubble: Color  // flat fallback; bubbles prefer bubbleGradient

    public init(
        bg: Color, surface: Color, ink: Color, muted: Color,
        accent: Color, accent2: Color, glow: Color, selection: Color,
        tint: Color? = nil,
        washOpacity: Double, bgOpacity: Double = 0.35, intensity: Double = 1.0,
        userBubble: Color
    ) {
        self.bg = bg
        self.surface = surface
        self.ink = ink
        self.muted = muted
        self.accent = accent
        self.accent2 = accent2
        self.glow = glow
        self.selection = selection
        self.tintOverride = tint
        self.washOpacity = washOpacity
        self.bgOpacity = bgOpacity
        self.intensity = intensity
        self.userBubble = userBubble
    }

    public var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    public var bubbleGradient: LinearGradient {
        LinearGradient(
            colors: [
                accent.opacity(min(0.34, 0.15 * intensity)),
                accent2.opacity(min(0.30, 0.12 * intensity)),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

extension Color {
    public init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - Caprine surfaces

/// The themed backdrop over the window glass. The transparency dial runs from solid to
/// maximum transparency. The default adds a little opacity above the theme's midpoint baseline.
public struct CaprineBackground: View {
    public static let defaultTransparency = 0.4
    private let tokens: Caprine
    private let transparency: Double  // 0 solid … 0.5 theme baseline … 1 very see-through
    private let extraOpacity: Double  // popups add a little floor so text reads
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    public init(
        _ tokens: Caprine, transparency: Double = CaprineBackground.defaultTransparency, extraOpacity: Double = 0
    ) {
        self.tokens = tokens
        self.transparency = transparency
        self.extraOpacity = extraOpacity
    }

    /// Slider 0 → fully opaque; 0.5 → the theme's own bgOpacity; 1 → nearly clear.
    private var floor: Double {
        if reduceTransparency || contrast == .increased { return 1 }
        let t = min(1, max(0, transparency))
        let base: Double
        if t <= 0.5 {
            base = 1.0 + (tokens.bgOpacity - 1.0) * (t / 0.5)  // 1.0 → bgOpacity
        } else {
            base = tokens.bgOpacity + (0.12 - tokens.bgOpacity) * ((t - 0.5) / 0.5)  // bgOpacity → 0.12
        }
        return min(1.0, max(0.0, base + extraOpacity))
    }

    public var body: some View {
        let wash = contrast == .increased ? 0 : tokens.washOpacity
        ZStack {
            tokens.bg.opacity(floor)
            // Violet settling in from the bottom-right, azure from the top-left - soft crossfade.
            LinearGradient(
                stops: [
                    .init(color: tokens.accent2.opacity(wash), location: 0.0),
                    .init(color: tokens.accent2.opacity(wash * 0.4), location: 0.3),
                    .init(color: tokens.accent.opacity(wash * 0.4), location: 0.7),
                    .init(color: tokens.accent.opacity(wash), location: 1.0),
                ],
                startPoint: .bottomTrailing,
                endPoint: .topLeading
            )
        }
        .ignoresSafeArea()
    }
}

/// The icon's neon ring, borrowed: static and faint at rest, sweeping while the goat works.
/// Honors Reduce Motion (static ring, no sweep).
public struct NeonRing: View {
    private let tokens: Caprine
    private let active: Bool
    private let animates: Bool
    private let cornerRadius: CGFloat
    private let idleOpacity: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        tokens: Caprine,
        active: Bool,
        cornerRadius: CGFloat,
        idleOpacity: Double = 0.35,
        animates: Bool = true
    ) {
        self.tokens = tokens
        self.active = active
        self.cornerRadius = cornerRadius
        self.idleOpacity = idleOpacity
        self.animates = animates
    }

    public var body: some View {
        if active && animates && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3
                ring(start: .degrees(phase * 360), opacity: 1, lineWidth: 1.5)
                    .shadow(color: tokens.glow.opacity(0.55), radius: 7)
            }
        } else {
            ring(start: .degrees(45), opacity: active ? 0.9 : idleOpacity, lineWidth: idleOpacity > 0.5 ? 1.5 : 1)
                .shadow(color: tokens.glow.opacity(idleOpacity > 0.5 ? 0.45 : 0), radius: 8)
        }
    }

    private func ring(start: Angle, opacity: Double, lineWidth: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(
                AngularGradient(
                    colors: [tokens.accent, tokens.accent2, tokens.accent],
                    center: .center,
                    startAngle: start,
                    endAngle: start + .degrees(360)
                ),
                lineWidth: lineWidth
            )
            .opacity(opacity)
            .allowsHitTesting(false)
    }
}
