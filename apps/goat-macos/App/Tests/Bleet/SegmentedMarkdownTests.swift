import AppKit
import Bleet
import MarkdownUI
import SwiftUI
import Testing

@testable import GOAT

private let fence = "```"

/// Paragraphs, lists, code, quotes, tables, headings and breaks, so whole-block boundaries fall
/// between every pair of block kinds a reply commonly places side by side.
private let mixedBlocks: [String] = [
    "# Report", "An opening paragraph with *emphasis* and `code`.",
    "- loose first\n\n  continued\n\n- loose second", "\(fence)swift\nlet value = 1\n\(fence)",
    "\(fence)\nplain code right after code\n\(fence)", "A paragraph after two code blocks.",
    "> quoted line\n> quoted again", "| Name | Value |\n| --- | --- |\n| a | 1 |", "---", "## Section",
    "Setext title\n============", "1. ordered\n2. tight", "Closing paragraph\nwith a soft break.",
]

/// A reply of `bytes` UTF-8 bytes in the shapes a long answer usually has.
private func longReply(bytes: Int) -> String {
    var reply = ""
    var index = 0
    while reply.utf8.count < bytes {
        switch index % 4 {
        case 0: reply += "## Part \(index)\n\n"
        case 1:
            reply +=
                "\(fence)swift\n" + (0..<12).map { "let v\($0) = \(index)" }.joined(separator: "\n") + "\n\(fence)\n\n"
        case 2: reply += "- item \(index)\n- another item\n- a third item with words\n\n"
        default: reply += String(repeating: "A sentence of the answer that keeps going. ", count: 12) + "\n\n"
        }
        index += 1
    }
    return String(reply.utf8.prefix(bytes)) ?? reply
}

/// Segment sources with their expected leading and trailing margins and whether the last leaf is a
/// paragraph (#60 A1).
private let structureCases: [(String, Double?, Double?, Bool)] = [
    ("Paragraph.", 0, 1, true), ("# Title\n\nText", 1.5, 1, true),
    ("\(fence)\ncode\n\(fence)", nil, nil, false), ("> \(fence)\n> code\n> \(fence)", nil, nil, false),
    ("> # Title\n> text", 1.5, 1, true), ("> text\n>\n> > nested", 0, 1, true), ("- a\n- b", 0, 1, true),
    ("- \(fence)\n  code\n  \(fence)", nil, nil, false), ("---", 2, 2, false), ("Text\n\n---", 0, 2, false),
    ("| a |\n| - |\n| 1 |", 0, 1, false), ("<div>x</div>", 0, 1, false), ("- [ ] task", 0, 1, true),
    ("- item\n\n  ---", 2, 2, false), ("Title\n=====", 1.5, 1, false), ("![alt](x.png)", 0, 1, false),
]

/// `reply` in appends of about `bytes` UTF-8 bytes, each ending on a scalar boundary.
private func chunks(of reply: String, bytes step: Int) -> [String] {
    let bytes = Array(reply.utf8)
    var result: [String] = []
    var start = 0
    while start < bytes.count {
        var end = min(bytes.count, start + step)
        while end < bytes.count, bytes[end] & 0xC0 == 0x80 { end += 1 }
        result.append(String(decoding: bytes[start..<end], as: UTF8.self))
        start = end
    }
    return result
}

