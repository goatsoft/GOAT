import Foundation

/// One independently renderable part of a Markdown reply.
///
/// `index` is the segment's identity. It depends only on the bytes before the segment, so it stays
/// the same while the reply grows. `text` is what to render. It usually equals the source bytes in
/// `sourceRange`, but differs for pieces of an oversized block (which repeat a fence opener or a
/// table header so each piece is valid Markdown) and when reference-style link definitions are
/// appended. A settled segment's range never changes, but its `text` can when a later definition
/// arrives, so consumers compare `text` before reusing prepared content.
public struct MarkdownSegment: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Whole top-level blocks.
        case blocks
        /// A piece of a fenced code block larger than the segment limit.
        case fencedCodePiece
        /// A piece of a GFM table larger than the segment limit.
        case tablePiece
        /// A piece of another block (paragraph, list, quote, HTML) larger than the segment limit.
        case blockPiece
    }

    public let index: Int
    /// UTF-8 offsets into the source. Consecutive segments tile the source exactly.
    public let sourceRange: Range<Int>
    public let text: String
    public let kind: Kind
    /// True when this segment continues the same block as the previous segment.
    public let continuesPrevious: Bool
    /// False while later input may still change this segment's range or body.
    public let isSettled: Bool

    /// Renderable text without appended definitions.
    let body: String
    /// Offset of the block this segment belongs to; resegmentation resumes at block starts.
    let blockStart: Int
    /// Reference definitions found in this segment's block (recorded on the block's first piece).
    let definitions: [[UInt8]]
}

/// The segments of one source, and the input needed to extend them as the source grows.
public struct MarkdownSegmentation: Equatable, Sendable {
    public let source: String
    public let isComplete: Bool
    public let segments: [MarkdownSegment]
    let targetBytes: Int
    let maximumBytes: Int
}

/// Splits a Markdown reply at valid top-level block boundaries (#60 A1/A3, ADR-0091).
///
/// Blocks start at a column-0 line that follows a blank line, at a column-0 fence opener, and at
/// the column-0 line after a fence closes, always outside fenced code, multi-line HTML and display
/// math. Indented lines never start a block, so list continuations and indented code stay with
/// their block. Whole blocks are packed until a segment reaches `targetBytes`, and a segment's
/// body never exceeds `maximumBytes`. A block larger than `maximumBytes` is split explicitly:
///
/// - Fenced code repeats its opening fence in every piece and closes every piece except an
///   unterminated final one. A single line longer than a piece is split at a scalar boundary.
/// - A table repeats its header and delimiter rows in every piece.
/// - Any other block splits before column-0 lines (list items, quote lines), then at any line,
///   then at whitespace, then at a scalar boundary. Splitting a paragraph ends it early, so the
///   renderer should join pieces marked `continuesPrevious` without a paragraph gap.
///
/// A document that is itself an HTML or SVG artifact (see `GOATMarkdownSyntax`) stays one segment.
/// Reference-style link definitions are appended to every segment (up to `definitionLimit` bytes)
/// so reference links resolve inside each segment.
///
/// Segmentation is a pure function of the source. `resegment` reuses settled segments when the
/// new source extends the old one and returns exactly what `segment` would.
public enum MarkdownSegmenter {
    public static let targetBytes = 6 * 1_024
    public static let maximumBytes = 16 * 1_024
    public static let definitionLimit = 4 * 1_024

    public static func segment(
        _ source: String, isComplete: Bool, targetBytes: Int = targetBytes, maximumBytes: Int = maximumBytes
    ) -> MarkdownSegmentation {
        let limits = Limits(target: targetBytes, maximum: maximumBytes)
        let scanner = Scanner(bytes: Array(source.utf8), limits: limits, isComplete: isComplete)
        return MarkdownSegmentation(
            source: source, isComplete: isComplete, segments: scanner.segments(from: 0, keeping: []),
            targetBytes: limits.target, maximumBytes: limits.maximum)
    }

