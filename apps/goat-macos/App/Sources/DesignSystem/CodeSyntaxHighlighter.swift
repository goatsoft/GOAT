import AppKit
import Foundation
import HighlightKit
import SwiftUI

/// Pure-Swift syntax highlighting on background tasks without JavaScriptCore or HTML round-tripping.
actor CodeSyntaxHighlighter {
    static let shared = CodeSyntaxHighlighter()

    /// Bounded per-source count of preparations started; lets tests prove a warm consumer skipped the work.
    private var preparationCounts: [Int: Int] = [:]

    func preparations(of source: String) -> Int { preparationCounts[source.hashValue, default: 0] }

    func render(_ source: String, language: String?, dark: Bool) async throws -> AttributedString {
        try Task.checkCancellation()
        if preparationCounts.count >= 512 { preparationCounts.removeAll(keepingCapacity: true) }
        preparationCounts[source.hashValue, default: 0] += 1
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

    private func makeKey(code: String, language: String?, dark: Bool) -> String {
        "\(code.hashValue):\(code.utf8.count):\(language ?? ""):\(dark)"
    }

    func peek(code: String, language: String?, dark: Bool) -> Entry? {
        let k = makeKey(code: code, language: language, dark: dark) as NSString
        guard let box = cache.object(forKey: k), box.code == code else { return nil }
        return box.entry
    }

    func set(code: String, language: String?, dark: Bool, text: AttributedString, lineCount: Int) {
        let k = makeKey(code: code, language: language, dark: dark) as NSString
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
    }

    /// First-frame text for the scheme SwiftUI will actually render (the app can prefer a scheme that
    /// differs from the system appearance). A resident cache entry wins over plain text; NSCache may
    /// have evicted it, in which case the task prepares it again.
    static func displayText(
        code: String,
        language: String?,
        dark: Bool,
        isStreaming: Bool,
        rendered: AttributedString?,
        renderedKey: CacheKey?
    ) -> AttributedString {
        let key = CacheKey(code: code, language: language, dark: dark)
        if renderedKey != key, !isStreaming,
            let cached = HighlightCache.shared.peek(code: code, language: language, dark: dark)
        {
            return cached.text
        }
        return resolveText(code: code, language: language, dark: dark, rendered: rendered, renderedKey: renderedKey)
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
        Self.displayText(
            code: code,
            language: language,
            dark: colorScheme == .dark,
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
        let key = CacheKey(code: code, language: language, dark: dark)
        let taskId = TaskKey(key: key, isStreaming: isStreaming)
        Text(currentText)
            .task(id: taskId) {
                if !isStreaming, let cached = HighlightCache.shared.peek(code: code, language: language, dark: dark) {
                    rendered = cached.text
                    renderedKey = key
                    return
                }
                if !isStreaming, renderedKey == key, let currentRendered = rendered {
                    let lines = HighlightCache.shared.lineCount(for: code)
                    HighlightCache.shared.set(
                        code: code, language: language, dark: dark, text: currentRendered, lineCount: lines)
                    return
                }
                do {
                    let result = try await CodeSyntaxHighlighter.shared.render(
                        code, language: language, dark: dark)
                    try Task.checkCancellation()
                    if !isStreaming {
                        let lines = HighlightCache.shared.lineCount(for: code)
                        HighlightCache.shared.set(
                            code: code, language: language, dark: dark, text: result, lineCount: lines)
                    }
                    rendered = result
                    renderedKey = key
                } catch {
                    // Keep current, selectable source when preparation fails or is superseded.
                }
            }
    }
}