/// Streams `reply` into `cache` in `step`-byte appends, then completes it.
private func stream(
    _ reply: String, step: Int, into cache: MarkdownSegmentCache, id: UUID = UUID(),
    observe: (PreparedMarkdownDocument) -> Void = { _ in }
) async throws -> PreparedMarkdownDocument {
    let bytes = Array(reply.utf8)
    var end = 0
    while end < bytes.count {
        end = min(bytes.count, end + step)
        // Appends end on scalar boundaries, as streamed text does.
        while end < bytes.count, bytes[end] & 0xC0 == 0x80 { end += 1 }
        let prefix = try #require(String(bytes: bytes[..<end], encoding: .utf8))
        observe(try #require(await cache.prepare(id: id, source: prefix, isComplete: false)))
    }
    let final = try #require(await cache.prepare(id: id, source: reply, isComplete: true))
    observe(final)
    return final
}

extension AppTests.Bleet {
    /// #60 A1/A3 step 2 (ADR-0091): replies prepare as segments, settled segments once.
    @Suite struct MarkdownSegmentCacheTests {

        @Test func settledSegmentsArePreparedOnceWhileTheReplyStreams() async throws {
            let cache = MarkdownSegmentCache(targetBytes: 256, maximumBytes: 1_024)
            let reply = mixedBlocks.joined(separator: "\n\n") + "\n\n" + longReply(bytes: 6_000)
            var settledPreparation: [Int: UInt64] = [:]
            var updates = 0
            let completed = try await stream(reply, step: 61, into: cache) { document in
                updates += 1
                for segment in document.segments where segment.isSettled {
                    if let first = settledPreparation[segment.index] {
                        #expect(first == segment.preparationID, "Settled segment \(segment.index) was re-prepared")
                    } else {
                        settledPreparation[segment.index] = segment.preparationID
                    }
                }
            }
            let whole = MarkdownSegmenter.segment(reply, isComplete: true, targetBytes: 256, maximumBytes: 1_024)
            let expected = whole.map(\.text)
            #expect(completed.segments.map(\.text) == expected)
            #expect(completed.segments.allSatisfy { $0.isSettled })
            #expect(completed.renderedBytes == whole.reduce(0) { $0 + $1.text.utf8.count })
            let snapshot = await cache.snapshot()
            #expect(settledPreparation.count == whole.count)
            // Every segment is parsed at least once; only the provisional tail is parsed again.
            #expect(snapshot.parseCount >= whole.count)
            #expect(snapshot.parseCount < whole.count + updates * 3)
            #expect(snapshot.streamCount == 0, "Completion releases the scanner state")
        }

        /// #60 measurement 1: parse work as a reply streams grows linearly with the reply, where
        /// re-parsing the whole reply on every refresh grows quadratically.
        @Test func streamingParseWorkGrowsLinearlyWithTheReply() async throws {
            var ratios: [Int: Double] = [:]
            for kibibytes in [32, 64, 128] {
                let cache = MarkdownSegmentCache()
                let reply = longReply(bytes: kibibytes * 1_024)
                _ = try await stream(reply, step: 1_024, into: cache)
                let parsed = await cache.snapshot().parsedBytes
                ratios[kibibytes] = Double(parsed) / Double(reply.utf8.count)
                // Whole-reply parsing at the same refreshes: the sum of every prefix.
                let whole = (1...kibibytes).reduce(0) { $0 + $1 * 1_024 }
                #expect(parsed * 4 < whole, "\(kibibytes) KiB parsed \(parsed) bytes; whole-reply parsing \(whole)")
            }
            let small = try #require(ratios[32])
            let large = try #require(ratios[128])
            // Quadrupling the reply leaves parsed bytes per reply byte flat (quadratic work would quadruple it).
            #expect(large < small * 1.25, "Parsed bytes per reply byte: \(ratios.sorted { $0.key < $1.key })")
        }

        @Test func aLaterDefinitionRepreparesSettledSegments() async throws {
            let cache = MarkdownSegmentCache(targetBytes: 1, maximumBytes: 1_024)
            let id = UUID()
            let opening = "See the [guide][g].\n\nA second paragraph.\n\nA third.\n\n"
            let before = try #require(await cache.prepare(id: id, source: opening, isComplete: false))
            let first = try #require(before.segments.first)
            #expect(first.isSettled && first.definitionSuffix.isEmpty)
            let after = try #require(
                await cache.prepare(id: id, source: opening + "[g]: https://example.com\n", isComplete: true))
            let revised = try #require(after.segments.first)
            #expect(revised.preparationID != first.preparationID)
            #expect(revised.text.hasSuffix("[g]: https://example.com\n"))
            guard case .parsed(let content) = revised.preparation else {
                Issue.record("Expected Markdown")
                return
            }
            #expect(content.value.renderHTML().contains("href=\"https://example.com\""))
        }

        @Test func anEditStartsANewSegmentationAndKeepsUnchangedSegments() async throws {
            let cache = MarkdownSegmentCache(targetBytes: 1, maximumBytes: 1_024)
            let id = UUID()
            let streamed = try #require(
                await cache.prepare(id: id, source: "First.\n\nSecond.\n\nThird.\n\n", isComplete: false))
            // Completion trims trailing whitespace: the final source no longer extends the streamed one.
            let trimmed = try #require(
                await cache.prepare(id: id, source: "First.\n\nSecond.\n\nThird.", isComplete: true))
            #expect(trimmed.segments.map(\.text) == ["First.\n\n", "Second.\n\n", "Third."])
            #expect(trimmed.segments[0].preparationID == streamed.segments[0].preparationID)
            #expect(trimmed.segments[1].preparationID == streamed.segments[1].preparationID)
            let edited = try #require(await cache.prepare(id: id, source: "Changed.\n\nSecond.", isComplete: true))
            #expect(edited.segments.map(\.text) == ["Changed.\n\n", "Second."])
            #expect(edited.segments[0].preparationID != streamed.segments[0].preparationID)
            let again = try #require(await cache.prepare(id: id, source: "Changed.\n\nSecond.", isComplete: true))
            #expect(again.segments.map(\.preparationID) == edited.segments.map(\.preparationID))
        }

        @Test func verbatimPiecesRenderAsPlainTextWithoutParsing() async throws {
            let cache = MarkdownSegmentCache(targetBytes: 256, maximumBytes: 1_024)
            let comment = "<!--\n" + String(repeating: "a line inside a long comment\n", count: 120) + "-->\n"
            let reply =
                "> \(fence)\n" + String(repeating: "> quoted code line\n", count: 120) + "> \(fence)\n\n" + comment
            let document = try #require(await cache.prepare(id: UUID(), source: reply, isComplete: true))
            let verbatim = document.segments.filter { $0.kind == .verbatimPiece }
            #expect(verbatim.count > 2)
            for segment in verbatim {
                guard case .plainText = segment.preparation else {
                    Issue.record("Verbatim piece \(segment.index) was parsed")
                    continue
                }
            }
            let parsed = document.segments.count - verbatim.count
            #expect(await cache.snapshot().parseCount == parsed)
        }

        /// #60 B1: the caret follows the tail's structure. Only a streaming tail whose last leaf block is
        /// a paragraph carries it, whatever text earlier blocks share with that ending.
        @Test(arguments: [
            ("Done.", true), ("Done.\n\nDone.", true), ("done.\n\nAll done.", true),
            ("Intro.\n\n- one\n- two", true), ("- loose\n\n  continued", true), ("> quoted\n> ending", true),
            ("1. outer\n   - inner ending", true), ("- [ ] task ending", true),
            ("Done.\n\n\(fence)\nDone.\n\(fence)", false), ("Done.\n\n# Done.", false),
            ("Done.\n\n| Done. |\n| --- |\n| Done. |", false), ("Done.\n\n---", false),
            ("Done.\n\n![Done.](x.png)", false), ("Done.\n\n<div>Done.</div>", false),
            ("- Done.\n\n  \(fence)\n  Done.\n  \(fence)", false), ("> Done.\n>\n> ## Done.", false),
        ])
        func caretFollowsTheTailsLastLeafBlock(source: String, endsInParagraph: Bool) async throws {
            let cache = MarkdownSegmentCache()
            let streaming = try #require(await cache.prepare(id: UUID(), source: source, isComplete: false))
            #expect(streaming.segments.map(\.endsInParagraph) == [endsInParagraph])
            let complete = try #require(await cache.prepare(id: UUID(), source: source, isComplete: true))
            #expect(complete.segments.map(\.endsInParagraph) == [nil])
        }

        /// #60 A1: a parsed segment's first and last margins are the largest any block inside each
        /// top-level block sets (nil when none does), read from cmark's structure, not its text.
        @Test(arguments: structureCases)
        func parsedStructureGivesMarginsAndTheLastLeaf(
            source: String, leading: Double?, trailing: Double?, lastLeafIsParagraph: Bool
        ) {
            let html = MarkdownContent(GOATMarkdownSyntax.normalized(source, detectsArtifacts: false)).renderHTML()
            let structure = MarkdownSegmentSpacing.structure(html: html)
            #expect(structure.leadingMargin == leading, "\(html)")
            #expect(structure.trailingMargin == trailing, "\(html)")
            #expect(structure.lastLeafIsParagraph == lastLeafIsParagraph, "\(html)")
        }

        @Test func cacheChargesRenderedBytesAndEvictsWithinBounds() async throws {
            let cache = MarkdownSegmentCache(maximumEntries: 2, maximumCost: 600, maximumEntryCost: 400, targetBytes: 1)
            let reference = "Use [a][x].\n\nThen [a][x] again.\n\n[x]: https://example.com/x\n"
            let document = try #require(await cache.prepare(id: UUID(), source: reference, isComplete: true))
            // Each segment that accepts definitions renders the suffix, so rendered bytes exceed the source.
            #expect(document.renderedBytes == document.segments.reduce(0) { $0 + $1.text.utf8.count })
            #expect(document.renderedBytes > reference.utf8.count)
            #expect(await cache.snapshot().cost == document.cost)

            _ = await cache.prepare(id: UUID(), source: "Two.", isComplete: true)
            _ = await cache.prepare(id: UUID(), source: "Three.", isComplete: true)
            let bounded = await cache.snapshot()
            #expect(bounded.entryCount == 2 && bounded.cost <= 600)

            let oversized = String(repeating: "word ", count: 100)
            #expect(await cache.prepare(id: UUID(), source: oversized, isComplete: false) != nil)
            #expect(await cache.snapshot().streamCount == 0, "An unretained reply keeps no scanner state")
            await cache.removeAll()
            #expect(await cache.snapshot().cost == 0)
        }

        @Test @MainActor func frontCacheServesExactAndLatestDocumentsWithinItsBudget() async throws {
            let segments = MarkdownSegmentCache()
            let cache = PreparedMarkdownDocumentCache(maximumEntries: 2, maximumTotalCost: 200, maximumEntryCost: 120)
            let message = ChatMessage(role: .assistant)
            message.appendStream(text: "Partial", thinking: "")
            let partial = message.textRevision
            let streaming = try #require(
                await segments.prepare(id: message.id, source: message.text, revision: partial, isComplete: false))
            #expect(cache.store(streaming, for: message.id))
            message.appendStream(text: " reply", thinking: "")
            #expect(cache.document(for: message.id, revision: message.textRevision) == nil)
            #expect(cache.document(for: message.id, revision: partial)?.source == "Partial")
            #expect(cache.latest(for: message.id)?.source == "Partial")
            #expect(cache.renderedBytes(for: message.id, revision: partial) == streaming.renderedBytes)
            #expect(cache.renderedBytes(for: message.id, revision: message.textRevision) == nil)
            message.text = String(repeating: "x", count: 100)
            let large = try #require(
                await segments.prepare(
                    id: message.id, source: message.text, revision: message.textRevision, isComplete: true))
            #expect(!cache.store(large, for: message.id))
            #expect(cache.latest(for: message.id) == nil, "A declined store drops the older document")
            for _ in 0..<3 {
                let other = UUID()
                cache.store(
                    try #require(await segments.prepare(id: other, source: "Short", isComplete: true)), for: other)
            }
            #expect(cache.snapshot().entryCount == 2 && cache.snapshot().totalCost <= 200)
        }

        @Test @MainActor func windowChargesThePreparedRepresentation() async throws {
            let message = ChatMessage(role: .assistant)
            message.text = "Use [a][x].\n\nThen [a][x] again.\n\n[x]: https://example.com/x\n"
            message.complete = true
            #expect(TranscriptWindow.displayCost(message) == message.text.utf8.count)
            let document = try #require(
                await MarkdownSegmentCache(targetBytes: 1).prepare(
                    id: message.id, source: message.text, revision: message.textRevision, isComplete: true))
            PreparedMarkdownDocumentCache.shared.store(document, for: message.id)
            #expect(TranscriptWindow.displayCost(message) == document.renderedBytes)
            message.text += "\n\nMore."
            #expect(TranscriptWindow.displayCost(message) == message.text.utf8.count)
        }

        /// #60 A1: a streamed reply extends its segmentation by revision, so a refresh compares only
        /// the bytes it re-prepares, never the reply's prefix, and visits only new and provisional
        /// segments.
        @Test @MainActor func revisionsExtendTheReplyWithoutComparingItsText() async throws {
            let cache = MarkdownSegmentCache(maximumEntryCost: 8 * 1_024 * 1_024)
            let message = ChatMessage(role: .assistant)
            let reply = mixedBlocks.joined(separator: "\n\n") + "\n\n" + longReply(bytes: 256 * 1_024)
            var refreshes = 0
            for chunk in chunks(of: reply, bytes: 1_024) {
                message.appendStream(text: chunk, thinking: "")
                _ = try #require(
                    await cache.prepare(
                        id: message.id, source: message.text, revision: message.textRevision, isComplete: false))
                refreshes += 1
                #expect(await cache.snapshot().streamCount == 1, "The scanner is retained while streaming")
            }
            let complete = try #require(
                await cache.prepare(
                    id: message.id, source: message.text, revision: message.textRevision, isComplete: true))
            let work = await cache.snapshot().work
            let whole = MarkdownSegmenter.segment(reply, isComplete: true)
            #expect(complete.segments.map(\.text) == whole.map(\.text))
            // Only re-prepared bodies are compared: at most the provisional bytes per refresh.
            #expect(
                work.comparedBytes <= (refreshes + 1) * 3 * MarkdownSegmenter.maximumBytes,
                "Compared \(work.comparedBytes) bytes over \(refreshes) refreshes")
            #expect(work.maximumVisitedSegments <= 6, "Visited at most \(work.maximumVisitedSegments) per refresh")
            #expect(work.visitedSegments <= whole.count + (refreshes + 1) * 3)
        }

        /// #60 A1: an edit, a trim or a replacement starts a new segmentation even when the new text
        /// is longer, and a stale revision never extends a newer one.
        @Test @MainActor func editsTrimsAndReplacementsStartANewSegmentation() async throws {
            let cache = MarkdownSegmentCache(targetBytes: 1, maximumBytes: 1_024)
            let message = ChatMessage(role: .assistant)
            func prepare(complete: Bool = false) async throws -> PreparedMarkdownDocument {
                try #require(
                    await cache.prepare(
                        id: message.id, source: message.text, revision: message.textRevision, isComplete: complete))
            }
            message.appendStream(text: "First.\n\nSecond.\n\nThird.\n\n", thinking: "")
            let streamed = try await prepare()
            // Completion trims trailing whitespace: a new epoch, reusing unchanged preparations.
            message.text = "First.\n\nSecond.\n\nThird."
            let trimmed = try await prepare(complete: true)
            #expect(trimmed.segments.map(\.text) == ["First.\n\n", "Second.\n\n", "Third."])
            #expect(trimmed.segments[0].preparationID == streamed.segments[0].preparationID)
            // An edit that makes the text longer still starts over.
            message.text = "Changed and longer first paragraph.\n\nSecond.\n\nThird."
            let edited = try await prepare()
            #expect(edited.segments.map(\.text).first == "Changed and longer first paragraph.\n\n")
            #expect(edited.segments[1].preparationID == streamed.segments[1].preparationID)
            // A replacement of the same length renders the new text.
            message.text = "Replaced and longer first paragraph.\n\nSecond.\n\nThird."
            let replaced = try await prepare()
            #expect(replaced.segments.first?.text == "Replaced and longer first paragraph.\n\n")
            // A stale sample (an older revision of another epoch) starts over rather than extending.
            let stale = try #require(
                await cache.prepare(
                    id: message.id, source: "Stale.", revision: TextRevision(epoch: 0, utf8Count: 6),
                    isComplete: false))
            #expect(stale.segments.map(\.text) == ["Stale."])
            let current = try await prepare()
            #expect(current.segments.map(\.text) == replaced.segments.map(\.text))
        }

        /// #60 A1: a later reference definition prepares again only settled segments that can use it.
        @Test func laterDefinitionsReprepareOnlySegmentsThatCanUseThem() async throws {
            let cache = MarkdownSegmentCache(targetBytes: 1, maximumBytes: 1_024)
            let id = UUID()
            let opening = "Plain one.\n\nSee the [guide][g].\n\nPlain two.\n\n`code` only.\n\n"
            let before = try #require(await cache.prepare(id: id, source: opening, isComplete: false))
            let after = try #require(
                await cache.prepare(id: id, source: opening + "[g]: https://example.com\n\nMore.", isComplete: false))
            for index in [0, 2, 3] {
                #expect(after.segments[index].preparationID == before.segments[index].preparationID)
            }
            #expect(after.segments[1].preparationID != before.segments[1].preparationID)
            guard case .parsed(let content) = after.segments[1].preparation else {
                Issue.record("Expected Markdown")
                return
            }
            #expect(content.value.renderHTML().contains("href=\"https://example.com\""))
            #expect(await cache.snapshot().work.definitionVisits >= 3)
        }

        /// #60 A1 step 3: a window parses only its segments; the others keep their text unparsed, and
        /// parses outside the window's margin are released, so retention follows the window.
        @Test func aWindowParsesOnlyItsSegmentsAndReleasesTheRest() async throws {
            let cache = MarkdownSegmentCache(targetBytes: 1, maximumBytes: 1_024)
            let id = UUID()
            let source = (0..<200).map { "Paragraph \($0) of a long reply." }.joined(separator: "\n\n")
            let windowed = try #require(
                await cache.prepare(id: id, source: source, isComplete: true, window: 100..<105))
            #expect(windowed.segments.count == 200)
            #expect(windowed.segments.filter(\.isParsed).map(\.index) == Array(100..<105))
            #expect(await cache.snapshot().parseCount == 5)
            #expect(windowed.retainedBytes == windowed.segments[100..<105].reduce(0) { $0 + $1.text.utf8.count })
            #expect(windowed.renderedBytes > windowed.retainedBytes * 30)
            #expect(windowed.cost == windowed.retainedBytes + source.utf8.count)

            // Moving within the margin parses only the new segments and keeps nearby ones.
            let moved = try #require(await cache.prepare(id: id, source: source, isComplete: true, window: 102..<108))
            #expect(await cache.snapshot().parseCount == 8)
            #expect(moved.segments.filter(\.isParsed).map(\.index) == Array(100..<108))
            // A distant window releases the old parses; a document already handed out keeps its own.
            let far = try #require(await cache.prepare(id: id, source: source, isComplete: true, window: 10..<12))
            #expect(far.segments.filter(\.isParsed).map(\.index) == [10, 11])
            #expect(moved.segments[103].isParsed)
            // Asking for every segment parses the rest.
            let whole = try #require(await cache.prepare(id: id, source: source, isComplete: true))
            #expect(whole.segments.allSatisfy(\.isParsed) && whole.retainedBytes == whole.renderedBytes)
        }

        /// While a long reply streams with a window on its tail, retained parses stay bounded however
        /// long the reply grows, and late definitions re-parse only segments in the window.
        @Test(arguments: [PreparationShape.mixed, .lateDefinitions])
        @MainActor func aStreamingTailWindowBoundsRetainedParses(shape: PreparationShape) async throws {
            func run(windowed: Bool) async throws -> (maximumRetained: Int, maximumParses: Int) {
                let cache = MarkdownSegmentCache(maximumCost: 64 * 1_024 * 1_024, maximumEntryCost: 64 * 1_024 * 1_024)
                let message = ChatMessage(role: .assistant)
                var window = 0..<4
                var maximumRetained = 0
                var maximumParses = 0
                for chunk in chunks(of: shape.reply(bytes: 256 * 1_024), bytes: 4_096) {
                    message.appendStream(text: chunk, thinking: "")
                    let before = await cache.snapshot().parseCount
                    let document = try #require(
                        await cache.prepare(
                            id: message.id, source: message.text, revision: message.textRevision, isComplete: false,
                            window: windowed ? window : nil))
                    maximumParses = max(maximumParses, await cache.snapshot().parseCount - before)
                    maximumRetained = max(maximumRetained, document.retainedBytes)
                    // Following keeps the last segments in the window, as the view does.
                    window = max(0, document.segments.count - 3)..<document.segments.count + 1
                }
                return (maximumRetained, maximumParses)
            }
            let windowed = try await run(windowed: true)
            let whole = try await run(windowed: false)
            #expect(windowed.maximumRetained <= 6 * MarkdownSegmenter.maximumBytes, "\(windowed)")
            #expect(whole.maximumRetained > 3 * windowed.maximumRetained, "\(whole) vs \(windowed)")
            #expect(windowed.maximumParses <= 6, "One refresh parses at most the window: \(windowed)")
            if shape == .lateDefinitions {
                #expect(whole.maximumParses > 20, "Without a window, definitions re-parse the reply: \(whole)")
            }
        }

        /// #60 A1 step 3: under the default bounds a reply streams to the rich limit showing its latest
        /// segments. The cache keeps its scanner at every refresh (no rescans), the view lays out at most
        /// the reply budget, and parses are retained for the window only, not the reply.
        @Test @MainActor func aReplyStreamsToTheRichLimitUnderTheDefaultBounds() async throws {
            let cache = MarkdownSegmentCache()
            let message = ChatMessage(role: .assistant)
            var maximumShown = 0
            var maximumRetained = 0
            var last: PreparedMarkdownDocument?
            for chunk in chunks(of: PreparationShape.mixed.reply(bytes: ReplyWindow.richLimit - 8_192), bytes: 32_768) {
                message.appendStream(text: chunk, thinking: "")
                let document = try #require(
                    await cache.prepare(
                        id: message.id, source: message.text, revision: message.textRevision, isComplete: false,
                        window: .latest))
                maximumShown = max(maximumShown, document.shownBytes)
                maximumRetained = max(maximumRetained, document.retainedBytes)
                #expect(await cache.snapshot().streamCount == 1, "Refresh at \(message.textRevision.utf8Count) bytes")
                last = document
            }
            let streamed = try #require(last)
            #expect(message.textRevision.utf8Count <= ReplyWindow.richLimit)
            #expect(streamed.window?.upperBound == streamed.segments.count, "Following shows the latest segments")
            let segmentBound = MarkdownSegmenter.maximumBytes + MarkdownSegmenter.definitionLimit
            #expect(maximumShown <= max(ReplyWindow.budget, 2 * segmentBound), "\(maximumShown)")
            let margins = 2 * MarkdownSegmentCache.retentionMargin * segmentBound
            #expect(maximumRetained <= maximumShown + margins, "\(maximumRetained)")
            #expect(streamed.retainedBytes * 10 < streamed.renderedBytes)

            message.complete = true
            let complete = try #require(
                await cache.prepare(
                    id: message.id, source: message.text, revision: message.textRevision, isComplete: true,
                    window: .latest))
            #expect(complete.window?.upperBound == complete.segments.count)
            #expect(await cache.snapshot().entryCount == 1, "The completed reply stays retained")
            let front = PreparedMarkdownDocumentCache()
            #expect(front.store(complete, for: message.id), "The front cache retains a windowed reply at the limit")
            #expect(front.shownBytes(for: message.id, revision: message.textRevision) == complete.shownBytes)
        }

        /// Documents handed to views keep their segments while the cache prepares later refreshes.
        @Test func preparedSegmentListsShareUnchangedChunks() async throws {
            let cache = MarkdownSegmentCache(targetBytes: 1, maximumBytes: 1_024)
            let id = UUID()
            let paragraphs = (0..<150).map { "Paragraph \($0)." }
            let first = try #require(
                await cache.prepare(id: id, source: paragraphs.joined(separator: "\n\n"), isComplete: false))
            let firstTexts = first.segments.map(\.text)
            let second = try #require(
                await cache.prepare(
                    id: id, source: paragraphs.joined(separator: "\n\n") + "\n\nMore", isComplete: false))
            #expect(first.segments.map(\.text) == firstTexts, "An earlier document is unchanged")
            #expect(second.segments.count == first.segments.count + 1)

            var list = PreparedSegmentList(first.segments)
            var mirror = Array(first.segments)
            for position in [0, 63, 64, 149] {
                list.set(second.segments[150], at: position)
                mirror[position] = second.segments[150]
            }
            #expect(list.map(\.preparationID) == mirror.map(\.preparationID))
            for cut in [140, 128, 65, 64, 1, 0] {
                list.removeSuffix(from: cut)
                mirror.removeLast(mirror.count - cut)
                #expect(list.map(\.preparationID) == mirror.map(\.preparationID) && list.count == cut)
            }
        }
    }
}