    /// Extends `previous` to `source`. Settled segments before the resume point are reused when
    /// `source` starts with the previous source; otherwise this is a full pass.
    public static func resegment(
        _ previous: MarkdownSegmentation, source: String, isComplete: Bool
    ) -> MarkdownSegmentation {
        guard !previous.isComplete, source.utf8.count >= previous.source.utf8.count,
            source.utf8.starts(with: previous.source.utf8),
            let resume = (previous.segments.first(where: { !$0.isSettled }) ?? previous.segments.last)?.blockStart
        else {
            return segment(
                source, isComplete: isComplete, targetBytes: previous.targetBytes, maximumBytes: previous.maximumBytes)
        }
        let limits = Limits(target: previous.targetBytes, maximum: previous.maximumBytes)
        let scanner = Scanner(bytes: Array(source.utf8), limits: limits, isComplete: isComplete)
        let kept = previous.segments.filter { $0.blockStart < resume }
        return MarkdownSegmentation(
            source: source, isComplete: isComplete, segments: scanner.segments(from: resume, keeping: kept),
            targetBytes: limits.target, maximumBytes: limits.maximum)
    }
}

// MARK: - Scanning

private struct Limits {
    let target: Int
    let maximum: Int
    init(target: Int, maximum: Int) {
        self.maximum = max(64, maximum)
        self.target = max(1, min(target, self.maximum))
    }
}

private enum BlockKind {
    case fence(opener: Range<Int>, marker: [UInt8], closer: Range<Int>?)
    case table(header: Range<Int>)
    case other
}

private struct Block {
    let range: Range<Int>
    let kind: BlockKind
    /// Fenced code, multi-line HTML and display math inside the block; cuts avoid their interiors.
    let protected: [Range<Int>]
}

private struct Piece {
    let range: Range<Int>
    let body: [UInt8]
    let kind: MarkdownSegment.Kind
    let continues: Bool
    let blockStart: Int
    let definitions: [[UInt8]]
}

private struct Scanner {
    let bytes: [UInt8]
    let limits: Limits
    let isComplete: Bool

    /// Segments from `start` (a block start outside any container), after the `kept` segments.
    func segments(from start: Int, keeping kept: [MarkdownSegment]) -> [MarkdownSegment] {
        if isArtifact {
            let body = String(decoding: bytes, as: UTF8.self)
            return [
                MarkdownSegment(
                    index: 0, sourceRange: 0..<bytes.count, text: body, kind: .blocks, continuesPrevious: false,
                    isSettled: isComplete, body: body, blockStart: 0, definitions: [])
            ]
        }
        let pieces = pack(blocks(from: start))
        let allDefinitions = kept.flatMap(\.definitions) + pieces.flatMap(\.definitions)
        let suffix = Self.definitionSuffix(allDefinitions)
        let finalLine = lastLineStart
        var segments = kept.map { segment in
            MarkdownSegment(
                index: segment.index, sourceRange: segment.sourceRange, text: segment.body + suffix,
                kind: segment.kind, continuesPrevious: segment.continuesPrevious, isSettled: segment.isSettled,
                body: segment.body, blockStart: segment.blockStart, definitions: segment.definitions)
        }
        for (offset, piece) in pieces.enumerated() {
            let isLast = offset == pieces.count - 1
            let body = String(decoding: piece.body, as: UTF8.self)
            segments.append(
                MarkdownSegment(
                    index: segments.count, sourceRange: piece.range, text: body + suffix, kind: piece.kind,
                    continuesPrevious: piece.continues,
                    isSettled: isComplete || (!isLast && piece.range.upperBound <= finalLine),
                    body: body, blockStart: piece.blockStart, definitions: piece.definitions))
        }
        return segments
    }

    /// Start of the final line, which may still be growing while the reply streams.
    private var lastLineStart: Int {
        var index = bytes.count
        if index > 0, bytes[index - 1] == newline { index -= 1 }
        while index > 0, bytes[index - 1] != newline { index -= 1 }
        return index
    }

    // MARK: Packing

