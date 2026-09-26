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
            let id = UUID()
            let streaming = try #require(await segments.prepare(id: id, source: "Partial", isComplete: false))
            #expect(cache.store(streaming, for: id))
            #expect(cache.document(for: id, source: "Partial reply") == nil)
            #expect(cache.latest(for: id)?.source == "Partial")
            #expect(cache.renderedBytes(for: id, source: "Partial") == streaming.renderedBytes)
            let large = try #require(
                await segments.prepare(id: id, source: String(repeating: "x", count: 100), isComplete: true))
            #expect(!cache.store(large, for: id))
            #expect(cache.latest(for: id) == nil, "A declined store drops the older document")
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
                    id: message.id, source: message.text, isComplete: true))
            PreparedMarkdownDocumentCache.shared.store(document, for: message.id)
            #expect(TranscriptWindow.displayCost(message) == document.renderedBytes)
            message.text += "\n\nMore."
            #expect(TranscriptWindow.displayCost(message) == message.text.utf8.count)
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
            #expect(PreparedMarkdownDocumentCache.shared.document(for: message.id, source: reply)?.isComplete == true)
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
