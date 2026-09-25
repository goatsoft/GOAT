import Foundation
import Testing

@testable import Bleet

private let fence = "```"

private func paragraph(_ label: String, bytes: Int) -> String {
    var text = "Paragraph \(label):"
    while text.utf8.count < bytes - 1 { text += " words" }
    return text + "\n"
}

private func code(lines: Int, width: Int = 40, blankEvery: Int = 0) -> String {
    (0..<lines).map { index in
        blankEvery > 0 && index % blankEvery == blankEvery - 1
            ? "" : "let value\(index) = \"" + String(repeating: "x", count: width) + "\""
    }.joined(separator: "\n") + "\n"
}

/// A reply mixing every construct the segmenter must respect.
private let mixedReply: String = [
    "# Report\n",
    paragraph("intro", bytes: 300),
    "- first item\n\n  continued inside the first item\n\n- second item\n",
    "\(fence)swift\n" + code(lines: 12, blankEvery: 4) + "\(fence)\n",
    "| Name | Value |\n| --- | ---: |\n| a | 1 |\n| b | 2 |\n",
    "> quoted line\n>\n> quoted again\n",
    "<!-- note\n\nstill a comment\n-->\n",
    "$$\nx = 1\n\ny = 2\n$$\n",
    "See [the guide][guide].\n",
    paragraph("closing", bytes: 400),
    "[guide]: https://example.com/guide\n",
].joined(separator: "\n")

private func expectTiling(_ result: MarkdownSegmentation, _ comment: Comment? = nil) {
    var offset = 0
    for segment in result.segments {
        #expect(segment.sourceRange.lowerBound == offset, comment)
        offset = segment.sourceRange.upperBound
    }
    #expect(offset == result.source.utf8.count, comment)
    #expect(result.segments.map(\.index) == Array(result.segments.indices), comment)
}

private func fenceLineCount(_ text: String) -> Int {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix(fence) }.count
}

@Suite struct MarkdownSegmenterTests {

    @Test func segmentsTileTheSourceAndPackWholeBlocks() {
        let result = MarkdownSegmenter.segment(mixedReply, isComplete: true, targetBytes: 256, maximumBytes: 1_024)
        expectTiling(result)
        #expect(result.segments.count > 1)
        for segment in result.segments {
            #expect(segment.kind == .blocks)
            #expect(segment.body.utf8.count <= 1_024)
            #expect(segment.isSettled)
            // Fenced code, multi-line HTML and display math are never cut when they fit.
            #expect(fenceLineCount(segment.body).isMultiple(of: 2), "fence split in \(segment.index)")
            #expect(segment.body.contains("<!--") == segment.body.contains("-->"))
            #expect(segment.body.components(separatedBy: "$$").count != 2)
        }
    }

    @Test func boundariesOnlyPrecedeColumnZeroBlocks() {
        let result = MarkdownSegmenter.segment(mixedReply, isComplete: true, targetBytes: 1, maximumBytes: 4_096)
        let bytes = Array(mixedReply.utf8)
        for segment in result.segments.dropFirst() {
            let start = segment.sourceRange.lowerBound
            #expect(bytes[start] != UInt8(ascii: " ") && bytes[start] != UInt8(ascii: "\n"))
        }
        // The indented continuation stays with its list item.
        #expect(result.segments.contains { $0.body.contains("- first item\n\n  continued inside the first item") })
        // Blank lines inside fenced code, HTML comments and display math are not boundaries.
        #expect(result.segments.contains { $0.body.hasPrefix("\(fence)swift") && $0.body.contains("\(fence)\n") })
        #expect(result.segments.contains { $0.body.contains("<!-- note\n\nstill a comment\n-->") })
        #expect(result.segments.contains { $0.body.contains("$$\nx = 1\n\ny = 2\n$$") })
    }

    @Test func oversizedFencedCodeRepeatsItsFenceInEveryPiece() {
        let body = code(lines: 80)
        let source = "Intro.\n\n\(fence)swift\n\(body)\(fence)\n\nAfter.\n"
        let result = MarkdownSegmenter.segment(source, isComplete: true, targetBytes: 256, maximumBytes: 1_024)
        expectTiling(result)
        let pieces = result.segments.filter { $0.kind == .fencedCodePiece }
        #expect(pieces.count > 2)
        var recovered = ""
        for (offset, piece) in pieces.enumerated() {
            #expect(piece.body.utf8.count <= 1_024)
            #expect(piece.body.hasPrefix("\(fence)swift\n"))
            #expect(piece.body.hasSuffix("\(fence)\n") || piece.body.hasSuffix("\(fence)\n\n"))
            #expect(piece.continuesPrevious == (offset > 0))
            var lines = piece.body.components(separatedBy: "\n")
            lines.removeFirst()
            while let last = lines.last, last.isEmpty || last == fence { lines.removeLast() }
            recovered += lines.joined(separator: "\n") + "\n"
        }
        #expect(recovered == body, "Code lines survive splitting in order")
    }