    private func pack(_ blocks: [Block]) -> [Piece] {
        var pieces: [Piece] = []
        var group: (start: Int, end: Int, definitions: [[UInt8]])?
        func close() {
            if let current = group {
                pieces.append(
                    Piece(
                        range: current.start..<current.end, body: Array(bytes[current.start..<current.end]),
                        kind: .blocks, continues: false, blockStart: current.start,
                        definitions: current.definitions))
            }
            group = nil
        }
        for block in blocks {
            let definitions = Self.definitions(in: bytes, range: block.range)
            if block.range.count > limits.maximum {
                close()
                let split = self.split(block)
                pieces += split.enumerated().map { offset, piece in
                    Piece(
                        range: piece.range, body: piece.body, kind: piece.kind, continues: offset > 0,
                        blockStart: block.range.lowerBound, definitions: offset == 0 ? definitions : [])
                }
                continue
            }
            if let current = group,
                current.end - current.start >= limits.target
                    || current.end - current.start + block.range.count > limits.maximum
            {
                close()
            }
            if let current = group {
                group = (current.start, block.range.upperBound, current.definitions + definitions)
            } else {
                group = (block.range.lowerBound, block.range.upperBound, definitions)
            }
        }
        close()
        return pieces
    }

    // MARK: Blocks

    private enum Container {
        case none
        case fence(marker: UInt8, minimum: Int)
        case html(terminator: [UInt8])
        case math
    }

    /// Top-level blocks from `start`, which must be a block start outside any container.
    func blocks(from start: Int) -> [Block] {
        var blocks: [Block] = []
        var blockStart = start
        var kind: BlockKind?
        var container = Container.none
        var previousBlank = false
        var afterContainer = false
        var protected: [Range<Int>] = []
        var containerStart = start
        var line = start
        while line < bytes.count {
            let end = lineEnd(line)
            let next = end < bytes.count ? end + 1 : end
            let blank = isBlank(line..<end)
            switch container {
            case .fence(let marker, let minimum):
                if isFenceCloser(line..<end, marker: marker, minimum: minimum) {
                    if case .fence(let opener, let fenceMarker, nil) = kind {
                        kind = .fence(opener: opener, marker: fenceMarker, closer: line..<next)
                    }
                    container = .none
                    afterContainer = true
                    protected.append(containerStart..<next)
                }
                previousBlank = false
            case .html(let terminator):
                if contains(terminator, in: line..<end, caseInsensitive: true) {
                    container = .none
                    afterContainer = true
                    protected.append(containerStart..<next)
                }
                previousBlank = false
            case .math:
                if isMathFence(line..<end) {
                    container = .none
                    afterContainer = true
                    protected.append(containerStart..<next)
                }
                previousBlank = false
            case .none:
                let fence = fenceOpener(line..<end)
                let columnZero = startsAtColumnZero(line)
                if line > blockStart, !blank, columnZero, previousBlank || afterContainer || fence != nil {
                    blocks.append(Block(range: blockStart..<line, kind: kind ?? .other, protected: protected))
                    blockStart = line
                    kind = nil
                    protected = []
                }
                if !blank { afterContainer = false }
                if kind == nil, !blank { kind = classify(line: line, end: end, next: next) }
                if let fence {
                    container = .fence(marker: fence.marker, minimum: fence.length)
                    containerStart = line
                } else if let terminator = htmlBlockTerminator(line..<end) {
                    container = .html(terminator: terminator)
                    containerStart = line
                } else if isMathFence(line..<end), !isSingleLineMath(line..<end) {
                    container = .math
                    containerStart = line
                }
                previousBlank = blank
            }
            if next == end { break }
            line = next
        }
        if case .none = container {} else { protected.append(containerStart..<bytes.count) }
        if blockStart < bytes.count {
            blocks.append(Block(range: blockStart..<bytes.count, kind: kind ?? .other, protected: protected))
        }
        return blocks
    }

