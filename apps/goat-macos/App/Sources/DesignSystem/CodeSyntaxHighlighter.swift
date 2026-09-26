import AppKit
import Caprine
import Foundation
import HighlightKit
import OKLabColorPicker
import SwiftUI

/// Syntax colours derived from the active Caprine theme (#60 A5): keywords take the accent, strings
/// the second accent, numbers and literals the glow, comments the muted ink, types and titles the tint,
/// and plain code keeps the environment's ink. Each colour is moved toward the theme's ink until it
/// reaches 4.5:1 contrast on the theme background, using the shared WCAG utilities (ADR-0098). That
/// guarantees AA-readable code only when the ink itself reaches 4.5:1; with a lower-contrast custom ink
/// the colour ends at the ink, which is as readable as the theme's own text.
///
/// The stored colours are everything that changes highlighted output, so equal palettes render
/// identically and the highlight cache keys on them.
struct SyntaxPalette: Hashable, Sendable {
    let keyword: UInt32
    let string: UInt32
    let number: UInt32
    let comment: UInt32
    let type: UInt32

    static let minimumContrast = 4.5

    init(theme: ThemeSpec) {
        // The background is converted once per palette, not inside the mixing loop.
        let background = Self.value(Self.rgb(theme.bg) ?? 0x000000)
        let ink = Self.rgb(theme.ink) ?? (background.relativeLuminance < 0.5 ? 0xFFFFFF : 0x000000)
        func readable(_ hex: String) -> UInt32 {
            Self.readable(Self.rgb(hex) ?? ink, on: background, toward: ink)
        }
        keyword = readable(theme.accent)
        string = readable(theme.accent2)
        number = readable(theme.glow)
        comment = readable(theme.muted)
        type = readable(theme.tint)
    }

    /// A deterministic identity for cache keys.
    var key: String {
        [keyword, string, number, comment, type].map { String($0, radix: 16) }.joined(separator: ".")
    }

    var highlightTheme: HighlightTheme {
        let keyword = ScopeStyle(color: Self.color(self.keyword))
        let string = ScopeStyle(color: Self.color(self.string))
        let number = ScopeStyle(color: Self.color(self.number))
        let comment = ScopeStyle(color: Self.color(self.comment))
        let type = ScopeStyle(color: Self.color(self.type))
        return HighlightTheme(
            foregroundColor: .textColor, backgroundColor: .clear,
            styles: [
                .keyword: keyword, .doctag: keyword, .templateTag: keyword, .templateVariable: keyword,
                .variableLanguage: keyword, .selectorTag: keyword, .tag: keyword,
                .section: ScopeStyle(color: Self.color(self.keyword), bold: true),
                .type: type, .builtIn: type, .title: type, .titleClass: type, .titleClassInherited: type,
                .titleFunction: type, .attr: type, .attribute: type, .name: type, .selectorClass: type,
                .selectorId: type, .selectorAttr: type, .selectorPseudo: type,
                .string: string, .regexp: string, .metaString: string, .charEscape: string, .link: string,
                .number: number, .literal: number, .symbol: number, .variableConstant: number, .bullet: number,
                .comment: comment, .code: comment, .formula: comment, .quote: comment, .meta: comment,
                .metaPrompt: comment,
                .addition: ScopeStyle(color: NSColor(Caprine.Semantic.success)),
                .deletion: ScopeStyle(color: NSColor(Caprine.Semantic.danger)),
                .emphasis: ScopeStyle(italic: true), .strong: ScopeStyle(bold: true),
            ])
    }

    static func rgb(_ hex: String) -> UInt32? {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6 else { return nil }
        return UInt32(digits, radix: 16)
    }

    static func color(_ rgb: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    /// An 8-bit sRGB colour as the shared colour value, for its WCAG utilities.
    static func value(_ rgb: UInt32) -> OKLabColorValue {
        OKLabColorValue.from(
            srgbRed: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255)
    }

    /// WCAG 2.1 contrast ratio of two sRGB colours.
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        value(a).contrastRatio(with: value(b))
    }

    /// `rgb`, or the least mix of it toward `ink` that reaches the minimum contrast on `background`;
    /// `ink` itself when no mix does.
    static func readable(_ rgb: UInt32, on background: OKLabColorValue, toward ink: UInt32) -> UInt32 {
        var mixed = rgb
        for step in 1...10 where value(mixed).contrastRatio(with: background) < minimumContrast {
            let t = Double(step) / 10
            func blend(_ shift: UInt32) -> UInt32 {
                let from = Double((rgb >> shift) & 0xFF)
                let to = Double((ink >> shift) & 0xFF)
                return UInt32((from + (to - from) * t).rounded()) << shift
            }
            mixed = blend(16) | blend(8) | blend(0)
        }
        return mixed
    }
}