@MainActor private func height<V: View>(_ view: V, width: CGFloat = 600) async throws -> CGFloat {
    let host = NSHostingView(
        rootView: view.frame(width: width, alignment: .leading).environment(AppModel.shared)
            .environment(\.colorScheme, .light))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: 400), styleMask: [.titled], backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer {
        window.contentView = nil
        window.close()
    }
    try await Task.sleep(for: .milliseconds(200))
    host.layoutSubtreeIfNeeded()
    return host.fittingSize.height
}

@MainActor private func wholeReply(_ source: String, fontSize: CGFloat) -> some View {
    Markdown(MarkdownContent(GOATMarkdownSyntax.normalized(source)))
        .markdownImageProvider(BlockedMarkdownImageProvider())
        .markdownInlineImageProvider(BlockedMarkdownInlineImageProvider())
        .goatMarkdownStyle(fontSize: fontSize)
        .textSelection(.enabled)
}

/// Renders through a displayed hosting view after layout settles. `ImageRenderer` can draw MarkdownUI
/// before its preference-driven block margins apply, so its heights vary between runs.
@MainActor private func caretPixels(_ document: PreparedMarkdownDocument, streaming: Bool) async throws
    -> NSBitmapImageRep
{
    let host = NSHostingView(
        rootView: SegmentedMarkdownView(document: document, fontSize: 14, isStreaming: streaming)
            .frame(width: 500, alignment: .leading).padding(10).background(.white)
            .environment(AppModel.shared).environment(\.colorScheme, .light))
    host.appearance = NSAppearance(named: .aqua)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.titled], backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer {
        window.contentView = nil
        window.close()
    }
    try await Task.sleep(for: .milliseconds(300))
    window.setContentSize(host.fittingSize)
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    return bitmap
}

