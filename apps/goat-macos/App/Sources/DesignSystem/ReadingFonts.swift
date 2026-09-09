import AppKit
import MarkdownUI
import SwiftUI

/// Reading preferences are independent of theme and never download or bundle fonts.
enum ReadingFontRole: String, Identifiable {
    case chat, code
    var id: String { rawValue }
    var title: String { self == .chat ? "Chat & composer" : "Code" }
    var defaultID: String { self == .chat ? "system" : "monospaced" }
    var defaultSize: Double { self == .chat ? 14 : 13 }
    var sizeRange: ClosedRange<Double> { self == .chat ? 11...28 : 10...24 }

    func normalizedSize(_ size: Double) -> Double {
        size.isFinite ? min(sizeRange.upperBound, max(sizeRange.lowerBound, size.rounded())) : defaultSize
    }
}

@MainActor
enum ReadingFonts {
    struct Choice: Identifiable {
        let id: String
        let name: String
    }

    static func requestedID(selection: String, themeFont: String?, role: ReadingFontRole) -> String {
        guard selection == "theme" else { return selection }
        guard let themeFont else { return role.defaultID }
        return ["system", "rounded", "serif", "monospaced"].contains(themeFont) ? themeFont : "font:" + themeFont
    }

    static func builtins(for role: ReadingFontRole) -> [Choice] {
        if role == .code { return [Choice(id: "monospaced", name: "System Mono")] }
        return [
            Choice(id: "system", name: "System"), Choice(id: "rounded", name: "System Rounded"),
            Choice(id: "serif", name: "System Serif"), Choice(id: "monospaced", name: "System Mono"),
        ]
    }

    static func installed(for role: ReadingFontRole) -> [Choice] {
        NSFontManager.shared.availableFonts.compactMap { name in
            guard !name.hasPrefix("."), let font = NSFont(name: name, size: 14),
                role != .code || font.isFixedPitch
            else { return nil }
            return Choice(id: "font:" + name, name: font.displayName ?? name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func isAvailable(_ id: String, for role: ReadingFontRole) -> Bool {
        if builtins(for: role).contains(where: { $0.id == id }) { return true }
        guard id.hasPrefix("font:"), let font = NSFont(name: String(id.dropFirst(5)), size: 14) else { return false }
        return role != .code || font.isFixedPitch
    }

    static func name(_ id: String, for role: ReadingFontRole) -> String {
        if let choice = builtins(for: role).first(where: { $0.id == id }) { return choice.name }
        guard isAvailable(id, for: role), let font = NSFont(name: String(id.dropFirst(5)), size: 14) else {
            return role == .chat ? "System (saved font unavailable)" : "System Mono (saved font unavailable)"
        }
        return font.displayName ?? font.fontName
    }

    static func nsFont(_ id: String, size: Double, role: ReadingFontRole) -> NSFont {
        let size = role.normalizedSize(size)
        let resolved = isAvailable(id, for: role) ? id : role.defaultID
        if resolved.hasPrefix("font:"), let font = NSFont(name: String(resolved.dropFirst(5)), size: size) {
            return font
        }
        if resolved == "monospaced" { return .monospacedSystemFont(ofSize: size, weight: .regular) }
        let base = NSFont.systemFont(ofSize: size)
        if resolved == "system" { return base }
        let design: NSFontDescriptor.SystemDesign =
            resolved == "serif" ? .serif : resolved == "rounded" ? .rounded : .default
        return base.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }

    static func family(_ id: String, role: ReadingFontRole) -> FontProperties.Family {
        let resolved = isAvailable(id, for: role) ? id : role.defaultID
        switch resolved {
        case "system": return .system()
        case "rounded": return .system(.rounded)
        case "serif": return .system(.serif)
        case "monospaced": return .system(.monospaced)
        default: return .custom(String(resolved.dropFirst(5)))
        }
    }
}
