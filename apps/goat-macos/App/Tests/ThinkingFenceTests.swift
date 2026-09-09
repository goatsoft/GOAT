import AppKit
import Testing

@testable import GOAT

@Test func thinkingFencesSeparateCodeFromProseAndHideMarkers() {
    let source = "Plan first.\n```typescript\nconst answer: number = 42;\n```\nThen continue.\n"
    let blocks = ThinkingFenceParser.parse(source)
    #expect(
        blocks == [
            .init(text: "Plan first.\n", language: nil),
            .init(text: "const answer: number = 42;\n", language: "typescript"),
            .init(text: "Then continue.\n", language: nil),
        ])
    #expect(!blocks.map(\.text).joined().contains("```"))
}

@Test func thinkingHandlesUnfinishedQuotedIndentedAndLongFences() {
    #expect(
        ThinkingFenceParser.parse("Before\n```ts\nconst partial =") == [
            .init(text: "Before\n", language: nil), .init(text: "const partial =", language: "ts"),
        ])
    #expect(
        ThinkingFenceParser.parse("> ```tsx\n> const card = <div />;\n> ```\n") == [
            .init(text: "const card = <div />;\n", language: "tsx")
        ])
    #expect(
        ThinkingFenceParser.parse("   ~~~json\n   {\"ok\": true}\n   ~~~") == [
            .init(text: "{\"ok\": true}\n", language: "json")
        ])
    #expect(
        ThinkingFenceParser.parse("````text\n```\nliteral shorter fence\n```\n````") == [
            .init(text: "```\nliteral shorter fence\n```\n", language: "text")
        ])
    #expect(
        ThinkingFenceParser.parse("```\nproject/\n  src/\n```").first == .init(text: "project/\n  src/\n", language: "")
    )
    #expect(ThinkingFenceParser.isFenceLine("```typescript"))
    #expect(!ThinkingFenceParser.isFenceLine("Use `const` here."))
    #expect(ThinkingFenceParser.parse("Use `const` here.") == [.init(text: "Use `const` here.", language: nil)])
}

@Test func thinkingBoundsPathologicalMarkdownAndPreservesOversizedSource() {
    let huge = String(repeating: "x", count: ThinkingFenceParser.maximumBytes + 1)
    #expect(ThinkingFenceParser.parse(huge) == [.init(text: huge, language: nil)])
    let many = String(repeating: "```ts\nconst a = 1\n```\ntext\n", count: 300)
    #expect(ThinkingFenceParser.parse(many) == [.init(text: many, language: nil)])
}

@Test(arguments: [false, true])
func thinkingHighlightsTypeScriptAndPreservesWhitespace(dark: Bool) async throws {
    let source = "\n  const answer: number = 42;\n\n"
    let result = try await ThinkingCodeHighlighter.shared.render(source, language: "ts", dark: dark)
    #expect(String(result.characters) == source)
    for token in ["const", "number"] {
        let range = try #require(result.range(of: token))
        #expect(result[range].runs.contains { $0.appKit.foregroundColor != nil })
    }
    let updated = "const answer: number = 43;"
    #expect(
        String(try await ThinkingCodeHighlighter.shared.render(updated, language: "typescript", dark: dark).characters)
            == updated)
}

@Test func thinkingHighlightsVueAndKeepsUnknownOrUnlabelledBlocksReadable() async throws {
    let vue = "<script setup lang=\"ts\">const answer: number = 42;</script>"
    let result = try await ThinkingCodeHighlighter.shared.render(vue, language: "vue", dark: true)
    #expect(String(result.characters) == vue)
    let range = try #require(result.range(of: "const"))
    #expect(result[range].runs.contains { $0.appKit.foregroundColor != nil })
    for language in ["", "unknown-language", "plaintext"] {
        let source = "project/\n  src/\n"
        #expect(
            String(try await ThinkingCodeHighlighter.shared.render(source, language: language, dark: false).characters)
                == source)
    }
}