extension AppTests.Bleet {
    /// Segmented rendering lays out as the whole reply does, before and after completion (#60 A1, A2).
    @Suite(.serialized) struct SegmentedMarkdownRenderingTests {

        /// Boundary crossings: with a boundary before every block, each streamed prefix renders at the
        /// height of the same prefix rendered as one document.
        @Test @MainActor func segmentsSpaceBlocksAsTheWholeReplyAtEveryBoundary() async throws {
            let fontSize = AppModel.shared.chatFontSize
            for count in [2, 5, 8, mixedBlocks.count] {
                let source = mixedBlocks.prefix(count).joined(separator: "\n\n")
                let cache = MarkdownSegmentCache(targetBytes: 1)
                let document = try #require(await cache.prepare(id: UUID(), source: source, isComplete: false))
                #expect(document.segments.count == count)
                let segmented = try await height(
                    SegmentedMarkdownView(document: document, fontSize: fontSize, isStreaming: true))
                let whole = try await height(wholeReply(source, fontSize: fontSize))
                #expect(abs(segmented - whole) < 1, "\(count) blocks: segmented \(segmented) pt, whole \(whole) pt")
            }
        }

        /// #60 A1: margins come from the parsed blocks, reduced over each block's subtree as MarkdownUI
        /// does, so shapes whose first or last line misleads still space as the whole reply.
        @Test(arguments: [
            ["> # Quoted title\n> quoted text", "After the quote."],
            ["Before.", "> \(fence)\n> code only\n> \(fence)", "After."],
            ["> outer\n>\n> > nested quote", "A paragraph."],
            ["- item\n\n  ---\n\n- next item", "A paragraph."],
            ["# Heading", "- a\n- b", "---", "Text after a break."],
            ["\(fence)\ncode\n\(fence)", "> quoted", "\(fence)\nmore code\n\(fence)"],
            ["<div>html block</div>", "Text.", "- [ ] a task", "Setext\n---", "Closing."],
            ["1. one\n2. two", "| a | b |\n| - | - |\n| 1 | 2 |", "## Section", "- \(fence)\n  code\n  \(fence)"],
        ])
        @MainActor func parsedMarginsSpaceShapesAsTheWholeReply(blocks: [String]) async throws {
            let fontSize = AppModel.shared.chatFontSize
            let source = blocks.joined(separator: "\n\n")
            let document = try #require(
                await MarkdownSegmentCache(targetBytes: 1).prepare(id: UUID(), source: source, isComplete: true))
            #expect(document.segments.count == blocks.count, "One segment per top-level block")
            let segmented = try await height(
                SegmentedMarkdownView(document: document, fontSize: fontSize, isStreaming: false))
            let whole = try await height(wholeReply(source, fontSize: fontSize))
            #expect(abs(segmented - whole) < 1, "Segmented \(segmented) pt, whole \(whole) pt")
        }

