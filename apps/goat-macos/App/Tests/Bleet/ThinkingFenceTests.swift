import AppKit
import Bleet
import Testing

@testable import GOAT

extension AppTests.Bleet {
    @Suite struct ThinkingFenceTests {

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
                ThinkingFenceParser.parse("```\nproject/\n  src/\n```").first
                    == .init(text: "project/\n  src/\n", language: "")
            )
            #expect(ThinkingFenceParser.isFenceLine("```typescript"))
            #expect(!ThinkingFenceParser.isFenceLine("Use `const` here."))
            #expect(ThinkingFenceParser.parse("Use `const` here.") == [.init(text: "Use `const` here.", language: nil)])
        }

        @Test func thinkingBoundsPathologicalMarkdownAndPreservesOversizedSource() {
            let huge = String(repeating: "x", count: ThinkingFenceParser.maximumBytes + 1)
            #expect(ThinkingFenceParser.parse(huge) == [.init(text: huge, language: nil)])
            let many = String(
                repeating: "```ts\nconst a = 1\n```\ntext\n", count: ThinkingFenceParser.maximumBlocks / 2 + 1)
            #expect(ThinkingFenceParser.parse(many) == [.init(text: many, language: nil)])
            // Hundreds of blocks stay code and prose: segments, not a block cap, bound their layout.
            let hundreds = String(repeating: "```ts\nconst a = 1\n```\ntext\n", count: 300)
            #expect(ThinkingFenceParser.parse(hundreds).count == 600)
        }

        /// #60 A1: expanded reasoning is split into bounded segments that join back to its text. Pieces
        /// of one block continue each other; an oversized line is split at scalar boundaries.
        @Test func reasoningSegmentsAreBoundedAndLossless() {
            let prose = (0..<400).map { "Reasoning paragraph \($0) weighs one more consideration.\n" }.joined()
            let code = (0..<300).map { "let value\($0) = \($0) * 2\n" }.joined()
            let line = String(repeating: "x", count: ThinkingSegmenter.targetBytes * 2) + "\n"
            let source = prose + "```swift\n" + code + "```\n" + line + "Done."
            let blocks = ThinkingFenceParser.parse(source)
            let segments = ThinkingSegmenter.segments(blocks)
            #expect(segments.map(\.text).joined() == blocks.map(\.text).joined())
            #expect(segments.allSatisfy { $0.bytes <= ThinkingSegmenter.targetBytes && $0.bytes == $0.text.utf8.count })
            #expect(segments.indices.allSatisfy { segments[$0].index == $0 })
            let codeSegments = segments.filter { $0.language == "swift" }
            #expect(codeSegments.count > 1 && codeSegments.map(\.text).joined() == code)
            #expect(!codeSegments[0].continuesPrevious && codeSegments.dropFirst().allSatisfy(\.continuesPrevious))
            // Whole lines: every piece of the code block ends at a line break.
            #expect(codeSegments.allSatisfy { $0.text.hasSuffix("\n") })
            #expect(segments.last?.text == "Done." && segments.last?.continuesPrevious == true)
            #expect(ThinkingSegmenter.pieces("short") == ["short"])
        }

        /// #60 A1: expanded reasoning is prepared without its boundary blank lines, lays out a bounded
        /// window of its latest segments, and is cached by revision under a byte budget.
        @Test @MainActor func expandedReasoningPreparesABoundedWindow() async throws {
            let message = ChatMessage(role: .assistant)
            let prose = (0..<400).map { "Reasoning paragraph \($0) weighs one more consideration.\n" }.joined()
            message.appendStream(text: "", thinking: "\n\n" + prose + "\n\n")
            let prepared = try await ThinkingPreparation().prepare(
                id: message.id, source: message.thinking, revision: message.thinkingRevision)
            #expect(
                prepared.segments.map(\.text).joined() == TranscriptText.removingBoundaryBlankLines(message.thinking))
            #expect(prepared.bytes == prepared.segments.reduce(0) { $0 + $1.bytes })
            #expect(prepared.cost == prepared.segments.reduce(0) { $0 + $1.cost } && prepared.cost > prepared.bytes)
            let latest = try #require(prepared.resolve(.latest), "Reasoning over the budget lays out a window")
            #expect(latest.upperBound == prepared.segments.count && latest.lowerBound > 0)
            #expect(latest.reduce(0) { $0 + prepared.segments[$1].bytes } <= ReplyWindow.budget)
            #expect(prepared.resolve(.all) == nil)

            let cache = PreparedThinkingCache(maximumEntries: 2)
            #expect(cache.store(prepared, for: message.id))
            #expect(cache.thinking(for: message.id, revision: message.thinkingRevision) != nil)
            message.appendStream(text: "", thinking: "One more step.")
            #expect(cache.thinking(for: message.id, revision: message.thinkingRevision) == nil)
            #expect(cache.latest(for: message.id) != nil, "Streaming reasoning shows its last preparation")
            let small = PreparedThinkingCache(maximumTotalCost: 1_024)
            #expect(!small.store(prepared, for: message.id), "Reasoning over the entry budget is not retained")
            #expect(small.snapshot() == .init(entryCount: 0, totalCost: 0))
        }

        /// The full preparation `ThinkingSegmentation` must match at every refresh.
        private func reference(_ source: String) -> [ThinkingSegment] {
            ThinkingSegmenter.segments(ThinkingFenceParser.parse(TranscriptText.removingBoundaryBlankLines(source)))
        }

        /// `source` appended in pieces of `step` characters, as reasoning streams.
        private func appends(_ source: String, step: Int) -> [String] {
            let characters = Array(source)
            return stride(from: 0, to: characters.count, by: step).map {
                String(characters[$0..<min(characters.count, $0 + step)])
            }
        }

        /// #60 A1: streaming reasoning extends one segmentation. At every refresh it equals preparing
        /// the whole text again: boundary blank lines, unfinished, quoted and indented fences, long
        /// info strings, oversized lines and lines split across appends.
        @Test(arguments: [13, 97, 3_001])
        func incrementalSegmentationEqualsFullPreparation(step: Int) {
            let code = (0..<400).map { "let value\($0) = \($0) * 2\n" }.joined()
            let prose = (0..<120).map { "Paragraph \($0) weighs one more consideration, \u{E9}t\u{E9}.\n" }.joined()
            let source =
                "\n  \n" + prose + "\n\n```swift title=Answer.swift\n" + code + "```\n"
                + "> ```tsx\n> const card = <div />;\n> ```\n" + "   ~~~json\n   {\"ok\": true}\n   ~~~\n"
                + String(repeating: "x", count: ThinkingSegmenter.targetBytes * 2) + "\nThen\n\n"
                + "````text\n```\nliteral\n```\n````\n" + prose + "```ts\nconst partial =" + "\n\n  \n"
            var segmentation = ThinkingSegmentation()
            var text = ""
            for piece in appends(source, step: step) {
                text += piece
                let segments = segmentation.extend(to: text)
                let expected = reference(text)
                #expect(segments == expected, "After \(text.utf8.count) bytes")
                if segments != expected { return }
            }
        }

        /// Past `ThinkingFenceParser.maximumBlocks` the whole reasoning is prose, incrementally too.
        @Test func incrementalSegmentationFallsBackPastTheBlockCap() {
            let source = String(
                repeating: "```ts\nconst a = 1\n```\ntext\n", count: ThinkingFenceParser.maximumBlocks / 2 + 1)
            var segmentation = ThinkingSegmentation()
            var text = ""
            for piece in appends(source, step: 4_096) {
                text += piece
                #expect(segmentation.extend(to: text) == reference(text), "After \(text.utf8.count) bytes")
            }
            #expect(segmentation.extend(to: text).allSatisfy { $0.language == nil })
        }

        /// #60 A1, A3: preparing streaming reasoning parses each appended byte about once, so the work
        /// grows linearly with the reasoning through the rich limit, not with the square of its length.
        @Test func streamingPreparationWorkGrowsLinearly() {
            let paragraphs = (0..<60_000).map { "Reasoning paragraph \($0) weighs one more consideration.\n" }
            let full = paragraphs.joined()
            for (kib, step) in [(32, 1_024), (64, 1_024), (128, 1_024), (2_048, 16_384)] {
                let source = String(full.utf8.prefix(kib * 1_024))!
                var segmentation = ThinkingSegmentation()
                var text = ""
                var segments: [ThinkingSegment] = []
                for piece in appends(source, step: step) {
                    text += piece
                    segments = segmentation.extend(to: text)
                }
                #expect(segments == reference(source), "\(kib) KiB")
                #expect(
                    segmentation.scannedBytes <= source.utf8.count * 11 / 10,
                    "\(kib) KiB scanned \(segmentation.scannedBytes) bytes for \(source.utf8.count)")
            }
        }

        /// #60 A1: an unbounded fence info string is never retained. Segments keep its first word,
        /// bounded, and caches charge what segments retain, metadata included.
        @Test @MainActor func segmentsBoundAndChargeFenceMetadata() {
            let info = String(repeating: "x", count: 1_024 * 1_024)
            let source = "```" + info + "\nx\n```"
            let segments = ThinkingSegmenter.segments(ThinkingFenceParser.parse(source))
            #expect(segments.count == 1)
            #expect(segments.first?.language?.count == ThinkingSegmenter.maximumLanguageCharacters)
            var segmentation = ThinkingSegmentation()
            #expect(segmentation.extend(to: source) == segments)
            #expect(ThinkingSegmenter.language("swift title=Answer.swift") == "swift")
            #expect(ThinkingSegmenter.language("") == "" && ThinkingSegmenter.language(nil) == nil)

            let revision = TextRevision(epoch: 1, utf8Count: source.utf8.count)
            let prepared = PreparedThinking(revision: revision, segments: segments)
            let storage = MemoryLayout<ThinkingSegment>.stride
            #expect(prepared.cost == 2 + ThinkingSegmenter.maximumLanguageCharacters + storage)
            #expect(segments.first?.cost == prepared.cost)
            // Admission is charged by cost, so many such entries stay within the cache's budget.
            let cache = PreparedThinkingCache(maximumEntries: 64, maximumTotalCost: prepared.cost * 3)
            for _ in 0..<10 { cache.store(prepared, for: UUID()) }
            #expect(cache.snapshot().entryCount == 3 && cache.snapshot().totalCost == prepared.cost * 3)
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
                String(
                    try await ThinkingCodeHighlighter.shared.render(updated, language: "typescript", dark: dark)
                        .characters)
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
                    String(
                        try await ThinkingCodeHighlighter.shared.render(source, language: language, dark: false)
                            .characters)
                        == source)
            }
        }
    }
}
