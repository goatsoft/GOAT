import SwiftUI

/// One goat "strut" easter egg, played along the top edge of the composer: the goat walks
/// in from off-screen right, stops at center to do its thing (poop, or a joy-jump), turns
/// to look at you, then walks off left. Frames are feet-normalized (all three rows sit on
/// one floor line), so the goat stays level the whole way across. Deterministic + reduce-
/// motion aware. Poop and Like share this - only the frame sets and the hop differ.
struct GoatStrut: View {
    /// Imageset name prefixes for the three phases; each has frames `<prefix>0…3`.
    let walk: String
    let act: String
    let look: String
    /// A parabolic leap during the act phase (for the pronk); poop stays grounded.
    var hop: Bool = false
    let onDone: () -> Void

    // Phase durations (seconds) - unhurried strut.
    private let walkIn = 3.0
    private let actDur: Double
    private let lookDur = 2.0
    private let walkOut = 3.0
    private var total: Double { walkIn + actDur + lookDur + walkOut }

    @State private var start = Date()
    @State private var finished = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    init(walk: String, act: String, look: String, hop: Bool = false, onDone: @escaping () -> Void) {
        self.walk = walk
        self.act = act
        self.look = look
        self.hop = hop
        self.onDone = onDone
        self.actDur = hop ? 1.4 : 1.6
    }

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let goatSize: CGFloat = 62
            let centerX = W * 0.52
            let floorY = geo.size.height - goatSize / 2  // constant - the goat never drops
            if reduceMotion {
                Image("\(look)3")
                    .resizable().interpolation(.high).antialiased(true).scaledToFit()
                    .frame(width: goatSize, height: goatSize)
                    .position(x: centerX, y: floorY)
            } else {
                TimelineView(
                    .animation(
                        minimumInterval: 1.0 / 30.0,
                        paused: scenePhase != .active)
                ) { context in
                    let t = context.date.timeIntervalSince(start)
                    Image(frameName(t: t))
                        .resizable().interpolation(.high).antialiased(true).scaledToFit()
                        .frame(width: goatSize, height: goatSize)
                        .position(x: xPosition(t: t, width: W, center: centerX), y: floorY + hopOffset(t: t))
                        // Hard cuts between sprite frames - no implicit cross-fade, or dramatic
                        // pose changes (crouch → airborne) would ghost two frames together.
                        .transaction { $0.animation = nil }
                        .onChange(of: t >= total) { _, done in
                            if done, !finished {
                                finished = true
                                onDone()
                            }
                        }
                }
            }
        }
        .frame(height: 62)
        .allowsHitTesting(false)
        .onAppear {
            // Reduce Motion: skip the stroll, hold a look-frame briefly, then finish.
            if reduceMotion {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    if !finished {
                        finished = true
                        onDone()
                    }
                }
            }
        }
    }

    // MARK: Timeline math

    private func xPosition(t: Double, width W: CGFloat, center: CGFloat) -> CGFloat {
        let off: CGFloat = W + 60
        if t < walkIn {
            return lerp(off, center, ease(t / walkIn))
        } else if t < walkIn + actDur + lookDur {
            return center
        } else {
            let p = (t - walkIn - actDur - lookDur) / walkOut
            return lerp(center, -60, ease(min(1, p)))
        }
    }

    /// Only the pronk leaves the floor - a single parabolic leap during the act phase.
    private func hopOffset(t: Double) -> CGFloat {
        guard hop, t >= walkIn, t < walkIn + actDur else { return 0 }
        let p = (t - walkIn) / actDur
        return -26 * CGFloat(sin(.pi * p))
    }

    private func frameName(t: Double) -> String {
        if t < walkIn {
            return "\(walk)\(Int(t * 6) % 4)"  // walking in
        } else if t < walkIn + actDur {
            let p = (t - walkIn) / actDur
            return "\(act)\(min(3, Int(p * 4)))"  // the deed
        } else if t < walkIn + actDur + lookDur {
            let p = (t - walkIn - actDur) / lookDur
            return "\(look)\(min(3, Int(p * 4)))"  // turn and look - ends front-facing
        } else {
            return "\(walk)\(Int(t * 6) % 4)"  // walking out
        }
    }

    private func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }  // smoothstep
    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
}

/// 👎 - the goat struts in, poops, looks at you, walks off. Stays level throughout.
struct GoatWalk: View {
    let onDone: () -> Void
    var body: some View {
        GoatStrut(walk: "gwalk", act: "gpoop", look: "glook", onDone: onDone)
    }
}

/// 👍 - the goat struts in, leaps for joy, looks at you, walks off. Same choreography.
struct GoatPronk: View {
    let onDone: () -> Void
    var body: some View {
        GoatStrut(walk: "prwalk", act: "prjump", look: "prlook", hop: true, onDone: onDone)
    }
}

/// 🏔️ Summit ("send it") - the goat blasts off on a rocket from the bottom-left, glances at
/// you as it crosses the middle, and streaks off the top-right corner. The art is pre-angled
/// up-right (exhaust and speed lines baked in), so we only translate along the diagonal, never
/// rotate. 12 frames play once across the flight: ahead (0-3), look at you (4-7), ahead (8-11).
/// Deterministic and reduce-motion aware.
struct GoatRocket: View {
    let onDone: () -> Void

    private let duration = 3.2  // a slow, slick glide across the whole view
    private let size: CGFloat = 132
    @State private var start = Date()
    @State private var finished = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if reduceMotion {
                // No flight under Reduce Motion: hold one look-at-you frame, then finish.
                Image("rocket5")
                    .resizable().interpolation(.high).antialiased(true).scaledToFit()
                    .frame(width: size, height: size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                flight
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            guard reduceMotion else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if !finished {
                    finished = true
                    onDone()
                }
            }
        }
    }

    private var flight: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let H = geo.size.height
            TimelineView(
                .animation(
                    minimumInterval: 1.0 / 30.0,
                    paused: scenePhase != .active)
            ) { context in
                let t = context.date.timeIntervalSince(start)
                let p = min(1.0, t / duration)
                Image(frameName(p))
                    .resizable().interpolation(.high).antialiased(true).scaledToFit()
                    .frame(width: size, height: size)
                    .shadow(color: .black.opacity(0.28), radius: 12, x: -4, y: 6)
                    .position(
                        x: lerp(-size * 0.6, W + size * 0.6, ease(p)),
                        y: lerp(H + size * 0.6, -size * 0.6, ease(p))
                    )
                    // Hard cuts between sprite frames, no implicit cross-fade.
                    .transaction { $0.animation = nil }
                    .onChange(of: p >= 1.0) { _, done in
                        if done, !finished {
                            finished = true
                            onDone()
                        }
                    }
            }
        }
    }

    /// 12 frames spread evenly across the flight: ahead (0-3), look at you (4-7), ahead (8-11).
    private func frameName(_ p: Double) -> String { "rocket\(min(11, Int(p * 12)))" }

    private func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }  // smoothstep
    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
}