        /// Pieces of one oversized block join without a gap. They are not the whole block (a split
        /// paragraph ends its line early; each code piece has its own chrome), so this checks the gap
        /// rather than the height.
        @Test func continuationPiecesJoinWithoutAGap() async throws {
            let paragraph = String(repeating: "word ", count: 400)
            let document = try #require(
                await MarkdownSegmentCache(targetBytes: 256, maximumBytes: 512).prepare(
                    id: UUID(), source: "Intro.\n\n" + paragraph, isComplete: true))
            let pieces = document.segments.filter(\.continuesPrevious)
            #expect(!pieces.isEmpty)
            for piece in pieces {
                let previous = document.segments[piece.index - 1]
                #expect(MarkdownSegmentSpacing.gap(after: previous, before: piece, fontSize: 14) == 0)
            }
        }

        /// Completion without reflow: a two-segment reply keeps its height when it completes.
        @Test @MainActor func completingASegmentedReplyKeepsItsHeight() async throws {
            let message = ChatMessage(role: .assistant)
            var reply = ""
            var paragraph = 0
            while reply.utf8.count < 7_400 {
                reply += "Paragraph \(paragraph) of a reply that crosses a segment boundary while it streams.\n\n"
                paragraph += 1
            }
            message.text = String(reply.utf8.prefix(3_000)) ?? reply
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(
                rootView: StreamingMarkdownView(message: message).frame(width: 600).environment(AppModel.shared))
            window.contentView = host
            defer {
                window.contentView = nil
                window.close()
            }
            try await Task.sleep(for: .milliseconds(400))
            message.text = reply
            message.markRenderChanged()
            try await Task.sleep(for: .milliseconds(600))
            host.layoutSubtreeIfNeeded()
            let streaming = host.fittingSize.height
            let prepared = try #require(PreparedMarkdownDocumentCache.shared.latest(for: message.id))
            #expect(prepared.source == reply && prepared.segments.count == 2)

            message.complete = true
            try await Task.sleep(for: .milliseconds(400))
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.height == streaming, "Completion must not reflow a segmented reply")
            #expect(
                PreparedMarkdownDocumentCache.shared.document(for: message.id, revision: message.textRevision)?
                    .isComplete == true)
        }

        /// #60 B1: the caret marks only the end of the reply, in its final line, including when earlier
        /// paragraphs end with the same text.
        @Test(arguments: [
            "First paragraph of the answer.\n\n- a list item\n\nThe final streamed line",
            "First paragraph of the answer.\n\nA second paragraph.\n\n- a list item\n- the final streamed item",
            "Done.\n\nDone.\n\nDone.", "done.\n\nAll done.", "- Done.\n\n> Done.\n\nDone.",
        ])
        @MainActor func streamingCaretMarksOnlyTheFinalLine(source: String) async throws {
            // One tail segment holding three paragraphs: only the last one carries the caret.
            let document = try #require(
                await MarkdownSegmentCache().prepare(id: UUID(), source: source, isComplete: false))
            #expect(document.segments.count == 1)
            let streaming = try await caretPixels(document, streaming: true)
            let complete = try await caretPixels(document, streaming: false)
            #expect(
                streaming.pixelsHigh == complete.pixelsHigh,
                "The caret never changes layout: \(streaming.pixelsHigh) vs \(complete.pixelsHigh)")
            var changed: [Int] = []
            for y in 0..<min(streaming.pixelsHigh, complete.pixelsHigh) {
                for x in 0..<min(streaming.pixelsWide, complete.pixelsWide)
                where streaming.colorAt(x: x, y: y) != complete.colorAt(x: x, y: y) {
                    changed.append(y)
                }
            }
            let lowest = try #require(changed.min())
            let highest = try #require(changed.max())
            let rows = lowest...highest
            let scale = CGFloat(streaming.pixelsHigh) / streaming.size.height
            #expect(CGFloat(rows.count) < 30 * scale, "One caret, one line tall: rows \(rows)")
            #expect(
                CGFloat(rows.upperBound) > CGFloat(streaming.pixelsHigh) - 40 * scale,
                "The caret sits on the final line: rows \(rows)")
        }

        /// #60 B1: a tail ending in code, a heading or a table shows no caret, even on an earlier
        /// paragraph whose text matches the ending.
        @Test(arguments: [
            "Done.\n\n\(fence)\nDone.\n\(fence)", "Done.\n\n# Done.", "Done.\n\n| Done. |\n| --- |\n| Done. |",
        ])
        @MainActor func streamingCaretSkipsTailsThatDoNotEndInProse(source: String) async throws {
            let document = try #require(
                await MarkdownSegmentCache().prepare(id: UUID(), source: source, isComplete: false))
            #expect(document.segments.count == 1)
            let streaming = try await caretPixels(document, streaming: true)
            let complete = try await caretPixels(document, streaming: false)
            #expect(streaming.pixelsHigh == complete.pixelsHigh)
            // Rows of the leading paragraph: its own rendering, less the bottom padding.
            let prose = try #require(
                await MarkdownSegmentCache().prepare(id: UUID(), source: "Done.", isComplete: true))
            let proseImage = try await caretPixels(prose, streaming: false)
            let scale = CGFloat(proseImage.pixelsHigh) / proseImage.size.height
            let proseRows = proseImage.pixelsHigh - Int(10 * scale)
            for y in 0..<proseRows {
                for x in 0..<min(streaming.pixelsWide, complete.pixelsWide)
                where streaming.colorAt(x: x, y: y) != complete.colorAt(x: x, y: y) {
                    Issue.record("The leading paragraph changed at \(x), \(y)")
                    return
                }
            }
        }
    }
}

