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

private func indented(_ text: String, by prefix: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.isEmpty ? "" : prefix + $0 }.joined(separator: "\n")
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

/// Grows `source` in place by `step` bytes (on scalar boundaries), checking every step.
@discardableResult
private func stream(
    _ source: String, step: Int, target: Int, maximum: Int,
    check: (MarkdownSegmentation, Int) -> Void = { _, _ in }
) -> (result: MarkdownSegmentation, steps: Int) {
    let bytes = Array(source.utf8)
    var segmentation = MarkdownSegmentation(targetBytes: target, maximumBytes: maximum)
    var length = 0
    var steps = 0
    while length < bytes.count {
        length = min(bytes.count, length + step)
        while length < bytes.count, bytes[length] & 0xC0 == 0x80 { length += 1 }
        segmentation.extend(to: String(decoding: bytes[0..<length], as: UTF8.self), isComplete: false)
        steps += 1
        check(segmentation, length)
    }
    segmentation.extend(to: source, isComplete: true)
    return (segmentation, steps)
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
        // The loose list stays one block: its continuation and its second item stay with it.
        #expect(
            result.segments.contains {
                $0.body.hasPrefix("- first item\n\n  continued") && $0.body.contains("- second item")
            })
        // Blank lines inside fenced code, HTML comments and display math are not boundaries.
        #expect(result.segments.contains { $0.body.hasPrefix("\(fence)swift") && $0.body.contains("\(fence)\n") })
        #expect(result.segments.contains { $0.body.contains("<!-- note\n\nstill a comment\n-->") })
        #expect(result.segments.contains { $0.body.contains("$$\nx = 1\n\ny = 2\n$$") })
    }

    @Test func looseListsStayWholeAndOtherListsStartBlocks() {
        func bodies(_ source: String) -> [String] {
            MarkdownSegmenter.segment(source, isComplete: true, targetBytes: 1, maximumBytes: 4_096).segments.map(
                \.body)
        }
        #expect(bodies("- a\n\n- b\n\n  more b\n\n- c\n").count == 1)
        #expect(bodies("1. a\n\n2. b\n\n3. c\n").count == 1)
        #expect(
            bodies("- a\n  ```\n  code\n  ```\n- b\n").count == 1, "An item after a nested fence continues the list")
        #expect(bodies("- a\n\n* b\n") == ["- a\n\n", "* b\n"], "A different bullet starts a new list")
        #expect(bodies("1. a\n\n2) b\n") == ["1. a\n\n", "2) b\n"])
        #expect(bodies("- a\n\n- - -\n") == ["- a\n\n", "- - -\n"], "A thematic break is not an item")
        #expect(bodies("- a\n\nAfter.\n") == ["- a\n\n", "After.\n"])
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
            #expect(piece.body.hasSuffix("\(fence)\n"))
            #expect(piece.continuesPrevious == (offset > 0))
            recovered += codeLines(of: piece.body)
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
        #expect(pieces.dropLast().allSatisfy { $0.isSettled })
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
        let streamed = stream(svg, step: 3, target: 64, maximum: 256) { partial, _ in
            #expect(partial.count == 1)
            #expect(partial.allSatisfy { !$0.isSettled })
        }
        #expect(streamed.result == result)
    }

    @Test func referenceDefinitionsResolveInEverySegment() {
        let result = MarkdownSegmenter.segment(mixedReply, isComplete: true, targetBytes: 64, maximumBytes: 1_024)
        #expect(result.segments.count > 2)
        for segment in result.segments {
            #expect(segment.text.hasSuffix("[guide]: https://example.com/guide\n"))
            #expect(segment.text.hasPrefix(segment.body))
        }
        // A definition continuing a paragraph is paragraph text, not a definition.
        let lazy = MarkdownSegmenter.segment("Text\n[a]: https://a.example\n", isComplete: true)
        #expect(lazy.segments.allSatisfy { $0.definitionSuffix.isEmpty })
    }

    // MARK: Bounds on syntax overhead (review finding 1)

    @Test func longFenceOpenersStayWithinTheMaximum() {
        let maximum = MarkdownSegmenter.maximumBytes
        let codeBody = code(lines: 900)  // about 45 KiB
        // An info string over the syntax budget keeps only its language.
        let longInfo = MarkdownSegmenter.segment(
            "\(fence)swift \(String(repeating: "i", count: 10_000))\n\(codeBody)\(fence)\n", isComplete: true)
        expectTiling(longInfo)
        #expect(longInfo.count > 2)
        for piece in longInfo {
            #expect(piece.kind == .fencedCodePiece)
            #expect(piece.body.utf8.count <= maximum)
            #expect(piece.body.hasPrefix("\(fence)swift\n"))
        }
        #expect(longInfo.map { codeLines(of: $0.body) }.joined() == codeBody)
        // The reviewer's case: a 17,000-byte opener is longer than a segment, so it has no syntax.
        let overLong = MarkdownSegmenter.segment(
            "\(fence)\(String(repeating: "i", count: 17_000))\n\(codeBody)\(fence)\n", isComplete: true)
        expectTiling(overLong)
        #expect(overLong.allSatisfy { $0.body.utf8.count <= maximum })
        #expect(overLong.dropLast().allSatisfy { $0.kind == .blockPiece })
        #expect(overLong.last?.body == "\(fence)\n", "The closing line now opens a fence of its own")
        // A marker run over the budget cannot be rebuilt: verbatim pieces.
        let run = String(repeating: "`", count: 5_000)
        let longRun = MarkdownSegmenter.segment("\(run)\n\(codeBody)\(run)\n", isComplete: true)
        expectTiling(longRun)
        #expect(longRun.count > 2)
        for piece in longRun {
            #expect(piece.kind == .verbatimPiece)
            #expect(piece.body.utf8.count <= maximum)
            #expect(piece.definitionSuffix.isEmpty)
        }
    }

    @Test func tableHeadersOverTheSyntaxBudgetBecomeVerbatim() {
        let maximum = 1_024
        let columns = 60
        let header = "|" + (0..<columns).map { " column \($0) |" }.joined() + "\n"
        let delimiter = "|" + String(repeating: " --- |", count: columns) + "\n"
        let rows =
            (0..<40).map { row in "|" + (0..<columns).map { " \(row)x\($0) |" }.joined() }
            .joined(separator: "\n") + "\n"
        #expect(header.utf8.count + delimiter.utf8.count > maximum / 4)
        let result = MarkdownSegmenter.segment(
            header + delimiter + rows, isComplete: true, targetBytes: 256, maximumBytes: maximum)
        expectTiling(result)
        #expect(result.count > 2)
        for piece in result {
            #expect(piece.kind == .verbatimPiece)
            #expect(piece.body.utf8.count <= maximum)
        }
    }

    // MARK: Nested containers (review finding 2)

    /// The reviewer's case: a fence inside a list item, far larger than a segment.
    @Test func oversizedFenceInAListItemIsRebuiltInEveryPiece() {
        let source = "- item\n\n  \(fence)\n" + String(repeating: "  let x = 1\n", count: 2_000) + "  \(fence)\n"
        let result = MarkdownSegmenter.segment(source, isComplete: true)
        expectTiling(result)
        #expect(result.first?.body == "- item\n\n")
        #expect(result.first?.kind == .blockPiece)
        let pieces = result.dropFirst()
        #expect(pieces.count >= 2)
        var lines = 0
        for piece in pieces {
            #expect(piece.kind == .fencedCodePiece)
            #expect(piece.continuesPrevious)
            #expect(piece.body.utf8.count <= MarkdownSegmenter.maximumBytes)
            #expect(piece.body.hasPrefix("\(fence)\nlet x = 1\n"))
            #expect(piece.body.hasSuffix("let x = 1\n\(fence)\n"))
            let code = codeLines(of: piece.body).split(separator: "\n")
            #expect(code.allSatisfy { $0 == "let x = 1" })
            lines += code.count
        }
        #expect(lines == 2_000)
    }

    @Test func deeplyNestedAndListMarkerFencesAreRebuilt() {
        let codeBody = code(lines: 60, width: 20)
        let deep = "- outer\n  - inner\n\n    ~~~js\n" + indented(codeBody, by: "    ") + "    ~~~\n"
        let marker = "1. " + fence + "js\n" + indented(codeBody, by: "   ") + "   " + fence + "\n"
        for source in [deep, marker] {
            let result = MarkdownSegmenter.segment(source, isComplete: true, targetBytes: 128, maximumBytes: 512)
            expectTiling(result)
            let pieces = result.filter { $0.kind == .fencedCodePiece }
            #expect(pieces.count > 2)
            #expect(
                pieces.allSatisfy {
                    $0.body.utf8.count <= 512 && $0.body.hasPrefix(source == deep ? "~~~js\n" : "\(fence)js\n")
                })
            #expect(pieces.map { codeLines(of: $0.body) }.joined() == codeBody, "Indentation is removed, code kept")
        }
    }

    @Test func oversizedQuotedFencesAndHTMLBecomeVerbatim() {
        let quoted = "> Quote:\n>\n> \(fence)\n" + indented(code(lines: 60, width: 20), by: "> ") + "> \(fence)\n"
        let comment = "- item\n\n  <!--\n" + indented(code(lines: 60, width: 20, blankEvery: 5), by: "  ") + "  -->\n"
        for source in [quoted, comment] {
            let result = MarkdownSegmenter.segment(source, isComplete: true, targetBytes: 128, maximumBytes: 512)
            expectTiling(result)
            let verbatim = result.filter { $0.kind == .verbatimPiece }
            #expect(verbatim.count > 2)
            for piece in result {
                #expect(piece.body.utf8.count <= 512)
                if piece.kind == .verbatimPiece {
                    #expect(Array(piece.body.utf8) == Array(Array(source.utf8)[piece.sourceRange]))
                }
            }
        }
    }

    @Test func oversizedListPiecesNeverCutInsideANestedFenceThatFits() {
        let items = (0..<30).map { "- item \($0) " + String(repeating: "w ", count: 20) }.joined(separator: "\n")
        let nested =
            "- code item\n\n  \(fence)\n" + indented(code(lines: 6, width: 10, blankEvery: 2), by: "  ")
            + "  \(fence)\n"
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

    // MARK: Streaming

    /// Streaming growth: every prefix, extended incrementally, equals a full pass, and a settled
    /// segment never changes its identity, range or body afterwards.
    @Test(arguments: [7, 61, 509]) func growthIsStableAndIncrementalMatchesFullPass(step: Int) {
        let source =
            mixedReply + "\(fence)swift\n" + code(lines: 60) + "\(fence)\n\n" + paragraph("tail", bytes: 2_500)
            + "- item\n\n  \(fence)\n" + indented(code(lines: 40), by: "  ") + "  \(fence)\n"
        expectStableGrowth(source, step: step, target: 256, maximum: 1_024)
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
        // A shorter source, and a rewrite of the undecided final line, both start over.
        let streaming = mixedReply + "Final line being typ"
        let first = MarkdownSegmenter.segment(streaming, isComplete: false, targetBytes: 256, maximumBytes: 1_024)
        for replaced in ["Different reply.\n", mixedReply + "Final line rewritten, and longer"] {
            #expect(
                MarkdownSegmenter.resegment(first, source: replaced, isComplete: false)
                    == MarkdownSegmenter.segment(replaced, isComplete: false, targetBytes: 256, maximumBytes: 1_024))
        }
    }

    /// Randomised documents: structural invariants that do not depend on the scanner, and
    /// incremental results equal to full passes at random step sizes.
    @Test(arguments: 0..<16) func randomDocumentsKeepEveryInvariant(seed: Int) {
        var random = SeededRandom(seed: UInt64(seed + 1))
        let limits = [(64, 256), (256, 1_024), (1_024, 4_096)][seed % 3]
        let source = randomDocument(&random, blocks: 14, scale: limits.1)
        let result = MarkdownSegmenter.segment(source, isComplete: true, targetBytes: limits.0, maximumBytes: limits.1)
        expectInvariants(result, maximum: limits.1)
        let step = 1 + random.below(max(8, source.utf8.count / 60))
        expectStableGrowth(source, step: step, target: limits.0, maximum: limits.1)
    }

    // MARK: Work (review finding 3)

    /// The scanner's own work, measured: bytes read plus bytes copied stay linear in the reply,
    /// whatever its shape, when it grows by fixed appends.
    @Test(arguments: WorkShape.allCases) func segmentationWorkIsLinearInTheReply(shape: WorkShape) {
        var totals: [Int] = []
        for kibibytes in [32, 64, 128] {
            let source = shape.source(bytes: kibibytes * 1_024)
            let length = source.utf8.count
            for step in [257, 1_024] {
                let run = stream(
                    source, step: step, target: MarkdownSegmenter.targetBytes, maximum: MarkdownSegmenter.maximumBytes)
                // Every byte is read and copied a bounded number of times, and each append rereads
                // at most a tail bounded by the segment maximum.
                let bound = 16 * length + run.steps * 10 * MarkdownSegmenter.maximumBytes
                #expect(run.result.work.totalBytes <= bound, "\(shape) \(kibibytes) KiB by \(step)")
                if step == 1_024 { totals.append(run.result.work.totalBytes) }
            }
        }
        // Doubling the reply at most slightly more than doubles the work (quadratic work would
        // quadruple it).
        #expect(Double(totals[1]) / Double(totals[0]) < 2.4, "\(shape): \(totals)")
        #expect(Double(totals[2]) / Double(totals[1]) < 2.4, "\(shape): \(totals)")
    }

    /// What step 2 must re-prepare per append: the unsettled segments stay within a few segment
    /// maxima, however long the reply grows.
    @Test func unsettledBytesStayBoundedWhileStreaming() {
        for shape in WorkShape.allCases {
            let source = shape.source(bytes: 96 * 1_024)
            stream(source, step: 257, target: MarkdownSegmenter.targetBytes, maximum: MarkdownSegmenter.maximumBytes) {
                partial, length in
                let unsettled = partial.filter { !$0.isSettled }.reduce(0) { $0 + $1.body.utf8.count }
                #expect(unsettled <= 3 * MarkdownSegmenter.maximumBytes, "\(shape) at \(length)")
            }
        }
    }
}