    private func classify(line: Int, end: Int, next: Int) -> BlockKind {
        if let fence = fenceOpener(line..<end) {
            return .fence(opener: line..<next, marker: Array(repeating: fence.marker, count: fence.length), closer: nil)
        }
        if bytes[line..<end].contains(pipe), next < bytes.count {
            let delimiterEnd = lineEnd(next)
            // The delimiter row must be complete before a table is recognised.
            if delimiterEnd < bytes.count || isComplete, isTableDelimiter(next..<delimiterEnd) {
                return .table(header: line..<(delimiterEnd < bytes.count ? delimiterEnd + 1 : delimiterEnd))
            }
        }
        return .other
    }

    // MARK: Oversized blocks

    private func split(_ block: Block) -> [(range: Range<Int>, body: [UInt8], kind: MarkdownSegment.Kind)] {
        switch block.kind {
        case .fence(let opener, let marker, let closer):
            return splitFence(block.range, opener: opener, marker: marker, closer: closer)
        case .table(let header):
            return splitTable(block.range, header: header)
        case .other:
            return chunks(block.range, budget: limits.maximum, preferColumnZero: true, protected: block.protected).map {
                ($0, Array(bytes[$0]), .blockPiece)
            }
        }
    }

    private func splitFence(_ range: Range<Int>, opener: Range<Int>, marker: [UInt8], closer: Range<Int>?)
        -> [(range: Range<Int>, body: [UInt8], kind: MarkdownSegment.Kind)]
    {
        let openerBytes = Array(bytes[opener]).withTrailingNewline
        let closing = marker + [newline]
        let bodyEnd = closer?.lowerBound ?? range.upperBound
        let budget = max(16, limits.maximum - openerBytes.count - closing.count - 1)
        let parts = chunks(opener.upperBound..<bodyEnd, budget: budget, preferColumnZero: false)
        guard !parts.isEmpty else { return [(range, Array(bytes[range]), .fencedCodePiece)] }
        return parts.enumerated().map { offset, part in
            let first = offset == 0
            let last = offset == parts.count - 1
            let raw = (first ? range.lowerBound : part.lowerBound)..<(last ? range.upperBound : part.upperBound)
            var body = openerBytes + Array(bytes[part]).withTrailingNewline
            if last, let closer {
                body += Array(bytes[closer.lowerBound..<range.upperBound])
            } else if !last {
                body += closing
            }
            return (raw, body, .fencedCodePiece)
        }
    }

    private func splitTable(_ range: Range<Int>, header: Range<Int>)
        -> [(range: Range<Int>, body: [UInt8], kind: MarkdownSegment.Kind)]
    {
        let headerBytes = Array(bytes[header]).withTrailingNewline
        let budget = max(16, limits.maximum - headerBytes.count)
        let parts = chunks(header.upperBound..<range.upperBound, budget: budget, preferColumnZero: false)
        guard !parts.isEmpty else { return [(range, Array(bytes[range]), .tablePiece)] }
        return parts.enumerated().map { offset, part in
            let raw = (offset == 0 ? range.lowerBound : part.lowerBound)..<part.upperBound
            return (raw, headerBytes + Array(bytes[part]), .tablePiece)
        }
    }

    /// Consecutive ranges covering `range`, each at most `budget` bytes. Ends at a line boundary
    /// where possible (a column-0 line first when `preferColumnZero`), then at whitespace, then at
    /// a Unicode scalar boundary.
    private func chunks(
        _ range: Range<Int>, budget: Int, preferColumnZero: Bool, protected: [Range<Int>] = []
    ) -> [Range<Int>] {
        func allowed(_ cut: Int) -> Bool { !protected.contains { $0.lowerBound < cut && cut < $0.upperBound } }
        var result: [Range<Int>] = []
        var start = range.lowerBound
        while start < range.upperBound {
            let limit = min(range.upperBound, start + budget)
            if limit == range.upperBound {
                result.append(start..<limit)
                break
            }
            var preferred: Int?
            var anyLine: Int?
            var line = start
            while line < limit {
                let next = lineEnd(line) + 1
                guard next <= limit else { break }
                if allowed(next) {
                    anyLine = next
                    if !preferColumnZero || startsAtColumnZero(next) { preferred = next }
                }
                line = next
            }
            let end = preferred ?? anyLine ?? whitespaceCut(start..<limit) ?? scalarCut(start..<limit)
            result.append(start..<end)
            start = end
        }
        return result
    }

