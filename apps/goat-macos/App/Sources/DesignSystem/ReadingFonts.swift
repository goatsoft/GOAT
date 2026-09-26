import AppKit
import Caprine
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

/// The transcript's reading measure (#60 D3, DESIGN.md §4). Prose runs at most 68ch of the selected
/// chat font, where 1ch is the advance of "0" as in CSS, so it follows the font and its size. The
/// transcript and composer share one centred column wide enough for code and artifacts
/// (`Caprine.Code.maxWidth`) beside the assistant's masthead; prose within it keeps the measure.
@MainActor
enum ReadingMeasure {
    private static var cache: [String: CGFloat] = [:]

    static func prose(fontID: String, size: Double) -> CGFloat {
        let key = "\(fontID):\(size)"
        if let cached = cache[key] { return cached }
        let font = ReadingFonts.nsFont(fontID, size: size, role: .chat)
        let zero = ("0" as NSString).size(withAttributes: [.font: font]).width
        let measure = (zero * Caprine.Reading.characters).rounded()
        if cache.count >= 64 { cache.removeAll() }
        cache[key] = measure
        return measure
    }

    /// The transcript column: the masthead gutter plus the wider of the prose measure and code.
    static func column(fontID: String, size: Double, presentation: Bool) -> CGFloat {
        let avatar =
            presentation ? Caprine.Activity.presentationAvatarWidth : Caprine.Activity.standardAvatarWidth
        return avatar + Caprine.Activity.assistantGutter + max(prose(fontID: fontID, size: size), Caprine.Code.maxWidth)
    }
}

/// Caps its content at `maximumWidth`, taking the proposed width up to it (or the maximum when none
/// is proposed). Unlike a flexible frame it never asks its content for an ideal width, which for text
/// means laying it out on one line, so its size never depends on the content's width.
struct BoundedWidthLayout: Layout {
    var maximumWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = min(proposal.width ?? maximumWidth, maximumWidth)
        let size = child.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        return CGSize(width: width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        child.place(
            at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: min(bounds.width, maximumWidth), height: bounds.height))
    }

    /// Text baselines and other vertical guides are the content's, as through a frame.
    func explicitAlignment(
        of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
        cache: inout ()
    ) -> CGFloat? {
        guard let child = subviews.first else { return nil }
        let size = ProposedViewSize(width: min(bounds.width, maximumWidth), height: bounds.height)
        return bounds.minY + child.dimensions(in: size)[guide]
    }
}

/// Fills the offered width and places its content at the trailing edge, offering it at most a
/// fraction of that width (#60 D3: user bubbles).
struct FractionalWidthLayout: Layout {
    var fraction: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = proposal.width.map { $0 * fraction }
        let size = child.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let width = proposal.width.map { $0 * fraction }
        let size = child.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        child.place(
            at: CGPoint(x: bounds.maxX - size.width, y: bounds.minY), anchor: .topLeading,
            proposal: ProposedViewSize(width: size.width, height: size.height))
    }
}
