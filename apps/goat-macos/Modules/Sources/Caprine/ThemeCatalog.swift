import AppKit
import SwiftUI

/// A theme as data: the **GOAT Theme Format** (GTF, docs/THEMES.md). Community themes are folders
/// under ~/.goat/config/themes/<id>/ (ADR-0009, ADR-0022). The metadata fields (schema/author/
/// description/preview) are optional so older and hand-written themes still decode.
public struct ThemeFonts: Codable, Sendable, Equatable {
    public var chat: String?
    public var code: String?
    public init(chat: String? = nil, code: String? = nil) {
        self.chat = chat
        self.code = code
    }
}

public struct ThemeSpec: Codable, Identifiable, Sendable, Equatable {
    public enum Appearance: String, Codable, Sendable { case system, light, dark }

    /// Current GOAT Theme Format version.
    public static let schemaVersion = 1

    public var id: String
    public var name: String
    public var appearance: Appearance
    public var mono: Bool
    public var fonts: ThemeFonts?

    // Colors as "#RRGGBB" strings so a hand-written JSON theme is legible.
    public var bg, surface, ink, muted, accent, accent2, glow, selection, tint: String
    public var washOpacity, bgOpacity, intensity: Double

    // GTF metadata (optional; absent in legacy/hand-written themes).
    public var schema: Int?
    public var author: String?
    public var description: String?
    /// Preview image filename relative to the theme's folder (e.g. "preview.png").
    public var preview: String?

    public init(
        id: String, name: String, appearance: Appearance, mono: Bool = false,
        bg: String, surface: String, ink: String, muted: String,
        accent: String, accent2: String, glow: String, selection: String, tint: String,
        washOpacity: Double, bgOpacity: Double, intensity: Double = 1.0,
        schema: Int? = nil, author: String? = nil, description: String? = nil, preview: String? = nil,
        fonts: ThemeFonts? = nil
    ) {
        self.id = id
        self.name = name
        self.appearance = appearance
        self.mono = mono
        self.fonts = fonts
        self.bg = bg
        self.surface = surface
        self.ink = ink
        self.muted = muted
        self.accent = accent
        self.accent2 = accent2
        self.glow = glow
        self.selection = selection
        self.tint = tint
        self.washOpacity = washOpacity
        self.bgOpacity = bgOpacity
        self.intensity = intensity
        self.schema = schema
        self.author = author
        self.description = description
        self.preview = preview
    }

    public var displayName: String { name }
    public var isMono: Bool { mono }

    public var colorScheme: ColorScheme? {
        switch appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// System resolves at runtime; others are declared.
    @MainActor public var isDark: Bool {
        switch appearance {
        case .dark: true
        case .light: false
        case .system: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    @MainActor public var tokens: Caprine {
        // System follows the OS by adopting a real GOAT theme: Light in light mode, Midnight in dark
        // (ADR-0022), not raw macOS window colors, so the app looks like itself either way.
        if appearance == .system {
            return (isDark ? ThemeCatalog.midnight : ThemeCatalog.light).tokens
        }
        return Caprine(
            bg: Color(hexString: bg), surface: Color(hexString: surface),
            ink: Color(hexString: ink), muted: Color(hexString: muted),
            accent: Color(hexString: accent), accent2: Color(hexString: accent2),
            glow: Color(hexString: glow), selection: Color(hexString: selection),
            tint: Color(hexString: tint),
            washOpacity: washOpacity, bgOpacity: bgOpacity, intensity: intensity,
            userBubble: Color(hexString: accent).opacity(0.12)
        )
    }
}

public enum ThemeCatalog {
    public static let builtins: [ThemeSpec] = [
        ThemeSpec(
            id: "system", name: "System", appearance: .system,
            bg: "#000000", surface: "#111111", ink: "#FFFFFF", muted: "#888888",
            accent: "#3AA0FF", accent2: "#A855F7", glow: "#7A5CFF",
            selection: "#3AA0FF", tint: "#3AA0FF",
            washOpacity: 0.10, bgOpacity: 0.65),
        ThemeSpec(
            id: "light", name: "Light", appearance: .light,
            bg: "#F5F6FA", surface: "#FFFFFF", ink: "#1A1C26", muted: "#646B7E",
            accent: "#2563C8", accent2: "#7542CB", glow: "#7542CB",
            selection: "#2563C8", tint: "#2563C8",
            washOpacity: 0.08, bgOpacity: 0.65),
        ThemeSpec(
            id: "pasture", name: "Pasture", appearance: .light,
            bg: "#F6F3EC", surface: "#FFFFFF", ink: "#2A2419", muted: "#6F634E",
            accent: "#496F2B", accent2: "#83582F", glow: "#496F2B",
            selection: "#496F2B", tint: "#496F2B",
            washOpacity: 0.10, bgOpacity: 0.70),
        ThemeSpec(
            id: "midnight", name: "Midnight", appearance: .dark,
            bg: "#0A0B14", surface: "#151726", ink: "#E9ECF5", muted: "#8E95A8",
            accent: "#3AA0FF", accent2: "#B44BFF", glow: "#7A5CFF",
            selection: "#3AA0FF", tint: "#3AA0FF",
            washOpacity: 0.14, bgOpacity: 0.65),
        ThemeSpec(
            id: "leet", name: "1337", appearance: .dark, mono: true,
            bg: "#04050C", surface: "#0A0C1C", ink: "#E6EEFF", muted: "#7583C9",
            accent: "#00B7FF", accent2: "#D42BFF", glow: "#A02BFF",
            selection: "#8324C9", tint: "#B96AFF",
            washOpacity: 0.34, bgOpacity: 0.60, intensity: 1.7),
    ]

    public static var light: ThemeSpec { builtins.first { $0.id == "light" }! }
    public static var midnight: ThemeSpec { builtins.first { $0.id == "midnight" }! }
    public static var builtinIDs: Set<String> { Set(builtins.map(\.id)) }
    public static func isBuiltin(_ id: String) -> Bool { builtinIDs.contains(id) }

    /// Built-ins (read-only) first, then the user's themes. A user theme whose id collides with a
    /// built-in is dropped: built-ins can't be overridden (ADR-0022); to change one, duplicate it.
    public static func all(userThemes: [ThemeSpec]) -> [ThemeSpec] {
        builtins + userThemes.filter { !builtinIDs.contains($0.id) }
    }

    public static func spec(id: String, userThemes: [ThemeSpec]) -> ThemeSpec {
        all(userThemes: userThemes).first { $0.id == id } ?? builtins[0]
    }

    /// A single built-in's JSON: the reference community authors start from (docs/THEMES.md).
    public static func json(for spec: ThemeSpec) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(spec), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

extension Color {
    /// Parse "#RRGGBB" (or "RRGGBB"); falls back to gray on malformed input.
    public init(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            self = .gray
            return
        }
        self.init(hex: v)
    }
}
