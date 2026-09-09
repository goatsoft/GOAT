import Foundation
import HighlightSwift
import SwiftUI

/// Fences in reasoning are formatting, not interactive artifacts. Keep prose unchanged and
/// present code without fence markers, cards, toolbars or line-number gutters.
enum ThinkingFenceParser {
    struct Block: Equatable, Sendable {
        let text: String
        /// nil is prose; an empty language is an unlabelled, plain monospaced block.
        let language: String?
    }

    private struct Fence {
        let marker: Character
        let count: Int
        let quoteDepth: Int
        let indent: Int
        let info: String
    }

    static let maximumBytes = 2 * 1_024 * 1_024
    private static let maximumBlocks = 256

    static func parse(_ source: String) -> [Block] {
        guard source.utf8.count <= maximumBytes else { return [Block(text: source, language: nil)] }
        var blocks: [Block] = []
        var opening: Fence?
        var buffer = ""
        func flush(language: String?) {
            if !buffer.isEmpty { blocks.append(Block(text: buffer, language: language)) }
            buffer = ""
        }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in lines.enumerated() {
            let line = String(rawLine)
            let newline = index < lines.count - 1 ? "\n" : ""
            if let active = opening {
                if let candidate = fence(in: line), candidate.marker == active.marker,
                    candidate.count >= active.count, candidate.quoteDepth == active.quoteDepth,
                    candidate.info.isEmpty
                {
                    flush(language: active.info)
                    opening = nil
                } else {
                    buffer += codeLine(line, fence: active) + newline
                }
            } else if let candidate = fence(in: line) {
                flush(language: nil)
                opening = candidate
            } else {
                buffer += line + newline
            }
            guard blocks.count < maximumBlocks else { return [Block(text: source, language: nil)] }
        }
        // An unfinished fence is code too: don't flash raw delimiters while tokens arrive.
        flush(language: opening?.info)
        return blocks
    }

    static func isFenceLine(_ line: String) -> Bool { fence(in: line) != nil }

    private static func fence(in line: String) -> Fence? {
        var rest = line[...]
        var depth = 0
        var indent = 0
        while rest.first == " ", indent < 3 {
            rest.removeFirst()
            indent += 1
        }
        while rest.first == ">" {
            rest.removeFirst()
            depth += 1
            if rest.first == " " { rest.removeFirst() }
        }
        if depth > 0 {
            indent = 0
            while rest.first == " ", indent < 3 {
                rest.removeFirst()
                indent += 1
            }
        }
        guard let marker = rest.first, marker == "`" || marker == "~" else { return nil }
        let count = rest.prefix(while: { $0 == marker }).count
        guard count >= 3 else { return nil }
        let info = rest.dropFirst(count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard marker != "`" || !info.contains("`") else { return nil }
        return Fence(marker: marker, count: count, quoteDepth: depth, indent: indent, info: info)
    }

    private static func codeLine(_ line: String, fence: Fence) -> String {
        var rest = line[...]
        if fence.quoteDepth > 0 {
            var quoted = rest
            var leading = 0
            while quoted.first == " ", leading < 3 {
                quoted.removeFirst()
                leading += 1
            }
            for _ in 0..<fence.quoteDepth {
                guard quoted.first == ">" else { return line }
                quoted.removeFirst()
                if quoted.first == " " { quoted.removeFirst() }
            }
            rest = quoted
        }
        for _ in 0..<fence.indent {
            if rest.first == " " { rest.removeFirst() }
        }
        return String(rest)
    }
}

private actor ThinkingPreparation {
    static let shared = ThinkingPreparation()
    func blocks(_ source: String) throws -> [ThinkingFenceParser.Block] {
        try Task.checkCancellation()
        return ThinkingFenceParser.parse(source)
    }
}

struct ThinkingContentView: View {
    let source: String
    @Environment(AppModel.self) private var model
    @State private var blocks: [ThinkingFenceParser.Block] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if let language = block.language {
                    ThinkingCodeText(code: block.text, language: language)
                        .font(
                            Font(ReadingFonts.nsFont(model.effectiveCodeFontID, size: model.codeFontSize, role: .code)))
                } else {
                    Text(block.text)
                        .font(
                            Font(
                                ReadingFonts.nsFont(
                                    model.effectiveChatFontID, size: model.chatFontSize - 1, role: .chat))
                        )
                        .lineSpacing(4)
                }
            }
        }
        .foregroundStyle(model.theme.tokens.ink)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: source) {
            guard let prepared = try? await ThinkingPreparation.shared.blocks(source), !Task.isCancelled else { return }
            blocks = prepared
        }
    }
}

actor ThinkingCodeHighlighter {
    static let shared = ThinkingCodeHighlighter()
    private let highlight = Highlight()

    func render(_ code: String, language: String, dark: Bool) async throws -> AttributedString {
        let alias = language.split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased() ?? ""
        guard code.utf8.count <= HighlightedCodeView.maximumHighlightedBytes,
            !["", "text", "plain", "plaintext"].contains(alias)
        else { return AttributedString(code) }
        if alias == "vue" { return try await VueSyntaxHighlighter.shared.render(code, dark: dark) }
        let core = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty, let range = code.range(of: core),
            let colored = try? await highlight.attributedText(
                core, language: alias, colors: dark ? .dark(.xcode) : .light(.xcode)),
            String(colored.characters) == core
        else { return AttributedString(code) }
        try Task.checkCancellation()
        var result = AttributedString(String(code[..<range.lowerBound]))
        result.append(colored)
        result.append(AttributedString(String(code[range.upperBound...])))
        return result
    }
}

private struct ThinkingCodeText: View {
    let code: String
    let language: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var rendered: AttributedString?
    @State private var renderedKey: Key?
    private struct Key: Equatable {
        let code: String
        let language: String
        let dark: Bool
    }

    var body: some View {
        let key = Key(code: code, language: language, dark: colorScheme == .dark)
        Text(renderedKey == key ? (rendered ?? AttributedString(code)) : AttributedString(code))
            .fixedSize(horizontal: false, vertical: true)
            .task(id: key) {
                do {
                    // Current source stays visible while an active fence settles. Closed fences
                    // retain their highlights as later reasoning streams into other blocks.
                    try await Task.sleep(for: .milliseconds(120))
                    let result = try await ThinkingCodeHighlighter.shared.render(
                        code, language: language, dark: key.dark)
                    try Task.checkCancellation()
                    rendered = result
                    renderedKey = key
                } catch {}
            }
    }
}