    private func whitespaceCut(_ range: Range<Int>) -> Int? {
        var index = range.upperBound
        let floor = range.lowerBound + range.count / 2
        while index > floor {
            if bytes[index - 1] == space || bytes[index - 1] == tab { return index }
            index -= 1
        }
        return nil
    }

    private func scalarCut(_ range: Range<Int>) -> Int {
        var index = range.upperBound
        while index > range.lowerBound + 1, index < bytes.count, bytes[index] & 0xC0 == 0x80 { index -= 1 }
        return index
    }

    // MARK: Lines

    private func lineEnd(_ start: Int) -> Int {
        var index = start
        while index < bytes.count, bytes[index] != newline { index += 1 }
        return index
    }

    private func isBlank(_ range: Range<Int>) -> Bool {
        bytes[range].allSatisfy { $0 == space || $0 == tab || $0 == carriageReturn }
    }

    private func startsAtColumnZero(_ index: Int) -> Bool {
        index < bytes.count && ![space, tab, newline, carriageReturn].contains(bytes[index])
    }

    /// First non-space offset when the line is indented by at most three spaces.
    private func contentStart(_ range: Range<Int>) -> Int? {
        var index = range.lowerBound
        while index < range.upperBound, bytes[index] == space, index - range.lowerBound < 4 { index += 1 }
        guard index - range.lowerBound <= 3, index == range.upperBound || bytes[index] != tab else { return nil }
        return index
    }

    private func fenceOpener(_ range: Range<Int>) -> (marker: UInt8, length: Int)? {
        guard let start = contentStart(range), start < range.upperBound else { return nil }
        let marker = bytes[start]
        guard marker == backtick || marker == tilde else { return nil }
        var index = start
        while index < range.upperBound, bytes[index] == marker { index += 1 }
        guard index - start >= 3 else { return nil }
        if marker == backtick, bytes[index..<range.upperBound].contains(backtick) { return nil }
        return (marker, index - start)
    }

    private func isFenceCloser(_ range: Range<Int>, marker: UInt8, minimum: Int) -> Bool {
        guard let start = contentStart(range) else { return false }
        var index = start
        while index < range.upperBound, bytes[index] == marker { index += 1 }
        return index - start >= minimum && isBlank(index..<range.upperBound)
    }

    private func htmlBlockTerminator(_ range: Range<Int>) -> [UInt8]? {
        guard let start = contentStart(range), start < range.upperBound, bytes[start] == lessThan else { return nil }
        let line = bytes[start..<range.upperBound]
        if line.starts(with: Array("<!--".utf8)) {
            return contains(Array("-->".utf8), in: (start + 4)..<range.upperBound, caseInsensitive: false)
                ? nil : Array("-->".utf8)
        }
        for tag in ["pre", "script", "style", "textarea"] {
            let open = Array("<\(tag)".utf8)
            guard line.count >= open.count, zip(line, open).allSatisfy({ lower($0) == $1 }) else { continue }
            let after = start + open.count
            guard after == range.upperBound || [space, tab, greaterThan].contains(bytes[after]) else { continue }
            let close = Array("</\(tag)>".utf8)
            return contains(close, in: start..<range.upperBound, caseInsensitive: true) ? nil : close
        }
        return nil
    }

    private func isMathFence(_ range: Range<Int>) -> Bool {
        guard let start = contentStart(range) else { return false }
        return bytes[start..<range.upperBound].starts(with: [dollar, dollar])
    }

    private func isSingleLineMath(_ range: Range<Int>) -> Bool {
        guard let start = contentStart(range) else { return false }
        let trimmed = bytes[start..<range.upperBound].trimmingTrailingWhitespace
        return trimmed.count >= 4 && trimmed.suffix(2).elementsEqual([dollar, dollar])
    }

