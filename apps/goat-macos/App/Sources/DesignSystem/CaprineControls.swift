import AppKit
import Caprine
import SwiftUI

/// Presents an AppKit file picker above the window that launched it. A floating Settings window
/// otherwise obscures a plain open panel, making the picker impossible to reach.
enum GOATFileSelector {
    @MainActor
    static func present(
        _ panel: NSSavePanel,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let parent = NSApp.keyWindow {
            panel.beginSheetModal(for: parent, completionHandler: completion)
        } else {
            panel.level = .modalPanel
            panel.begin(completionHandler: completion)
        }
    }
}

/// Copy-to-clipboard with feedback: icon flips to a green checkmark for a beat, then back.
struct CopyButton: View {
    let text: String
    var compact = true
    @State private var copied = false

    var body: some View {
        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.declareTypes([.string], owner: nil)
            pb.writeObjects([text as NSString])
            withAnimation(.easeOut(duration: 0.15)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeOut(duration: 0.2)) { copied = false }
            }
        } label: {
            if compact {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? Color.green : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            } else {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? Color.green : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .buttonStyle(.plain)
        .help("Copy")
    }
}

/// A soft, feathered themed ring - a crisp thin edge plus a wide blurred glow.
struct FeatheredRing: View {
    let tint: Color
    var cornerRadius: CGFloat = 20
    var feather: CGFloat = 5

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(tint.opacity(0.9), lineWidth: 1.2)
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(tint, lineWidth: 3)
                .blur(radius: feather)
                .opacity(0.75)
        }
        .allowsHitTesting(false)
    }
}

/// Three dots that ripple as a travelling wave - each lifts and settles, staggered.
struct WaveDots: View {
    var color: Color = .white
    var dot: CGFloat = 4
    var animates = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var spacing: CGFloat { dot * 0.8 }
    private var amplitude: Double { Double(dot) * 0.7 }

    var body: some View {
        if reduceMotion || !animates {
            row { _ in 0 }
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                row { i in -amplitude * sin(t * 3.4 - Double(i) * 0.7) }
            }
        }
    }

    private func row(_ lift: @escaping (Int) -> Double) -> some View {
        HStack(spacing: spacing) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(color)
                    .frame(width: dot, height: dot)
                    .offset(y: lift(i))
            }
        }
    }
}

/// The goatie's "typing…" speech bubble - neon glass bubble art with a wave of themed dots.
struct ThinkingBubble: View {
    var tint: Color = .white
    var height: CGFloat = 30
    var animates = true

    var body: some View {
        Image("speech-bubble")
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .scaledToFit()
            .frame(height: height)
            .overlay(
                WaveDots(color: tint, dot: height * 0.13, animates: animates)
                    .offset(y: -height * 0.14)  // sit in the body, above the tail
            )
            .accessibilityLabel("Thinking")
    }
}

/// Draw the streaming marker at the final line, including a trailing blank line. Keeping it
/// in the text layout avoids a separate HStack column and leaves copied text unchanged.
struct StreamingTextRenderer: TextRenderer {
    let tint: Color
    var displayPadding: EdgeInsets { EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 6) }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout { context.draw(line) }
        guard let last = layout.last else { return }
        let bounds = last.typographicBounds.rect
        let caret = CGRect(x: bounds.maxX + 3, y: bounds.minY, width: 2.5, height: bounds.height)
        context.fill(Path(roundedRect: caret, cornerRadius: 1.25), with: .color(tint.opacity(0.85)))
    }
}

/// The 🐐💨 badge shown when the goat is really cooking (>100 tok/s).
struct SpeedBadge: View {
    var body: some View {
        Text("🐐💨").font(.caption)
    }
}

/// Press-bounce for round action buttons - squishes on press, springs back.
struct PressBounceStyle: ButtonStyle {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var animates: Bool { model.animationsEnabled && !reduceMotion }
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && animates ? 0.94 : 1)
            .animation(animates ? .easeOut(duration: 0.12) : nil, value: configuration.isPressed)
    }
}

/// The send button - gradient disc that grows and glows on hover, bounces on press,
/// and gives a little launch nudge when it fires.
struct SendButton: View {
    let enabled: Bool
    let gradient: LinearGradient
    let glow: Color
    let animates: Bool
    @Environment(AppModel.self) private var model
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // An idle composer must not schedule window layout twenty times per second.
        // Hover and press feedback remain event-driven.
        button(glowStrength: enabled ? 0.32 : 0)
    }

    private func button(glowStrength: Double) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(model.theme.isDark ? Color.black : Color.white)
                .frame(width: 30, height: 30)
                .background(gradient, in: Circle())
                .scaleEffect(hovering && enabled && animates && !reduceMotion ? 1.06 : 1)
                .shadow(color: glow.opacity(hovering ? 0.75 : glowStrength), radius: hovering ? 10 : 5)
                .animation(animates && !reduceMotion ? .easeOut(duration: 0.16) : nil, value: hovering)
        }
        .buttonStyle(PressBounceStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 && enabled }
        .help("Send (⏎)")
    }
}