extension EnvironmentValues {
    /// The active theme's syntax palette; nil outside a themed window, where code keeps the light or
    /// dark Xcode palette.
    @Entry var syntaxPalette: SyntaxPalette?
}

/// Pure-Swift syntax highlighting on background tasks without JavaScriptCore or HTML round-tripping.
actor CodeSyntaxHighlighter {
    static let shared = CodeSyntaxHighlighter()

    /// Bounded per-source count of preparations started; lets tests prove a warm consumer skipped the work.
    private var preparationCounts: [Int: Int] = [:]
    private var themes: [SyntaxPalette: HighlightTheme] = [:]

    func preparations(of source: String) -> Int { preparationCounts[source.hashValue, default: 0] }

    func render(_ source: String, language: String?, dark: Bool, palette: SyntaxPalette? = nil) async throws
        -> AttributedString
    {
        try Task.checkCancellation()
        if preparationCounts.count >= 512 { preparationCounts.removeAll(keepingCapacity: true) }
        preparationCounts[source.hashValue, default: 0] += 1
        guard source.utf8.count <= HighlightedCodeView.maximumHighlightedBytes else {
            return AttributedString(source)
        }
        let core = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty, let range = source.range(of: core) else { return AttributedString(source) }

        let theme = self.theme(palette: palette, dark: dark)
        let alias = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let result: HighlightResult
        if let alias, !alias.isEmpty, !["text", "plain", "plaintext"].contains(alias) {
            result = Highlighter.shared.highlight(core, as: alias)
        } else {
            result = await Highlighter.shared.highlightAuto(core)
        }

        try Task.checkCancellation()

        let ns = NSMutableAttributedString(string: core)
        let fullLength = (core as NSString).length
        for token in result.tokens {
            guard let style = theme.style(for: token) else { continue }
            guard token.range.location + token.range.length <= fullLength else { continue }
            if let color = style.color {
                ns.addAttribute(.foregroundColor, value: color, range: token.range)
            }
        }

        let colored = AttributedString(ns)
        guard String(colored.characters) == core else { return AttributedString(source) }

        var output = AttributedString(String(source[..<range.lowerBound]))
        output.append(colored)
        output.append(AttributedString(String(source[range.upperBound...])))
        return output
    }

    /// The theme for `palette`, built once per palette; without one, Xcode's light or dark theme.
    func theme(palette: SyntaxPalette?, dark: Bool) -> HighlightTheme {
        guard let palette else { return dark ? .xcodeDark : .xcodeLight }
        if let theme = themes[palette] { return theme }
        if themes.count >= 16 { themes.removeAll(keepingCapacity: true) }
        let theme = palette.highlightTheme
        themes[palette] = theme
        return theme
    }
}

/// Bounded synchronous cache for highlighted code so blocks render highlighted on frame 0 without popping.
@MainActor
final class HighlightCache {
    static let shared = HighlightCache()

    struct Entry: Sendable {
        let text: AttributedString
        let lineCount: Int
    }

    private let cache = NSCache<NSString, EntryBox>()
    private let lineCounts = NSCache<NSString, NSNumber>()

    /// Keeps the exact source so a hash collision can never return another block's highlighting.
    final class EntryBox: @unchecked Sendable {
        let code: String
        let entry: Entry
        init(code: String, entry: Entry) {
            self.code = code
            self.entry = entry
        }
    }

    init() {
        cache.countLimit = 200
        lineCounts.countLimit = 500
    }

    /// The palette (or, without one, the scheme) is part of the key: a theme change never serves
    /// another theme's colours.
    private func makeKey(code: String, language: String?, dark: Bool, palette: SyntaxPalette?) -> String {
        "\(code.hashValue):\(code.utf8.count):\(language ?? ""):\(palette?.key ?? (dark ? "dark" : "light"))"
    }

    func peek(code: String, language: String?, dark: Bool, palette: SyntaxPalette? = nil) -> Entry? {
        let k = makeKey(code: code, language: language, dark: dark, palette: palette) as NSString
        guard let box = cache.object(forKey: k), box.code == code else { return nil }
        return box.entry
    }

    func set(
        code: String, language: String?, dark: Bool, palette: SyntaxPalette? = nil, text: AttributedString,
        lineCount: Int
    ) {
        let k = makeKey(code: code, language: language, dark: dark, palette: palette) as NSString
        cache.setObject(EntryBox(code: code, entry: Entry(text: text, lineCount: lineCount)), forKey: k)
    }