    private func isTableDelimiter(_ range: Range<Int>) -> Bool {
        let line = bytes[range]
        guard line.contains(pipe), line.contains(hyphen) else { return false }
        return line.allSatisfy { [pipe, colon, hyphen, space, tab, carriageReturn].contains($0) }
    }

    private func contains(_ needle: [UInt8], in range: Range<Int>, caseInsensitive: Bool) -> Bool {
        guard !needle.isEmpty, range.count >= needle.count else { return false }
        var index = range.lowerBound
        while index + needle.count <= range.upperBound {
            var offset = 0
            while offset < needle.count {
                let byte = bytes[index + offset]
                if (caseInsensitive ? lower(byte) : byte) != needle[offset] { break }
                offset += 1
            }
            if offset == needle.count { return true }
            index += 1
        }
        return false
    }

    // MARK: Definitions and artifacts

    private var isArtifact: Bool {
        var index = 0
        while index < bytes.count, [space, tab, newline, carriageReturn].contains(bytes[index]) { index += 1 }
        let head = bytes[index..<min(bytes.count, index + 16)].map(lower)
        return ["<!doctype html", "<html", "<svg"].contains { head.starts(with: Array($0.utf8)) }
    }

    /// Reference-style link definition lines (`[label]: destination`) outside fenced code.
    static func definitions(in bytes: [UInt8], range: Range<Int>) -> [[UInt8]] {
        var found: [[UInt8]] = []
        var fence: UInt8?
        var line = range.lowerBound
        while line < range.upperBound {
            var end = line
            while end < range.upperBound, bytes[end] != newline { end += 1 }
            var start = line
            while start < end, start - line < 3, bytes[start] == space { start += 1 }
            let body = bytes[start..<end]
            if let marker = body.first, marker == backtick || marker == tilde,
                body.prefix(3).allSatisfy({ $0 == marker })
            {
                fence = fence == nil ? marker : (fence == marker ? nil : fence)
            } else if fence == nil, body.first == openBracket, body.dropFirst().first != caret,
                let close = body.firstIndex(of: closeBracket), close + 2 < end, bytes[close + 1] == colon,
                !bytes[(close + 2)..<end].allSatisfy({ $0 == space || $0 == tab || $0 == carriageReturn })
            {
                found.append(body.trimmingTrailingWhitespace)
            }
            line = end + 1
        }
        return found
    }

    static func definitionSuffix(_ definitions: [[UInt8]]) -> String {
        var unique: [[UInt8]] = []
        for definition in definitions where !unique.contains(definition) { unique.append(definition) }
        let joined = Array(unique.joined(separator: [newline]))
        guard !joined.isEmpty, joined.count <= MarkdownSegmenter.definitionLimit else { return "" }
        return "\n\n" + String(decoding: joined, as: UTF8.self) + "\n"
    }
}

// MARK: - Bytes

private let newline = UInt8(ascii: "\n")
private let carriageReturn = UInt8(ascii: "\r")
private let space = UInt8(ascii: " ")
private let tab = UInt8(ascii: "\t")
private let backtick = UInt8(ascii: "`")
private let tilde = UInt8(ascii: "~")
private let pipe = UInt8(ascii: "|")
private let hyphen = UInt8(ascii: "-")
private let colon = UInt8(ascii: ":")
private let dollar = UInt8(ascii: "$")
private let lessThan = UInt8(ascii: "<")
private let greaterThan = UInt8(ascii: ">")
private let openBracket = UInt8(ascii: "[")
private let closeBracket = UInt8(ascii: "]")
private let caret = UInt8(ascii: "^")

private func lower(_ byte: UInt8) -> UInt8 {
    (65...90).contains(byte) ? byte + 32 : byte
}

extension Array where Element == UInt8 {
    fileprivate var withTrailingNewline: [UInt8] { last == newline || isEmpty ? self : self + [newline] }
}

extension Collection where Element == UInt8 {
    fileprivate var trimmingTrailingWhitespace: [UInt8] {
        var result = Array(self)
        while let last = result.last, last == space || last == tab || last == carriageReturn { result.removeLast() }
        return result
    }
}
