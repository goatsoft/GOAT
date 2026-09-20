import Foundation
import HighlightSwift
import SwiftUI

/// HighlightSwift's CodeText uses a class-valued @Entry default that constructs a
/// Highlight on every access. Own one runtime explicitly, independent of view updates.
actor CodeSyntaxHighlighter {
    static let shared = CodeSyntaxHighlighter()
    private let highlight = Highlight()

    func render(_ source: String, language: String?, dark: Bool) async throws -> AttributedString {
        try Task.checkCancellation()
        guard source.utf8.count <= HighlightedCodeView.maximumHighlightedBytes else {
            return AttributedString(source)
        }
        let core = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty, let range = source.range(of: core) else { return AttributedString(source) }
        let result: AttributedString
        if let language {
            result = try await highlight.attributedText(
                core, language: language, colors: dark ? .dark(.xcode) : .light(.xcode))
        } else {
            result = try await highlight.attributedText(core, colors: dark ? .dark(.xcode) : .light(.xcode))
        }
        try Task.checkCancellation()
        // The library's HTML conversion trims boundaries. Preserve source and indentation,
        // and reject a conversion that changes the actual code (as the Vue path does).
        guard String(result.characters) == core else { return AttributedString(source) }
        var output = AttributedString(String(source[..<range.lowerBound]))
        output.append(result)
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
