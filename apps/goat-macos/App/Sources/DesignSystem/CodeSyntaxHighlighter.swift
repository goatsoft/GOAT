import AppKit
import Foundation
import HighlightKit
import SwiftUI

/// Pure-Swift syntax highlighting on background tasks without JavaScriptCore or HTML round-tripping.
actor CodeSyntaxHighlighter {
    static let shared = CodeSyntaxHighlighter()

    func render(_ source: String, language: String?, dark: Bool) async throws -> AttributedString {
        try Task.checkCancellation()
        guard source.utf8.count <= HighlightedCodeView.maximumHighlightedBytes else {
            return AttributedString(source)
        }
        let core = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty, let range = source.range(of: core) else { return AttributedString(source) }

        let theme: HighlightTheme = dark ? .xcodeDark : .xcodeLight
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
    final class EntryBox: @unchecked Sendable {
        let entry: Entry
        init(_ entry: Entry) { self.entry = entry }
    }

    init() {
        cache.countLimit = 200
    }

    private func makeKey(code: String, language: String?, dark: Bool) -> String {
        "\(code.hashValue):\(code.utf8.count):\(language ?? ""):\(dark)"
    }

    func peek(code: String, language: String?, dark: Bool) -> Entry? {
        let k = makeKey(code: code, language: language, dark: dark) as NSString
        return cache.object(forKey: k)?.entry
    }

    func set(code: String, language: String?, dark: Bool, text: AttributedString, lineCount: Int) {
        let k = makeKey(code: code, language: language, dark: dark) as NSString
        cache.setObject(EntryBox(Entry(text: text, lineCount: lineCount)), forKey: k)
    }

    func lineCount(for code: String) -> Int {
        if let entry = peek(code: code, language: nil, dark: true) ?? peek(code: code, language: nil, dark: false) {
            return entry.lineCount
        }
        return max(1, code.reduce(1) { $0 + ($1 == "\n" ? 1 : 0) } - (code.hasSuffix("\n") ? 1 : 0))
    }
}

struct PreparedCodeText: View {
    let code: String
    let language: String?
    var isStreaming: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var rendered: AttributedString?
    @State private var renderedKey: CacheKey?

    struct CacheKey: Equatable {
        let code: String
        let language: String?
        let dark: Bool
    }

    init(code: String, language: String?, isStreaming: Bool = false) {
        self.code = code
        self.language = language
        self.isStreaming = isStreaming

        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if let cached = HighlightCache.shared.peek(code: code, language: language, dark: isDark) {
            _rendered = State(initialValue: cached.text)
            _renderedKey = State(initialValue: CacheKey(code: code, language: language, dark: isDark))
        }
    }

    static func resolveText(
        code: String,
        language: String?,
        dark: Bool,
        rendered: AttributedString?,
        renderedKey: CacheKey?
    ) -> AttributedString {
        let key = CacheKey(code: code, language: language, dark: dark)
        if renderedKey == key, let rendered {
            return rendered
        }
        if let rendered, let prevKey = renderedKey,
            prevKey.language == language,
            prevKey.dark == dark,
            code.hasPrefix(prevKey.code)
        {
            var combined = rendered
            let suffix = code.dropFirst(prevKey.code.count)
            combined.append(AttributedString(suffix))
            return combined
        }
        return AttributedString(code)
    }

    private var currentText: AttributedString {
        Self.resolveText(
            code: code,
            language: language,
            dark: colorScheme == .dark,
            rendered: rendered,
            renderedKey: renderedKey
        )
    }

    var body: some View {
        let dark = colorScheme == .dark
        let key = CacheKey(code: code, language: language, dark: dark)
        Text(currentText)
            .task(id: key) {
                if let cached = HighlightCache.shared.peek(code: code, language: language, dark: dark) {
                    rendered = cached.text
                    renderedKey = key
                    return
                }
                if isStreaming {
                    // Debounce syntax highlighting while streaming to coalesce rapid token arrivals
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled else { return }
                }
                do {
                    let result = try await CodeSyntaxHighlighter.shared.render(
                        code, language: language, dark: key.dark)
                    try Task.checkCancellation()
                    let lines = max(1, code.reduce(1) { $0 + ($1 == "\n" ? 1 : 0) } - (code.hasSuffix("\n") ? 1 : 0))
                    HighlightCache.shared.set(code: code, language: language, dark: dark, text: result, lineCount: lines)
                    rendered = result
                    renderedKey = key
                } catch {
                    // Keep current, selectable source when preparation fails or is superseded.
                }
            }
    }
}
