import Foundation
import HighlightKit
import SwiftUI

/// HighlightKit provides pure-Swift syntax highlighting on background tasks without
/// JavaScriptCore, HTML round-tripping, or memory bloat.
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

struct PreparedCodeText: View {
    let code: String
    let language: String?
    @Environment(\.colorScheme) private var colorScheme
    @State private var rendered: AttributedString?
    @State private var renderedKey: Key?

    private struct Key: Equatable {
        let code: String
        let language: String?
        let dark: Bool
    }

    var body: some View {
        let key = Key(code: code, language: language, dark: colorScheme == .dark)
        Text(renderedKey == key ? (rendered ?? AttributedString(code)) : AttributedString(code))
            .task(id: key) {
                do {
                    let result = try await CodeSyntaxHighlighter.shared.render(
                        code, language: language, dark: key.dark)
                    try Task.checkCancellation()
                    rendered = result
                    renderedKey = key
                } catch {
                    // Keep current, selectable source when preparation fails or is superseded.
                }
            }
    }
}
