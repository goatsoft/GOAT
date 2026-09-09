# ADR-0011: Liquid Glass adoption & true window translucency

**Status:** Accepted · 2026-08-29 · Extends [ADR-0002](0002-ui-architecture.md), amends Caprine ([DESIGN.md](../DESIGN.md))

## Context

Caprine v2 leaned on `.ultraThinMaterial` + hand-painted gradient washes. On the real window it read *opaque*: no desktop showing through. Root cause, confirmed against the [Liquid Glass reference](https://github.com/conorluddy/LiquidGlassReference): SwiftUI `WindowGroup` windows are **opaque by default**, and there is **no SwiftUI API to set `NSWindow.isOpaque`**. A material rendered in an opaque window samples the window's own backing, not the desktop, so it looks solid. JB wants the modern macOS 26 (Tahoe) treatment with genuine alpha.

## Decision

- **True translucency via an AppKit hook.** `WindowConfigurator` (an `NSViewRepresentable`) reaches the host `NSWindow` and sets `isOpaque = false`, `backgroundColor = .clear`, `titlebarAppearsTransparent = true`. This is the sanctioned path: the reference is SwiftUI-only and offers nothing for window opacity, so AppKit is required. Painted alpha now reveals the desktop.
- **Adopt the real Liquid Glass primitives** (macOS 26 only; deployment target is 26.0 so no availability gate needed):
  - Composer floats on `glassEffect(.regular, in: .rect(cornerRadius: 20))`.
  - Model/effort capsule and other floating chrome use `glassEffect`.
  - Sidebar `List` uses `scrollContentBackground(.hidden)` so the window glass shows through (the split view auto-floats its glass on 26).
  - Circular buttons that use prominent fills get `clipShape(Circle())` to avoid the documented `.glassProminent`/`.circle` artifact.
- **Layering discipline** (per the reference): glass belongs to the *navigation/overlay* layer, never the content layer. The transcript stays plain; only floating surfaces get glass. No glass-on-glass stacking.
- **Caprine backdrop** stays a low-alpha color floor + gradient wash *over* the now-translucent window, tuned by the Transparency slider. The floor dropped so the desktop genuinely reads through.

## Consequences

Real see-through windows in the native idiom; the wash tints the desktop rather than hiding it. One small AppKit surface (`WindowConfigurator`), acceptable and idiomatic. Reduce Transparency / Reduce Motion remain system-honored (glass and the Neon Ring both respond). `GlassEffectContainer` for grouped morphing is available if we later cluster multiple glass elements, noted, not yet needed.

## Alternatives considered

Material-only, no AppKit (rejected: stays opaque, the actual bug), full custom NSVisualEffectView plumbing (rejected: `glassEffect` + one opacity hook is less code and more native), dropping translucency entirely (rejected: JB asked for the opposite).