/// A text field with a custom focus ring because AppKit's native ring ignores `.tint`.
private struct ThemedFieldModifier: ViewModifier {
    let tint: Color
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focused($focused)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.4)))
            .overlay {
                // Feathered ring: a crisp thin edge + a soft blurred glow of the same color.
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(
                            focused ? tint.opacity(0.9) : Color.secondary.opacity(0.35),
                            lineWidth: focused ? 1.5 : 1)
                    if focused {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(tint, lineWidth: 3)
                            .blur(radius: 4)
                            .opacity(0.75)
                    }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onTapGesture { focused = true }
            .animation(.easeOut(duration: 0.14), value: focused)
    }
}

extension View {
    func themedField(tint: Color) -> some View {
        modifier(ThemedFieldModifier(tint: tint))
    }
}

/// Shared secondary actions: neutral at rest, themed on interaction, with a visible hit target.
/// Keep primary actions prominent and document links inline; do not apply this to an entire page.
struct SecondaryChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SecondaryChipBody(configuration: configuration)
    }
}

private struct SecondaryChipBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(AppModel.self) private var model
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var tokens: Caprine { model.theme.tokens }
    private var highlighted: Bool { isEnabled && (hovering || isFocused || configuration.isPressed) }
    private var interactionColor: Color { configuration.role == .destructive ? .red : tokens.tint }

    var body: some View {
        configuration.label
            .foregroundStyle(isEnabled ? (highlighted ? interactionColor : tokens.ink) : tokens.muted)
            .padding(.horizontal, InterfaceMetrics.secondaryActionPadding)
            .frame(minWidth: InterfaceMetrics.controlHitArea, minHeight: InterfaceMetrics.controlHitArea)
            .background {
                RoundedRectangle(cornerRadius: InterfaceMetrics.secondaryActionRadius)
                    .fill(tokens.ink.opacity(contrast == .increased ? 0.10 : 0.045))
                if highlighted {
                    RoundedRectangle(cornerRadius: InterfaceMetrics.secondaryActionRadius)
                        .fill(interactionColor.opacity(configuration.isPressed ? 0.18 : 0.09))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: InterfaceMetrics.secondaryActionRadius)
                    .strokeBorder(
                        highlighted
                            ? interactionColor.opacity(0.6) : tokens.ink.opacity(contrast == .increased ? 0.4 : 0.12),
                        lineWidth: isFocused ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: InterfaceMetrics.secondaryActionRadius))
            .opacity(isEnabled ? 1 : 0.55)
            .onHover { hovering = $0 }
            .animation(
                model.animationsEnabled && !reduceMotion ? .easeOut(duration: 0.12) : nil,
                value: highlighted)
    }
}

/// A deliberately high-contrast secondary action for dismissing a sheet. Plain Cancel buttons
/// disappear too easily against GOAT's glass surfaces, especially when the primary action is blue.
struct DialogCancelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary.opacity(configuration.isPressed ? 0.95 : 0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.75)
            )
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

/// A standard escape hatch for dismissible GOAT sheets. Permission gates intentionally do not use
/// this control because they require an explicit Allow or Deny decision.
struct DialogCloseButton: View {
    let action: () -> Void
    var disabled = false
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if hovering {
                    Circle().fill(Color.primary.opacity(0.12))
                }
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(hovering ? Color.primary : Color.secondary)
            }
            .frame(width: InterfaceMetrics.controlHitArea, height: InterfaceMetrics.controlHitArea)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .onHover { hovering = $0 && !disabled }
        .help("Close (Esc)")
        .accessibilityLabel("Close")
    }
}

/// Shared visual shell for GOAT's dismissible sheets. The content owns its size and actions;
/// the shell keeps the close affordance, theme, and background consistent across every dialog.
struct GOATDialogShell<Content: View>: View {
    @Environment(AppModel.self) private var model

    let closeAction: () -> Void
    var closeDisabled = false
    var extraOpacity = 0.24
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .overlay(alignment: .topTrailing) {
                DialogCloseButton(action: closeAction, disabled: closeDisabled)
                    .padding(8)
            }
            .background(
                CaprineBackground(
                    model.theme.tokens,
                    transparency: model.windowTransparency,
                    extraOpacity: extraOpacity)
            )
            .tint(model.theme.tokens.tint)
            .goatPresentation()
    }
}