    @Test func streamingUnterminatedFenceLeavesItsLastPieceOpen() {
        let source = "\(fence)python\n" + code(lines: 80)
        let result = MarkdownSegmenter.segment(source, isComplete: false, targetBytes: 256, maximumBytes: 1_024)
        let pieces = result.segments.filter { $0.kind == .fencedCodePiece }
        #expect(pieces.count > 2)
        for piece in pieces.dropLast() { #expect(piece.body.hasSuffix("\(fence)\n")) }
        #expect(!(pieces.last?.body.contains("\n\(fence)\n") ?? true), "The open fence is not closed early")
        #expect(pieces.last?.isSettled == false)
    }

    @Test func oversizedTableRepeatsItsHeaderInEveryPiece() {
        let rows = (0..<120).map { "| row \($0) | \(String(repeating: "v", count: 20)) |" }.joined(separator: "\n")
        let header = "| Name | Value |\n| --- | --- |\n"
        let source = header + rows + "\n"
        let result = MarkdownSegmenter.segment(source, isComplete: true, targetBytes: 256, maximumBytes: 1_024)
        expectTiling(result)
        let pieces = result.segments.filter { $0.kind == .tablePiece }
        #expect(pieces.count > 2)
        var recovered: [String] = []
        for piece in pieces {
            #expect(piece.body.utf8.count <= 1_024)
            #expect(piece.body.hasPrefix(header))
            recovered += piece.body.dropFirst(header.count).split(separator: "\n").map(String.init)
        }
        #expect(recovered == rows.split(separator: "\n").map(String.init))
    }

    @Test func oversizedParagraphSplitsAtWhitespaceWithinTheLimit() {
        let source = paragraph("long", bytes: 3_000)
        let result = MarkdownSegmenter.segment(source, isComplete: true, targetBytes: 256, maximumBytes: 1_024)
        expectTiling(result)
        #expect(result.segments.count >= 3)
        for (offset, segment) in result.segments.enumerated() {
            #expect(segment.kind == .blockPiece)
            #expect(segment.body.utf8.count <= 1_024)
            #expect(segment.continuesPrevious == (offset > 0))
            if offset < result.segments.count - 1 { #expect(segment.body.hasSuffix(" ")) }
        }
        #expect(result.segments.map(\.body).joined() == source)
    }

    @Test func unbrokenMultibyteTextSplitsOnScalarBoundaries() {
        let source = String(repeating: "é🐐", count: 900)  // no whitespace, no newlines
        let result = MarkdownSegmenter.segment(source, isComplete: true, targetBytes: 64, maximumBytes: 256)
        expectTiling(result)
        for segment in result.segments {
            #expect(segment.body.utf8.count <= 256)
            #expect(
                Array(segment.body.utf8) == Array(Array(source.utf8)[segment.sourceRange]), "No replacement characters")
        }
        #expect(result.segments.map(\.body).joined() == source)
    }

    @Test func artifactDocumentsStayWhole() {
        let svg = "<svg width=\"10\">\n\n" + String(repeating: "<rect/>\n\n", count: 400) + "</svg>\n"
        let result = MarkdownSegmenter.segment(svg, isComplete: true, targetBytes: 64, maximumBytes: 256)
        #expect(result.segments.count == 1)
        #expect(result.segments[0].body == svg)
    }

    @Test func referenceDefinitionsResolveInEverySegment() {
        let result = MarkdownSegmenter.segment(mixedReply, isComplete: true, targetBytes: 64, maximumBytes: 1_024)
        #expect(result.segments.count > 2)
        for segment in result.segments {
            #expect(segment.text.hasSuffix("[guide]: https://example.com/guide\n"))
            #expect(segment.text.hasPrefix(segment.body))
        }
    }

    /// Streaming growth: every prefix, extended incrementally, equals a full pass, and a settled
    /// segment never changes its identity, range or body afterwards.
    @Test(arguments: [7, 61, 509]) func growthIsStableAndIncrementalMatchesFullPass(step: Int) {
        let source = mixedReply + "\(fence)swift\n" + code(lines: 60) + "\(fence)\n\n" + paragraph("tail", bytes: 2_500)
        let bytes = Array(source.utf8)
        var previous = MarkdownSegmenter.segment("", isComplete: false, targetBytes: 256, maximumBytes: 1_024)
        var settled: [Int: (Range<Int>, String)] = [:]
        var length = 0
        while length < bytes.count {
            length = min(bytes.count, length + step)
            // Only cut on scalar boundaries, like a real stream of decoded text.
            while length < bytes.count, bytes[length] & 0xC0 == 0x80 { length += 1 }
            let prefix = String(decoding: bytes[0..<length], as: UTF8.self)
            let full = MarkdownSegmenter.segment(prefix, isComplete: false, targetBytes: 256, maximumBytes: 1_024)
            let incremental = MarkdownSegmenter.resegment(previous, source: prefix, isComplete: false)
            #expect(incremental == full, "Incremental result differs at \(length) bytes")
            expectTiling(full, "at \(length) bytes")
            for segment in full.segments {
                if let (range, body) = settled[segment.index] {
                    #expect(segment.sourceRange == range && segment.body == body, "Settled \(segment.index) moved")
                }
                if segment.isSettled { settled[segment.index] = (segment.sourceRange, segment.body) }
                #expect(segment.body.utf8.count <= 1_024)
            }
            previous = incremental
        }
        let complete = MarkdownSegmenter.resegment(previous, source: source, isComplete: true)
        #expect(complete == MarkdownSegmenter.segment(source, isComplete: true, targetBytes: 256, maximumBytes: 1_024))
        #expect(complete.segments.allSatisfy { $0.isSettled })
    }

    @Test func crossingTheTargetAddsASegmentWithoutMovingTheFirst() {
        var text = paragraph("one", bytes: 200) + "\n"
        let first = MarkdownSegmenter.segment(text, isComplete: false, targetBytes: 256, maximumBytes: 1_024)
        #expect(first.segments.count == 1)
        #expect(first.segments[0].isSettled == false)
        text += paragraph("two", bytes: 200) + "\n"
        text += paragraph("three", bytes: 200)
        let grown = MarkdownSegmenter.resegment(first, source: text, isComplete: false)
        #expect(grown.segments.count == 2)
        #expect(grown.segments[0].isSettled)
        #expect(grown.segments[0].body.hasPrefix("Paragraph one"))
        #expect(grown.segments[1].isSettled == false)
    }

    @Test func nonExtendingSourceFallsBackToAFullPass() {
        let first = MarkdownSegmenter.segment(mixedReply, isComplete: false, targetBytes: 256, maximumBytes: 1_024)
        let replaced = "Different reply.\n"
        #expect(
            MarkdownSegmenter.resegment(first, source: replaced, isComplete: false)
                == MarkdownSegmenter.segment(replaced, isComplete: false, targetBytes: 256, maximumBytes: 1_024))
    }