    func lineCount(for code: String) -> Int {
        let key = code as NSString
        if let cached = lineCounts.object(forKey: key) {
            return cached.intValue
        }
        var count = 1
        for byte in code.utf8 {
            if byte == 0x0A { count += 1 }
        }
        if code.hasSuffix("\n") { count = max(1, count - 1) }
        lineCounts.setObject(NSNumber(value: count), forKey: key)
        return count
    }

    func removeAll() {
        cache.removeAllObjects()
        lineCounts.removeAllObjects()
    }
}

struct PreparedCodeText: View {
    let code: String
    let language: String?
    var isStreaming: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.syntaxPalette) private var palette
    @State private var rendered: AttributedString?
    @State private var renderedKey: CacheKey?

    struct CacheKey: Equatable {
        let code: String
        let language: String?
        let dark: Bool
        var palette: SyntaxPalette? = nil
    }

    init(code: String, language: String?, isStreaming: Bool = false) {
        self.code = code
        self.language = language
        self.isStreaming = isStreaming
    }

    /// First-frame text for the scheme and palette SwiftUI will actually render (the app can prefer a
    /// scheme that differs from the system appearance). A resident cache entry wins over plain text;
    /// NSCache may have evicted it, in which case the task prepares it again.
    static func displayText(
        code: String,
        language: String?,
        dark: Bool,
        palette: SyntaxPalette? = nil,
        isStreaming: Bool,
        rendered: AttributedString?,
        renderedKey: CacheKey?
    ) -> AttributedString {
        let key = CacheKey(code: code, language: language, dark: dark, palette: palette)
        if renderedKey != key, !isStreaming,
            let cached = HighlightCache.shared.peek(code: code, language: language, dark: dark, palette: palette)
        {
            return cached.text
        }
        return resolveText(
            code: code, language: language, dark: dark, palette: palette, rendered: rendered,
            renderedKey: renderedKey)
    }

    static func resolveText(
        code: String,
        language: String?,
        dark: Bool,
        palette: SyntaxPalette? = nil,
        rendered: AttributedString?,
        renderedKey: CacheKey?
    ) -> AttributedString {
        let key = CacheKey(code: code, language: language, dark: dark, palette: palette)
        if renderedKey == key, let rendered {
            return rendered
        }
        guard let rendered, let prevKey = renderedKey, prevKey.language == language else {
            return AttributedString(code)
        }
        // A theme or scheme change keeps the previous colours until the new ones are ready, rather
        // than flashing plain text.
        if prevKey.code == code { return rendered }
        if prevKey.dark == dark, prevKey.palette == palette, code.hasPrefix(prevKey.code) {
            var combined = rendered
            let suffix = code.dropFirst(prevKey.code.count)
            combined.append(AttributedString(suffix))
            return combined
        }
        return AttributedString(code)
    }

    private var currentText: AttributedString {
        Self.displayText(
            code: code,
            language: language,
            dark: colorScheme == .dark,
            palette: palette,
            isStreaming: isStreaming,
            rendered: rendered,
            renderedKey: renderedKey
        )
    }

    struct TaskKey: Equatable {
        let key: CacheKey
        let isStreaming: Bool
    }

    var body: some View {
        let dark = colorScheme == .dark
        let palette = self.palette
        let key = CacheKey(code: code, language: language, dark: dark, palette: palette)
        let taskId = TaskKey(key: key, isStreaming: isStreaming)
        Text(currentText)
            .task(id: taskId) {
                let cache = HighlightCache.shared
                if !isStreaming, let cached = cache.peek(code: code, language: language, dark: dark, palette: palette) {
                    rendered = cached.text
                    renderedKey = key
                    return
                }
                if !isStreaming, renderedKey == key, let currentRendered = rendered {
                    let lines = cache.lineCount(for: code)
                    cache.set(
                        code: code, language: language, dark: dark, palette: palette, text: currentRendered,
                        lineCount: lines)
                    return
                }
                do {
                    let result = try await CodeSyntaxHighlighter.shared.render(
                        code, language: language, dark: dark, palette: palette)
                    try Task.checkCancellation()
                    if !isStreaming {
                        let lines = cache.lineCount(for: code)
                        cache.set(
                            code: code, language: language, dark: dark, palette: palette, text: result,
                            lineCount: lines)
                    }
                    rendered = result
                    renderedKey = key
                } catch {
                    // Keep current, selectable source when preparation fails or is superseded.
                }
            }
    }
}