// MARK: - Helpers

/// Code lines of a fence piece: everything between its opening and closing fence lines.
private func codeLines(of body: String) -> String {
    var lines = body.components(separatedBy: "\n")
    lines.removeFirst()
    if lines.last == "" { lines.removeLast() }
    if let last = lines.last, last.hasPrefix(fence) || last.hasPrefix("~~~") { lines.removeLast() }
    return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
}

private func expectStableGrowth(_ source: String, step: Int, target: Int, maximum: Int) {
    var settled: [Int: MarkdownSegment] = [:]
    let bytes = Array(source.utf8)
    let run = stream(source, step: step, target: target, maximum: maximum) { partial, length in
        let prefix = String(decoding: bytes[0..<length], as: UTF8.self)
        let full = MarkdownSegmenter.segment(prefix, isComplete: false, targetBytes: target, maximumBytes: maximum)
        #expect(partial == full, "Incremental result differs at \(length) bytes (step \(step))")
        expectTiling(partial, "at \(length) bytes")
        for segment in partial {
            if let earlier = settled[segment.index] {
                #expect(
                    segment.sourceRange == earlier.sourceRange && segment.body == earlier.body
                        && segment.kind == earlier.kind,
                    "Settled \(segment.index) changed at \(length) bytes")
            }
            if segment.isSettled { settled[segment.index] = segment }
        }
    }
    #expect(
        run.result == MarkdownSegmenter.segment(source, isComplete: true, targetBytes: target, maximumBytes: maximum))
    #expect(run.result.allSatisfy { $0.isSettled })
}

