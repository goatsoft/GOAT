import Foundation
import HighlightSwift
import SwiftUI

/// Highlight SFC sections without flattening TypeScript scripts into HTML or JavaScript.
/// Source text is preserved exactly, including whitespace between independently coloured sections.
actor VueSyntaxHighlighter {
    static let shared = VueSyntaxHighlighter()
    private let highlight = Highlight()
    static let maximumBytes = 256 * 1_024
    private static let maximumSections = 128

    struct Section: Equatable, Sendable {
        let text: String
        let language: String
    }

    static func sections(in source: String) -> [Section] {
        guard source.utf8.count <= maximumBytes,
            let opening = try? NSRegularExpression(
                pattern: #"<!--[\s\S]*?(?:-->|$)|<(script|style)\b(?:"[^"]*"|'[^']*'|[^'">])*>"#,
                options: .caseInsensitive)
        else { return [Section(text: source, language: "plaintext")] }
        let input = source as NSString
        var sections: [Section] = []
        var cursor = 0
        var markupStart = 0
        while cursor < input.length,
            let match = opening.firstMatch(in: source, range: NSRange(cursor..<input.length))
        {
            cursor = NSMaxRange(match.range)
            // A comment is markup even when it contains example script/style tags.
            guard match.range(at: 1).location != NSNotFound else { continue }
            let attributes = input.substring(with: match.range)
            guard !attributes.hasSuffix("/>") else { continue }
            guard sections.count < maximumSections,
                let closing = try? NSRegularExpression(
                    pattern: "</" + input.substring(with: match.range(at: 1)) + #"\s*>"#,
                    options: .caseInsensitive)
            else { return [Section(text: source, language: "xml")] }
            sections.append(Section(text: input.substring(with: NSRange(markupStart..<cursor)), language: "xml"))
            let end = closing.firstMatch(in: source, range: NSRange(cursor..<input.length))
            let bodyEnd = end?.range.location ?? input.length
            let tag = input.substring(with: match.range(at: 1)).lowercased()
            sections.append(
                Section(
                    text: input.substring(with: NSRange(cursor..<bodyEnd)),
                    language: sectionLanguage(tag: tag, attributes: attributes)))
            markupStart = bodyEnd
            cursor = end.map { NSMaxRange($0.range) } ?? input.length
        }
        if markupStart < input.length {
            sections.append(Section(text: input.substring(from: markupStart), language: "xml"))
        }
        return sections
    }

    private static func sectionLanguage(tag: String, attributes: String) -> String {
        let pattern = #"\s+lang\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let input = attributes as NSString
        let match = regex?.firstMatch(in: attributes, range: NSRange(0..<input.length))
        let value = (1...3).compactMap { index -> String? in
            guard let range = match?.range(at: index), range.location != NSNotFound else { return nil }
            return input.substring(with: range).lowercased()
        }.first
        switch (tag, value) {
        case ("script", nil), ("script", "js"), ("script", "javascript"), ("script", "jsx"): return "javascript"
        case ("script", "ts"), ("script", "typescript"), ("script", "tsx"): return "typescript"
        case ("script", "json"): return "json"
        case ("style", nil), ("style", "css"): return "css"
        case ("style", "scss"): return "scss"
        case ("style", "less"): return "less"
        default: return "plaintext"
        }
    }

    func render(_ source: String, dark: Bool) async throws -> AttributedString {
        guard source.utf8.count <= Self.maximumBytes else { return AttributedString(source) }
        var output = AttributedString()
        for section in Self.sections(in: source) {
            try Task.checkCancellation()
            let text = section.text
            let core = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !core.isEmpty, section.language != "plaintext",
                let range = text.range(of: core),
                let result = try? await highlight.attributedText(
                    core, language: section.language, colors: dark ? .dark(.xcode) : .light(.xcode)),
                String(result.characters) == core
            else {
                output.append(AttributedString(text))
                continue
            }
            // HighlightSwift trims boundaries. Restore them explicitly, and reject any conversion
            // that changes the source rather than risk losing code or misaligning line numbers.
            output.append(AttributedString(String(text[..<range.lowerBound])))
            output.append(result)
            output.append(AttributedString(String(text[range.upperBound...])))
        }
        try Task.checkCancellation()
        return output
    }
}

struct VueCodeText: View {
    let code: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var rendered: AttributedString?
    @State private var renderedKey: Key?

    private struct Key: Equatable {
        let code: String
        let dark: Bool
    }

    var body: some View {
        let key = Key(code: code, dark: colorScheme == .dark)
        Text(renderedKey == key ? (rendered ?? AttributedString(code)) : AttributedString(code))
            .task(id: key) {
                // Coalesce streaming updates; show current plain source while preparation is pending.
                do {
                    try await Task.sleep(for: .milliseconds(120))
                    let result = try await VueSyntaxHighlighter.shared.render(code, dark: key.dark)
                    try Task.checkCancellation()
                    rendered = result
                    renderedKey = key
                } catch {
                    // Keep the current plain source if highlighting fails or is superseded.
                }
            }
    }
}