/// Reply shapes for the whole-path preparation workload (#60 A1).
enum PreparationShape: String, CaseIterable, CustomStringConvertible {
    case mixed, paragraphs, fences, tables, lateDefinitions

    var description: String { rawValue }

    func reply(bytes: Int) -> String {
        var reply = ""
        var index = 0
        while reply.utf8.count < bytes {
            reply += block(index)
            index += 1
        }
        if self == .lateDefinitions {
            // Definitions arrive at the end, as they usually do, changing every settled segment
            // that references them.
            reply += (0..<16).map { "[ref \($0)]: https://example.com/\($0)" }.joined(separator: "\n") + "\n"
        }
        return reply
    }

    private func block(_ index: Int) -> String {
        switch self {
        case .mixed:
            return longReply(bytes: 2_048) + "\n\n"
        case .paragraphs:
            // One long line per paragraph, as models often emit.
            return String(repeating: "A sentence that keeps a long paragraph going \(index). ", count: 60) + "\n\n"
        case .fences:
            // Mostly segment-sized fences, and every eighth one larger than a segment.
            let lines = index % 8 == 7 ? 1_200 : 120
            return "\(fence)swift\n" + (0..<lines).map { "let value\($0) = \(index) // line" }.joined(separator: "\n")
                + "\n\(fence)\n\n"
        case .tables:
            let rows = index % 8 == 7 ? 1_500 : 60
            return "| Name | Value | Note |\n| --- | ---: | --- |\n"
                + (0..<rows).map { "| row \($0) | \(index) | text |" }.joined(separator: "\n") + "\n\n"
        case .lateDefinitions:
            return "Paragraph \(index) cites [a source][ref \(index % 16)] and continues with plain words. "
                + String(repeating: "More words follow. ", count: 12) + "\n\n"
        }
    }
}