/// Invariants checked against the source, not against the scanner's own decisions.
private func expectInvariants(_ result: MarkdownSegmentation, maximum: Int) {
    expectTiling(result)
    let source = Array(result.source.utf8)
    for segment in result {
        let raw = Array(source[segment.sourceRange])
        #expect(segment.body.utf8.count <= maximum, "segment \(segment.index) over the maximum")
        switch segment.kind {
        case .blocks, .blockPiece, .verbatimPiece:
            #expect(Array(segment.body.utf8) == raw, "segment \(segment.index) is not its source")
        case .fencedCodePiece:
            let lines = segment.body.components(separatedBy: "\n")
            let opener = lines.first ?? ""
            #expect(opener.hasPrefix("```") || opener.hasPrefix("~~~"), "piece \(segment.index) has no fence")
            let marker = String(opener.prefix { $0 == opener.first })
            let fenceLines = lines.dropFirst().filter { $0.hasPrefix(marker) && $0.allSatisfy { $0 == opener.first } }
            #expect(fenceLines.count <= 1, "piece \(segment.index) closes more than once")
        case .tablePiece:
            #expect(segment.body.split(separator: "\n").dropFirst().first?.contains("-") == true)
        }
        if segment.index > 0, segment.kind == .blocks {
            // Whole-block segments start at column 0, after a blank line or a container.
            #expect(![UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\t")].contains(raw.first ?? 0))
        }
    }
}