    /// Segment preparation work grows linearly: across a stream, the bytes in segments that are
    /// new or not yet settled at each step stay within the source plus one segment per step.
    @Test func workPerStreamingStepIsBoundedByOneSegment() {
        let source = String(repeating: mixedReply, count: 6)
        let bytes = Array(source.utf8)
        var previous = MarkdownSegmenter.segment("", isComplete: false, targetBytes: 1_024, maximumBytes: 4_096)
        var seen = Set<Int>()
        var preparedBytes = 0
        var steps = 0
        var length = 0
        while length < bytes.count {
            length = min(bytes.count, length + 97)
            while length < bytes.count, bytes[length] & 0xC0 == 0x80 { length += 1 }
            previous = MarkdownSegmenter.resegment(
                previous, source: String(decoding: bytes[0..<length], as: UTF8.self), isComplete: false)
            for segment in previous.segments where !segment.isSettled || !seen.contains(segment.index) {
                preparedBytes += segment.body.utf8.count
                if segment.isSettled { seen.insert(segment.index) }
            }
            steps += 1
        }
        #expect(preparedBytes <= bytes.count + steps * 4_096)
        // A whole-document approach would have prepared every prefix: quadratic in the source.
        #expect(preparedBytes < steps * bytes.count / 4)
    }
    @Test func oversizedListPiecesNeverCutInsideItsNestedFence() {
        let items = (0..<30).map { "- item \($0) " + String(repeating: "w ", count: 20) }.joined(separator: "\n")
        let nested =
            "- code item\n\n  ```\n"
            + code(lines: 6, width: 10, blankEvery: 2)
            .split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? "" : "  " + $0 }
            .joined(separator: "\n") + "  ```\n"
        let source = items + "\n" + nested + items + "\n"
        let result = MarkdownSegmenter.segment(source, isComplete: true, targetBytes: 256, maximumBytes: 1_024)
        expectTiling(result)
        #expect(result.segments.allSatisfy { $0.kind == .blockPiece })
        for segment in result.segments {
            #expect(segment.body.utf8.count <= 1_024)
            #expect(fenceLineCount(segment.body).isMultiple(of: 2), "nested fence cut in \(segment.index)")
        }
    }

    @Test func singleLineMathAndInnerBacktickRunsDoNotOpenOrCloseContainers() {
        let source = "$$x = 1$$\n\nNext.\n\n~~~markdown\n```swift\n\nlet a = 1\n```\n\nStill inside.\n~~~\n\nAfter.\n"
        let result = MarkdownSegmenter.segment(source, isComplete: true, targetBytes: 1, maximumBytes: 4_096)
        let bodies = result.segments.map(\.body)
        #expect(bodies.first == "$$x = 1$$\n\n", "Single-line math closes itself")
        #expect(bodies.contains { $0.hasPrefix("~~~markdown") && $0.contains("Still inside.\n~~~") })
        #expect(bodies.last == "After.\n")
    }
}