extension AppTests.Bleet {
    /// #60 A1: the whole preparation path (scanning, copying, comparing, parsing, assembling,
    /// placing the caret and handing documents to the main actor) at a fixed refresh cadence, for
    /// replies from 32 KiB to 2 MiB. This measures the preparation layer, not live rendering: the
    /// live view still uses the 8 KiB parts fallback. Counters are asserted; durations are printed as
    /// `SEGMENT_PREPARATION` records for profiles.
    @Suite(.serialized) struct SegmentPreparationWorkloadTests {

        @Test(arguments: PreparationShape.allCases)
        @MainActor func wholePreparationPathWorkIsLinearInTheReply(shape: PreparationShape) async throws {
            var ratios: [Int: Double] = [:]
            for kibibytes in [32, 128, 512, 2_048] {
                let result = try await measure(shape: shape, bytes: kibibytes * 1_024)
                ratios[kibibytes] = result.workPerByte
                #expect(result.maximumVisited <= 12, "\(shape) \(kibibytes) KiB visited \(result.maximumVisited)")
            }
            let small = try #require(ratios[32])
            let large = try #require(ratios[2_048])
            // 64 times the reply: linear work keeps work per reply byte flat, quadratic work would
            // multiply it by 64.
            #expect(large < small * 1.5, "\(shape) work per reply byte: \(ratios.sorted { $0.key < $1.key })")
        }