enum WorkShape: String, CaseIterable, CustomTestStringConvertible, Sendable {
    /// One paragraph on a single line: every append lands in one long line.
    case unbrokenLine
    /// One paragraph of short lines with no blank line: one ever-growing block.
    case paragraph
    /// One fenced code block.
    case fence
    /// A fence nested in a list item.
    case nestedFence
    /// One table.
    case table
    /// A mixed reply, repeated.
    case mixed

    var testDescription: String { rawValue }

    func source(bytes: Int) -> String {
        var text: String
        switch self {
        case .unbrokenLine:
            text = "Start"
            while text.utf8.count < bytes { text += " word" }
        case .paragraph:
            text = ""
            while text.utf8.count < bytes { text += "A line of prose that wraps onto the next line of prose\n" }
        case .fence:
            text = "```swift\n"
            while text.utf8.count < bytes { text += "let value = \"\(String(repeating: "x", count: 40))\"\n" }
        case .nestedFence:
            text = "- item\n\n  ```\n"
            while text.utf8.count < bytes { text += "  let value = \"\(String(repeating: "x", count: 40))\"\n" }
        case .table:
            text = "| Name | Value |\n| --- | --- |\n"
            while text.utf8.count < bytes { text += "| row | \(String(repeating: "v", count: 30)) |\n" }
        case .mixed:
            text = ""
            while text.utf8.count < bytes { text += mixedReply + "\n" }
        }
        return text
    }
}

private struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(max(1, bound))) }
}

/// A document of random blocks, some larger than a segment, some nested, some multibyte.
private func randomDocument(_ random: inout SeededRandom, blocks: Int, scale: Int) -> String {
    var parts: [String] = []
    for _ in 0..<blocks {
        let size = 1 + random.below(random.below(4) == 0 ? scale * 3 : scale / 2)
        switch random.below(11) {
        case 0: parts.append(paragraph("p", bytes: max(20, size)))
        case 1: parts.append(String(repeating: "wörd🐐 ", count: max(1, size / 12)) + "\n")
        case 2:
            parts.append("\(fence)swift\n" + code(lines: max(1, size / 50), width: 30, blankEvery: 3) + "\(fence)\n")
        case 3:
            parts.append("~~~\n" + code(lines: max(1, size / 50), width: 30) + (random.below(3) == 0 ? "" : "~~~\n"))
        case 4:
            parts.append(
                "| a | b |\n| - | - |\n" + (0..<max(1, size / 20)).map { "| \($0) | v |" }.joined(separator: "\n")
                    + "\n")
        case 5:
            parts.append(
                "- item\n\n  \(fence)\n" + indented(code(lines: max(1, size / 50), width: 30), by: "  ")
                    + "  \(fence)\n")
        case 6: parts.append((0..<max(1, size / 30)).map { "- item \($0) with words" }.joined(separator: "\n\n") + "\n")
        case 7: parts.append("> " + (0..<max(1, size / 30)).map { "quoted \($0)" }.joined(separator: "\n> ") + "\n")
        case 8: parts.append("<!--\n" + code(lines: max(1, size / 50), width: 30, blankEvery: 4) + "-->\n")
        case 9: parts.append("[ref\(random.below(5))]: https://example.com/\(random.below(100))\n")
        default: parts.append("# Heading \(random.below(100))\n")
        }
    }
    return parts.joined(separator: random.below(2) == 0 ? "\n" : "\n\n")
}
