import AppKit
import SwiftUI

/// The Dock icon the user has chosen. macOS has no alternate-icon API like iOS, so switching
/// is done by swapping `NSApp.applicationIconImage` at runtime.
enum AppIcon: String, CaseIterable, Identifiable {
    case system
    case light
    case dark
    case original
    case v

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "System"
        case .original: "The GOAT"
        case .v: "1337"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    /// Asset-catalog imageset used for the settings thumbnail and (for the variant) the live icon.
    var assetName: String { "AppIconGlyph" + rawValue.capitalized }
}

/// Applies and remembers the chosen Dock icon. The choice persists in UserDefaults and is
/// re-applied on launch.
@MainActor
enum AppIconManager {
    private static let key = "appIcon"

    static var current: AppIcon {
        AppIcon(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    static func available(unlocked: Bool, playful: Bool) -> [AppIcon] {
        AppIcon.allCases.filter { (unlocked && playful) || ($0 != .original && $0 != .v) }
    }

    static func resolved(_ icon: AppIcon, unlocked: Bool, playful: Bool, dark: Bool) -> AppIcon {
        if icon == .system || ((!unlocked || !playful) && (icon == .original || icon == .v)) {
            return dark ? .dark : .light
        }
        return icon
    }

    static func apply(_ icon: AppIcon, unlocked: Bool, playful: Bool, dark: Bool) {
        let allowed = available(unlocked: unlocked, playful: playful).contains(icon) ? icon : .system
        UserDefaults.standard.set(allowed.rawValue, forKey: key)
        let effective = resolved(allowed, unlocked: unlocked, playful: playful, dark: dark)
        // Assign Dark explicitly too. Clearing an override is not an appearance selection
        // and can leave AppKit/Dock displaying the previously cached light icon.
        NSApp.applicationIconImage = NSImage(named: effective.assetName)
    }

    static func applyStored(unlocked: Bool, playful: Bool, dark: Bool) {
        apply(current, unlocked: unlocked, playful: playful, dark: dark)
    }
}