        private struct Result {
            let workPerByte: Double
            let maximumVisited: Int
        }

        @MainActor private func measure(shape: PreparationShape, bytes: Int) async throws -> Result {
            // Budgets large enough to retain the reply, so the measurement covers the retained path.
            let cache = MarkdownSegmentCache(
                maximumCost: 64 * 1_024 * 1_024, maximumEntryCost: 64 * 1_024 * 1_024)
            let front = PreparedMarkdownDocumentCache(
                maximumTotalCost: 64 * 1_024 * 1_024, maximumEntryCost: 64 * 1_024 * 1_024)
            let message = ChatMessage(role: .assistant)
            let reply = shape.reply(bytes: bytes)
            let clock = ContinuousClock()
            var refreshTimes: [Duration] = []
            var mainActorTimes: [Duration] = []
            for chunk in chunks(of: reply, bytes: 4_096) {
                message.appendStream(text: chunk, thinking: "")
                let started = clock.now
                let document = try #require(
                    await cache.prepare(
                        id: message.id, source: message.text, revision: message.textRevision, isComplete: false))
                refreshTimes.append(clock.now - started)
                let handed = clock.now
                front.store(document, for: message.id)
                _ = front.renderedBytes(for: message.id, revision: message.textRevision)
                mainActorTimes.append(clock.now - handed)
            }
            let streaming = await cache.snapshot()
            #expect(streaming.streamCount == 1, "The scanner must be retained for this measurement")
            _ = try #require(
                await cache.prepare(
                    id: message.id, source: message.text, revision: message.textRevision, isComplete: true))
            let work = await cache.snapshot().work
            let document = try #require(front.latest(for: message.id))

            // Completion that trims whitespace starts a new epoch: one pass over the whole reply.
            message.text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimStarted = clock.now
            _ = try #require(
                await cache.prepare(
                    id: message.id, source: message.text, revision: message.textRevision, isComplete: true))
            let trim = clock.now - trimStarted

            refreshTimes.sort()
            mainActorTimes.sort()
            func micros(_ duration: Duration) -> Int { Int(duration / .microseconds(1)) }
            func millis(_ duration: Duration) -> Int { Int(duration / .milliseconds(1)) }
            func percentile(_ values: [Duration], _ p: Double) -> Duration {
                values.isEmpty ? .zero : values[min(values.count - 1, Int(Double(values.count) * p))]
            }
            let replyBytes = reply.utf8.count
            let total =
                streaming.parsedBytes + work.scannedBytes + work.copiedBytes + work.comparedBytes + work.htmlBytes
            print(
                "SEGMENT_PREPARATION shape=\(shape) reply_bytes=\(replyBytes) refreshes=\(work.refreshes) "
                    + "parse_count=\(streaming.parseCount) parsed_bytes=\(streaming.parsedBytes) "
                    + "scanned_bytes=\(work.scannedBytes) copied_bytes=\(work.copiedBytes) "
                    + "compared_bytes=\(work.comparedBytes) html_bytes=\(work.htmlBytes) "
                    + "visited_segments=\(work.visitedSegments) max_visited=\(work.maximumVisitedSegments) "
                    + "definition_visits=\(work.definitionVisits) segments=\(document.segments.count) "
                    + "segmentation_ms=\(millis(work.segmentationTime)) parse_ms=\(millis(work.parseTime)) "
                    + "assembly_ms=\(millis(work.assemblyTime)) "
                    + "refresh_p50_us=\(micros(percentile(refreshTimes, 0.5))) "
                    + "refresh_p95_us=\(micros(percentile(refreshTimes, 0.95))) "
                    + "refresh_max_us=\(micros(refreshTimes.last ?? .zero)) "
                    + "main_actor_p95_us=\(micros(percentile(mainActorTimes, 0.95))) "
                    + "streaming_retained_cost=\(streaming.cost) front_cost=\(front.snapshot().totalCost) "
                    + "completion_trim_ms=\(millis(trim)) work_per_reply_byte=\(Double(total) / Double(replyBytes))")
            return Result(workPerByte: Double(total) / Double(replyBytes), maximumVisited: work.maximumVisitedSegments)
        }
    }
}
