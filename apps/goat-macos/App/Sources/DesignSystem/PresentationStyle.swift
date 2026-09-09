import SwiftUI

/// Shared window appearance, including AppKit-backed controls that consult accentColor.
struct PresentationStyle: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(ThemedFieldSelection(tint: model.theme.tokens.tint, ink: model.theme.tokens.ink))
            .tint(model.theme.tokens.tint)
            .accentColor(model.theme.tokens.tint)
            .preferredColorScheme(model.preferredColorScheme)
            .onChange(of: colorScheme, initial: true) { _, scheme in
                if model.themeID == "system" { model.systemIsDark = scheme == .dark }
            }
            .onChange(of: model.theme.isDark, initial: true) { _, _ in updateIcon() }
            .onChange(of: model.presentation.isEnabled) { _, _ in updateIcon() }
    }

    private func updateIcon() {
        AppIconManager.applyStored(
            unlocked: model.presentation.isUnlocked, playful: model.presentation.isEnabled,
            dark: model.theme.isDark)
    }
}

extension View {
    func goatPresentation() -> some View { modifier(PresentationStyle()) }
}

/// Shared control geometry for compact chrome and settings forms.
enum InterfaceMetrics {
    static let controlIcon: CGFloat = 14
    static let controlHitArea: CGFloat = 28
    static let secondaryActionPadding: CGFloat = 8
    static let secondaryActionRadius: CGFloat = 7
}

/// A bounded, theme-coloured sweep across the thinking label. Stops when inactive or hidden.
struct ThinkingLabel: View {
    let title: String
    let live: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if live && model.animationsEnabled && !reduceMotion && scenePhase == .active {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3
                label.foregroundStyle(
                    LinearGradient(
                        colors: [
                            model.theme.tokens.accent, model.theme.tokens.accent2,
                            model.theme.tokens.accent, model.theme.tokens.accent2, model.theme.tokens.accent,
                        ],
                        startPoint: UnitPoint(x: -1 + phase, y: 0.5),
                        endPoint: UnitPoint(x: 1 + phase, y: 0.5)))
            }
        } else {
            label.foregroundStyle(live ? model.theme.tokens.tint : model.theme.tokens.muted)
        }
    }

    private var label: some View {
        Text(title)
            .font(.system(size: InterfaceMetrics.controlIcon, weight: .medium))
    }
}
