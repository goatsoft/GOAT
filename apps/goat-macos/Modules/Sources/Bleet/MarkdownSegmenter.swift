import Foundation

/// One independently renderable part of a Markdown reply.
///
/// `index` is the segment's identity. It depends only on the bytes before the segment, so it stays
/// the same while the reply grows. `body` is what to render: the source bytes in `sourceRange` for
/// whole blocks, and for a piece of an oversized block, those bytes with the syntax that makes the
/// piece valid on its own rebuilt around them (a code fence, a table header). `text` appends the
/// reply's reference-style link definitions so reference links resolve inside the segment.
public struct MarkdownSegment: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Whole top-level blocks, copied from the source.
        case blocks
        /// A piece of fenced code larger than the segment maximum, with its own opening and
        /// closing fence. A code line longer than a piece is split at a scalar boundary.
        case fencedCodePiece
        /// A piece of a GFM table larger than the segment maximum, with its header repeated.
        case tablePiece
        /// A piece of another block (paragraph, list, quote) larger than the segment maximum. A
        /// paragraph or list item cut here ends early; inline markup that crosses the cut is not
        /// preserved, and a single-item piece of a loose list renders tight.
        case blockPiece
        /// A piece whose Markdown syntax cannot be rebuilt within the segment maximum (an HTML or
        /// math container, a fence nested in a quote, a table whose header rows exceed the
        /// syntax budget, a fence whose opener does). Render `body` as plain monospaced text.
        case verbatimPiece
    }

    public let index: Int
    /// UTF-8 offsets into the source. Consecutive segments tile the source exactly.
    public let sourceRange: Range<Int>
    /// Renderable content, at most `maximumBytes` long (except a whole HTML or SVG artifact).
    public let body: String
    /// Reference-style definitions appended by `text` (empty for verbatim pieces and artifacts).
    public let definitionSuffix: String
    public let kind: Kind
    /// True when this segment continues the same block as the previous segment.
    public let continuesPrevious: Bool
    /// False while later input may still change this segment's range, kind or body.
    public let isSettled: Bool

    /// The Markdown to render: `body` followed by the reply's reference definitions.
    public var text: String { definitionSuffix.isEmpty ? body : body + definitionSuffix }
}

/// Splits a Markdown reply at valid top-level block boundaries (#60 A1/A3, ADR-0091).
///
/// **Boundaries.** Blocks start at a column-0 line that follows a blank line, at a column-0 fence
/// opener, and at the column-0 line after a container closes, always outside fenced code,
/// multi-line HTML (`pre`, `script`, `style`, `textarea`, comments) and display math. A column-0
/// item of the same list after a blank line continues that list, so loose lists stay whole.
/// Indented lines never start a block. Whole blocks are packed until a segment reaches
/// `targetBytes`; a segment's body never exceeds `maximumBytes`.
///
/// **Oversized blocks** are split explicitly, and each piece stays valid on its own:
///
/// - Fenced code gets a rebuilt fence in every piece: the opener with its info string, or only its
///   language, or a bare fence, whichever fits the syntax budget (a quarter of the maximum), and a
///   closing fence on every piece except an unterminated final one. Code lines keep their text,
///   with the fence's indentation removed.
/// - A table repeats its header and delimiter rows when they fit the syntax budget.
/// - Other blocks split before column-0 lines (list items), then at any line, then at whitespace,
///   then at a scalar boundary, and never inside a nested container. A nested container larger
///   than a piece is split on its own: an indented or list-item fence is rebuilt as above, and
///   HTML, math and quoted fences become `verbatimPiece`s.
/// - Anything whose syntax cannot be rebuilt within the budget becomes `verbatimPiece`s.
///
/// **Bounded syntax.** A line longer than `maximumBytes` has no block syntax: it cannot open or close
/// a fence, HTML block or display math, or be a table header, delimiter or link definition. This
/// is where GOAT departs from CommonMark (which has no line limit); it bounds both the syntax a
/// piece repeats and the input the scanner must see before deciding what a line is.
///
/// **Artifacts.** A document that is itself an HTML or SVG artifact (see `GOATMarkdownSyntax`)
/// stays one segment, the only body that may exceed `maximumBytes`.
///
/// **Streaming.** Segmentation is a pure function of the source: extending a segmentation equals
/// segmenting the longer source afresh. Each extension reads only the new bytes plus a tail bounded
/// by the segment maximum: lines are committed once their role is decided (a line is decided when
/// it ends or exceeds the maximum; a possible table header when the following line is decided),
/// committed segments are never revisited, and oversized blocks resume at their open piece. See
/// `MarkdownSegmentation.Work`.
public enum MarkdownSegmenter {
    public static let targetBytes = 6 * 1_024
    public static let maximumBytes = 16 * 1_024
    public static let definitionLimit = 4 * 1_024

    public static func segment(
        _ source: String, isComplete: Bool, targetBytes: Int = targetBytes, maximumBytes: Int = maximumBytes
    ) -> MarkdownSegmentation {
        var segmentation = MarkdownSegmentation(targetBytes: targetBytes, maximumBytes: maximumBytes)
        segmentation.extend(to: source, isComplete: isComplete)
        return segmentation
    }

    /// Extends `previous` to `source`. Prefer `MarkdownSegmentation.extend(to:isComplete:)` on a
    /// uniquely held value, which appends in place.
    public static func resegment(
        _ previous: MarkdownSegmentation, source: String, isComplete: Bool
    ) -> MarkdownSegmentation {
        var next = previous
        next.extend(to: source, isComplete: isComplete)
        return next
    }
}

/// The segments of one source, and the scanner state needed to extend them as the source grows.
public struct MarkdownSegmentation: Sendable {
    /// Work the segmenter has done, for tests that bound it.
    public struct Work: Equatable, Sendable {
        /// Source bytes read while scanning, classifying and verifying (an upper bound).
        public var scannedBytes = 0
        /// Bytes copied into segment bodies, table headers and definitions.
        public var copiedBytes = 0
        public var totalBytes: Int { scannedBytes + copiedBytes }
    }

    public private(set) var source = ""
    public private(set) var isComplete = false
    public private(set) var work = Work()
    let limits: SegmentLimits

    private var settled: [StoredSegment] = []
    private var provisional: [StoredSegment] = []
    private var definitions = DefinitionSet()
    private var settledSuffix = ""
    private var provisionalSuffix = ""
    private var engine = Engine()
    private var artifact: Bool?

    public init(
        targetBytes: Int = MarkdownSegmenter.targetBytes, maximumBytes: Int = MarkdownSegmenter.maximumBytes
    ) {
        limits = SegmentLimits(target: targetBytes, maximum: maximumBytes)
    }

    /// The segments, settled ones first. Accessing one is O(1); `text` concatenates on access.
    public var segments: [MarkdownSegment] { Array(self) }

    /// Extends the segmentation to `newSource`.
    ///
    /// `newSource` must extend the current source. Only the undecided tail is compared, so a caller
    /// that rewrites earlier text must start a new segmentation; a completed segmentation, a shorter
    /// source or a changed tail starts over. The work is bounded by the new bytes plus the segment
    /// maximum when this value is uniquely referenced and `newSource` is a native Swift string.
    public mutating func extend(to newSource: String, isComplete complete: Bool) {
        if !canExtend(to: newSource) {
            let spent = work
            self = MarkdownSegmentation(limits: limits)
            work = spent
        }
        source = newSource
        isComplete = complete
        advance()
    }

    private init(limits: SegmentLimits) {
        self.limits = limits
    }

    private mutating func canExtend(to newSource: String) -> Bool {
        guard !isComplete, newSource.utf8.count >= source.utf8.count else { return false }
        guard artifact != true else { return true }
        let from = engine.position
        let old = source
        var compared = 0
        let matches = withUTF8(old) { oldBytes in
            withUTF8(newSource) { newBytes in
                compared = oldBytes.count - from
                return oldBytes[from...].elementsEqual(newBytes[from..<oldBytes.count])
            }
        }
        work.scannedBytes += 2 * compared
        // Committed bytes are not compared in release builds. Debug builds check a bounded window
        // of the most recent committed bytes to catch callers that rewrite them.
        let window = Swift.max(0, from - limits.maximum)..<from
        assert(
            !matches
                || newSource.utf8.dropFirst(window.lowerBound).prefix(window.count)
                    .elementsEqual(old.utf8.dropFirst(window.lowerBound).prefix(window.count)),
            "Committed text was rewritten")
        return matches
    }

    private mutating func advance() {
        let text = source
        let limits = self.limits
        let final = isComplete
        withUTF8(text) { bytes in
            var input = Input(bytes: bytes, isFinal: final, limits: limits)
            if artifact == nil { artifact = Engine.artifactDecision(&input) }
            if artifact == true {
                let whole = StoredSegment(
                    range: 0..<bytes.count, body: text, kind: .blocks, acceptsDefinitions: false, continues: false)
                settled = final ? [whole] : []
                provisional = final ? [] : [whole]
            } else {
                var committed = Output()
                if artifact == false { engine.run(&input, &committed, provisional: false) }
                settled += committed.segments
                if definitions.add(committed.definitions) { settledSuffix = definitions.suffix }
                provisional = []
                provisionalSuffix = settledSuffix
                if !final {
                    var tail = artifact == false ? engine : Engine()
                    var pending = Output()
                    tail.run(&input, &pending, provisional: true)
                    provisional = pending.segments
                    if !pending.definitions.isEmpty {
                        var all = definitions
                        if all.add(pending.definitions) { provisionalSuffix = all.suffix }
                    }
                }
            }
            work.scannedBytes += input.work.scannedBytes
            work.copiedBytes += input.work.copiedBytes
        }
    }
}

extension MarkdownSegmentation: RandomAccessCollection {
    public var startIndex: Int { 0 }
    public var endIndex: Int { settled.count + provisional.count }

    public subscript(position: Int) -> MarkdownSegment {
        if position < settled.count {
            return settled[position].segment(index: position, suffix: settledSuffix, isSettled: true)
        }
        return provisional[position - settled.count].segment(
            index: position, suffix: provisionalSuffix, isSettled: false)
    }
}

extension MarkdownSegmentation: Equatable {
    /// Equal sources, completeness and segments; scanner state and work are not compared.
    public static func == (lhs: MarkdownSegmentation, rhs: MarkdownSegmentation) -> Bool {
        lhs.source == rhs.source && lhs.isComplete == rhs.isComplete && lhs.elementsEqual(rhs)
    }
}

private func withUTF8<Result>(_ text: String, _ body: (UnsafeBufferPointer<UInt8>) -> Result) -> Result {
    if let result = text.utf8.withContiguousStorageIfAvailable(body) { return result }
    var copy = text
    copy.makeContiguousUTF8()
    return copy.utf8.withContiguousStorageIfAvailable(body)!
}

// MARK: - Storage

struct SegmentLimits: Equatable, Sendable {
    let target: Int
    let maximum: Int
    /// Syntax a piece may repeat: a fence opener and closer, or a table's header rows.
    let syntax: Int

    init(target: Int, maximum: Int) {
        self.maximum = max(64, maximum)
        self.target = max(1, min(target, self.maximum))
        syntax = self.maximum / 4
    }
}

private struct StoredSegment: Sendable {
    let range: Range<Int>
    let body: String
    let kind: MarkdownSegment.Kind
    let acceptsDefinitions: Bool
    let continues: Bool

    func segment(index: Int, suffix: String, isSettled: Bool) -> MarkdownSegment {
        MarkdownSegment(
            index: index, sourceRange: range, body: body, definitionSuffix: acceptsDefinitions ? suffix : "",
            kind: kind, continuesPrevious: continues, isSettled: isSettled)
    }
}

private struct Output {
    var segments: [StoredSegment] = []
    var definitions: [[UInt8]] = []
}

/// Unique reference definitions in order. Once they exceed `definitionLimit` none are appended.
private struct DefinitionSet: Sendable {
    private var items: [[UInt8]] = []
    private var seen: Set<[UInt8]> = []
    private var joinedBytes = 0
    private var overflowed = false

    /// Adds `definitions`; true when the suffix changed.
    mutating func add(_ definitions: [[UInt8]]) -> Bool {
        var changed = false
        for definition in definitions where !overflowed && !seen.contains(definition) {
            let extra = definition.count + (items.isEmpty ? 0 : 1)
            if joinedBytes + extra > MarkdownSegmenter.definitionLimit {
                overflowed = true
                items = []
                seen = []
            } else {
                items.append(definition)
                seen.insert(definition)
                joinedBytes += extra
            }
            changed = true
        }
        return changed
    }

    var suffix: String {
        guard !items.isEmpty else { return "" }
        return "\n\n" + String(decoding: Array(items.joined(separator: [newline])), as: UTF8.self) + "\n"
    }
}

// MARK: - Input

private struct Input {
    let bytes: UnsafeBufferPointer<UInt8>
    let isFinal: Bool
    let limits: SegmentLimits
    var work = MarkdownSegmentation.Work()

    var count: Int { bytes.count }
    subscript(index: Int) -> UInt8 { bytes[index] }

    mutating func scanned(_ count: Int) { work.scannedBytes += max(0, count) }

    mutating func copy(_ range: Range<Int>) -> [UInt8] {
        work.copiedBytes += range.count
        return Array(bytes[range])
    }
}

private struct Line {
    let start: Int
    /// End of the line's content (its newline or the end of the source); unknown for long lines.
    let end: Int
    /// Start of the following line.
    let next: Int
    /// Longer than the maximum: no block syntax, streamed without waiting for its end.
    let isLong: Bool
    var range: Range<Int> { start..<end }
}

private struct FenceOpener {
    let marker: UInt8
    let length: Int
    /// Bytes before the marker run: removed from each content line when the fence is rebuilt.
    let indent: Int
    let info: Range<Int>
}

private struct NestedFence {
    let opener: FenceOpener
    let quoteDepth: Int
    /// A fence behind spaces or a list marker is rebuilt; a quoted or tab-indented one is not.
    let rebuildable: Bool
}

private enum ListMarker: Equatable {
    case bullet(UInt8)
    case ordered(UInt8)
}

private struct Facts {
    let blank: Bool
    let columnZero: Bool
    let fence: FenceOpener?
    let listMarker: ListMarker?
}

private enum Container {
    case none
    case fence(marker: UInt8, minimum: Int)
    case html(terminator: [UInt8])
    case math

    var isOpen: Bool {
        if case .none = self { return false }
        return true
    }
}

// MARK: - Pieces

private struct FencePlan {
    let opener: [UInt8]
    let closing: [UInt8]
    let strip: Int
    let contentStart: Int

    func budget(_ limits: SegmentLimits) -> Int { limits.maximum - opener.count - closing.count - 1 }
}

private enum Shape {
    case prose
    case fence(FencePlan)
    case table(header: [UInt8])
    case verbatim

    var kind: MarkdownSegment.Kind {
        switch self {
        case .prose: .blockPiece
        case .fence: .fencedCodePiece
        case .table: .tablePiece
        case .verbatim: .verbatimPiece
        }
    }
}

private struct Piece {
    let raw: Range<Int>
    let content: Range<Int>
    let shape: Shape
    /// Close a rebuilt fence (every piece except an unterminated final one).
    let closed: Bool
}

/// Greedy piece boundaries for one run of content, decided as bytes arrive.
///
/// A piece covering content from `contentStart` is cut when the byte at `limit` arrives, at the
/// last candidate before it: a column-0 line boundary when preferred, any line boundary, the end
/// of whitespace in the second half, or a scalar boundary. Candidates are remembered as the last
/// seen, so deciding a cut never rescans the piece.
private struct Cutter {
    var pieceStart: Int
    var contentStart: Int
    /// No cuts at or after this offset (a fence's closing line).
    var contentEnd = Int.max
    let budget: Int
    let preferColumnZero: Bool
    var lastBoundary = -1
    var lastColumnZero = -1

    var limit: Int { contentStart + budget < contentEnd ? contentStart + budget : Int.max }

    mutating func boundary(_ offset: Int, columnZero: Bool) {
        lastBoundary = offset
        if columnZero { lastColumnZero = offset }
    }

    func cut(at limit: Int, lastSpaceEnd: Int, _ input: inout Input) -> Int {
        if preferColumnZero, lastColumnZero > contentStart { return lastColumnZero }
        if lastBoundary > contentStart { return lastBoundary }
        if lastSpaceEnd > contentStart + (limit - contentStart) / 2 { return lastSpaceEnd }
        var index = limit
        while index > contentStart + 1, index < input.count, input[index] & 0xC0 == 0x80 { index -= 1 }
        input.scanned(limit - index + 1)
        return index
    }

    mutating func advance(to offset: Int) {
        pieceStart = offset
        contentStart = offset
    }
}

private struct Shadow {
    let start: Int
    let shape: Shape
    var cutter: Cutter
    var pending: [Piece] = []
}

private struct Block {
    enum Mode {
        case prose
        case fence(FencePlan)
        case table(header: [UInt8])
        case verbatim

        var shape: Shape {
            switch self {
            case .prose: .prose
            case .fence(let plan): .fence(plan)
            case .table(let header): .table(header: header)
            case .verbatim: .verbatim
            }
        }
    }

    let start: Int
    var classified = false
    var listMarker: ListMarker?
    var oversized = false
    var emitted = 0
    var mode = Mode.prose
    var main: Cutter
    /// The block's own fence is open (the block started with it).
    var ownFence = false
    /// The block's own fence has closed; its last piece takes blank lines until the next content.
    var fenceDone = false
    /// The adopted container has closed; its last piece takes blank lines until the next content.
    var shadowDone = false
    /// Pieces decided before the block is known to exceed the maximum.
    var pending: [Piece] = []
    /// A container inside a prose block, chunked on its own in case it outgrows a piece.
    var shadow: Shadow?
    /// The shadow's pieces are the block's pieces until its container closes.
    var adopted = false
}

// MARK: - Engine

/// The scanner. Its state is small and copyable: `MarkdownSegmentation` keeps the committed state
/// and runs a copy over the undecided tail on every extension.
private struct Engine: Sendable {
    var position = 0
    var longLine: Int?
    var container = Container.none
    var nested: NestedFence?
    var previousBlank = false
    var afterContainer = false
    var previousDefinition = false
    var block: Block?
    var group: Range<Int>?
    var lastSpaceEnd = -1

    /// Advances over decided lines. With `provisional`, treats the source as ending here instead
    /// and closes every open block, group and piece.
    mutating func run(_ input: inout Input, _ out: inout Output, provisional: Bool) {
        while true {
            if let start = longLine {
                guard streamLongLine(from: start, &input, &out, provisional: provisional) else { return }
                continue
            }
            guard position < input.count else {
                if provisional || input.isFinal { finish(&input, &out) }
                return
            }
            guard let line = Scan.line(at: position, &input, provisional: provisional) else { return }
            if line.isLong {
                beginLongLine(line, &input, &out)
                continue
            }
            var lookahead: Line?
            if !container.isOpen, Scan.mayBeTableHeader(line.range, &input) {
                // A table needs its delimiter row, which must be complete.
                if line.next < input.count, let next = Scan.line(at: line.next, &input, provisional: false) {
                    lookahead = next.isLong ? nil : next
                } else if !(provisional || input.isFinal) {
                    return
                }
            }
            processLine(line, lookahead: lookahead, &input, &out)
        }
    }

    // MARK: Lines

    private mutating func processLine(_ line: Line, lookahead: Line?, _ input: inout Input, _ out: inout Output) {
        position = line.next
        switch container {
        case .fence(let marker, let minimum):
            let closes = Scan.isFenceCloser(line.range, marker: marker, minimum: minimum, &input)
            interiorLine(line, closes: closes, rebuildsCloser: true, &input, &out)
            return
        case .html(let terminator):
            let closes = Scan.contains(terminator, in: line.range, &input)
            interiorLine(line, closes: closes, rebuildsCloser: false, &input, &out)
            return
        case .math:
            let closes = Scan.isMathFence(line.range, &input)
            interiorLine(line, closes: closes, rebuildsCloser: false, &input, &out)
            return
        case .none:
            break
        }
        let facts = Scan.facts(line, &input)
        enterLine(line, facts, &input, &out)
        if !facts.blank { finishClosedPiece(at: line.start, &input, &out) }
        if let nested {
            let closes = Scan.isNestedCloser(line.range, nested, &input)
            if closes { closerLine(at: line.start) }
            consume(line.start..<line.next, &input, &out)
            if closes {
                self.nested = nil
                afterContainer = true
                containerClosed(at: line.next, closed: true, &input, &out)
            }
            previousBlank = facts.blank
            previousDefinition = false
            return
        }
        let definitionAllowed = previousBlank || previousDefinition || afterContainer || !block!.classified
        if !facts.blank { afterContainer = false }
        let classifying = !block!.classified && !facts.blank
        if classifying { classify(line, facts, lookahead: lookahead, &input) }
        if let fence = facts.fence {
            container = .fence(marker: fence.marker, minimum: fence.length)
            if !block!.ownFence {
                containerOpened(at: line.start, plan: Scan.fencePlan(line, fence, &input), &input)
            }
        } else if let terminator = Scan.htmlTerminator(line.range, &input) {
            container = .html(terminator: terminator)
            containerOpened(at: line.start, plan: nil, &input)
        } else if Scan.isMathFence(line.range, &input), !Scan.isSingleLineMath(line.range, &input) {
            container = .math
            containerOpened(at: line.start, plan: nil, &input)
        } else if !facts.blank, let fence = Scan.nestedFence(line.range, &input) {
            nested = fence
            let plan = fence.rebuildable ? Scan.fencePlan(line, fence.opener, &input) : nil
            containerOpened(at: line.start, plan: plan, &input)
        }
        if let marker = facts.listMarker { block!.listMarker = marker }
        if !facts.blank, definitionAllowed, let definition = Scan.definition(line.range, &input) {
            out.definitions.append(definition)
            previousDefinition = true
        } else {
            previousDefinition = false
        }
        consume(line.start..<line.next, &input, &out)
        previousBlank = facts.blank
    }

    /// Block bookkeeping at the start of a line outside any top-level container.
    private mutating func enterLine(_ line: Line, _ facts: Facts, _ input: inout Input, _ out: inout Output) {
        if let nested, facts.columnZero, !facts.blank, !(nested.quoteDepth > 0 && input[line.start] == greaterThan) {
            // A column-0 line ends a fence nested in a list item, and a quoted one unless quoted.
            self.nested = nil
            containerClosed(at: line.start, closed: false, &input, &out)
            afterContainer = true
        }
        if let current = block, line.start > current.start, !facts.blank, facts.columnZero,
            previousBlank || afterContainer || facts.fence != nil,
            !(facts.fence == nil && facts.listMarker != nil && facts.listMarker == current.listMarker)
        {
            endBlock(at: line.start, &input, &out)
        }
        if block == nil { startBlock(at: line.start, input.limits) }
        registerBoundary(at: line.start, &input)
    }

    private mutating func interiorLine(
        _ line: Line, closes: Bool, rebuildsCloser: Bool, _ input: inout Input, _ out: inout Output
    ) {
        registerBoundary(at: line.start, &input)
        if closes, rebuildsCloser { closerLine(at: line.start) }
        consume(line.start..<line.next, &input, &out)
        if closes {
            container = .none
            afterContainer = true
            containerClosed(at: line.next, closed: true, &input, &out)
        }
        previousBlank = false
        previousDefinition = false
    }

    private mutating func beginLongLine(_ line: Line, _ input: inout Input, _ out: inout Output) {
        longLine = line.start
        if container.isOpen {
            registerBoundary(at: line.start, &input)
        } else {
            let columnZero = !isSpaceLike(input[line.start])
            let marker =
                columnZero ? Scan.listMarker(line.start..<(line.start + input.limits.maximum), &input) : nil
            let facts = Facts(blank: false, columnZero: columnZero, fence: nil, listMarker: marker)
            enterLine(line, facts, &input, &out)
            finishClosedPiece(at: line.start, &input, &out)
            if nested == nil {
                afterContainer = false
                block!.classified = true
                if let marker { block!.listMarker = marker }
            }
        }
        previousDefinition = false
    }

    /// Consumes a long line's available bytes; true once the line has ended.
    private mutating func streamLongLine(
        from start: Int, _ input: inout Input, _ out: inout Output, provisional: Bool
    ) -> Bool {
        var index = position
        while index < input.count, input[index] != newline { index += 1 }
        let found = index < input.count
        let next = found ? index + 1 : index
        consume(position..<next, &input, &out)
        position = next
        guard found || provisional || input.isFinal else { return false }
        longLine = nil
        let content = start..<index
        let closes: Bool
        switch container {
        case .html(let terminator): closes = Scan.contains(terminator, in: content, &input)
        case .math: closes = Scan.isMathFence(content, &input)
        case .none, .fence: closes = false
        }
        if closes {
            container = .none
            afterContainer = true
            containerClosed(at: next, closed: true, &input, &out)
        }
        previousBlank = false
        return true
    }

    // MARK: Blocks

    private mutating func startBlock(at start: Int, _ limits: SegmentLimits) {
        block = Block(
            start: start,
            main: Cutter(pieceStart: start, contentStart: start, budget: limits.maximum, preferColumnZero: true))
    }

    private mutating func classify(_ line: Line, _ facts: Facts, lookahead: Line?, _ input: inout Input) {
        block!.classified = true
        guard block!.emitted == 0, block!.pending.isEmpty, block!.main.pieceStart == block!.start else { return }
        let limits = input.limits
        let start = block!.start
        if let fence = facts.fence {
            if let plan = Scan.fencePlan(line, fence, &input) {
                block!.mode = .fence(plan)
                block!.main = Cutter(
                    pieceStart: start, contentStart: plan.contentStart, budget: plan.budget(limits),
                    preferColumnZero: false)
                block!.ownFence = true
            } else {
                useVerbatim(limits)
            }
        } else if let next = lookahead, Scan.containsPipe(line.range, &input),
            Scan.isTableDelimiter(next.range, &input)
        {
            let headerEnd = next.next
            let terminated = input[headerEnd - 1] == newline
            if headerEnd - line.start + (terminated ? 0 : 1) <= limits.syntax {
                var header = input.copy(line.start..<headerEnd)
                if !terminated { header.append(newline) }
                block!.mode = .table(header: header)
                block!.main = Cutter(
                    pieceStart: start, contentStart: headerEnd, budget: limits.maximum - header.count,
                    preferColumnZero: false)
            } else {
                useVerbatim(limits)
            }
        }
    }

    private mutating func useVerbatim(_ limits: SegmentLimits) {
        block!.mode = .verbatim
        block!.main = Cutter(
            pieceStart: block!.start, contentStart: block!.start, budget: limits.maximum, preferColumnZero: false)
    }

    private mutating func endBlock(at end: Int, _ input: inout Input, _ out: inout Output) {
        guard block != nil else { return }
        if nested != nil {
            nested = nil
            containerClosed(at: end, closed: false, &input, &out)
        }
        finishClosedPiece(at: end, &input, &out)
        let current = block!
        if current.oversized {
            if current.adopted, let shadow = current.shadow {
                output(
                    Piece(
                        raw: shadow.cutter.pieceStart..<end,
                        content: shadow.cutter
                            .contentStart..<max(
                                shadow.cutter.contentStart, min(shadow.cutter.contentEnd, end)),
                        shape: shadow.shape, closed: false), &input, &out)
            } else if current.main.pieceStart < end {
                output(
                    Piece(
                        raw: current.main.pieceStart..<end,
                        content: current.main
                            .contentStart..<max(
                                current.main.contentStart, min(current.main.contentEnd, end)),
                        shape: current.mode.shape, closed: false), &input, &out)
            }
        } else {
            pack(current.start..<end, &input, &out)
        }
        block = nil
    }

    /// Adds a whole block to the open group. A group is emitted as soon as it reaches the target,
    /// so it settles without waiting for the next block to end.
    private mutating func pack(_ range: Range<Int>, _ input: inout Input, _ out: inout Output) {
        if let current = group, current.count + range.count > input.limits.maximum {
            emitGroup(current, &input, &out)
            group = nil
        }
        let merged = group.map { $0.lowerBound..<range.upperBound } ?? range
        if merged.count >= input.limits.target {
            emitGroup(merged, &input, &out)
            group = nil
        } else {
            group = merged
        }
    }

    private mutating func emitGroup(_ range: Range<Int>, _ input: inout Input, _ out: inout Output) {
        let body = String(decoding: input.copy(range), as: UTF8.self)
        out.segments.append(
            StoredSegment(range: range, body: body, kind: .blocks, acceptsDefinitions: true, continues: false))
    }

    private mutating func finish(_ input: inout Input, _ out: inout Output) {
        endBlock(at: input.count, &input, &out)
        if let current = group { emitGroup(current, &input, &out) }
        group = nil
        position = input.count
    }

    // MARK: Containers inside a block

    private mutating func containerOpened(at start: Int, plan: FencePlan?, _ input: inout Input) {
        guard case .prose = block!.mode else { return }
        let limits = input.limits
        let cutter =
            plan.map {
                Cutter(
                    pieceStart: start, contentStart: $0.contentStart, budget: $0.budget(limits),
                    preferColumnZero: false)
            } ?? Cutter(pieceStart: start, contentStart: start, budget: limits.maximum, preferColumnZero: false)
        block!.shadow = Shadow(start: start, shape: plan.map(Shape.fence) ?? .verbatim, cutter: cutter)
    }

    /// The line at `start` closes the current fence: its bytes are not code.
    private mutating func closerLine(at start: Int) {
        if block!.ownFence {
            block!.main.contentEnd = start
        } else if case .fence = block!.shadow?.shape {
            block!.shadow!.cutter.contentEnd = start
        }
    }

    /// A container inside the block has closed at `end` (after its closing line), or was cut off
    /// there (`closed` false) by the end of its block or a column-0 line.
    private mutating func containerClosed(at end: Int, closed: Bool, _ input: inout Input, _ out: inout Output) {
        guard block != nil else { return }
        if block!.ownFence {
            block!.ownFence = false
            block!.fenceDone = true
        } else if let shadow = block!.shadow {
            if block!.adopted, closed {
                block!.shadowDone = true
                return
            }
            if block!.adopted {
                let cutter = shadow.cutter
                output(
                    Piece(
                        raw: cutter.pieceStart..<end,
                        content: cutter.contentStart..<max(cutter.contentStart, min(cutter.contentEnd, end)),
                        shape: shadow.shape, closed: false), &input, &out)
                block!.main.advance(to: end)
                block!.adopted = false
            }
            block!.shadow = nil
        }
    }

    /// Ends the piece of a closed container at `end`, the next non-blank line or the block's end,
    /// so blank lines after a closing fence never form a piece of their own. Prose resumes there.
    private mutating func finishClosedPiece(at end: Int, _ input: inout Input, _ out: inout Output) {
        guard block != nil else { return }
        if block!.fenceDone {
            let main = block!.main
            emit(
                Piece(
                    raw: main.pieceStart..<end,
                    content: main.contentStart..<max(main.contentStart, min(main.contentEnd, end)),
                    shape: block!.mode.shape, closed: true), &input, &out)
            block!.fenceDone = false
            block!.mode = .prose
            block!.main = Cutter(
                pieceStart: end, contentStart: end, budget: input.limits.maximum, preferColumnZero: true)
        }
        if block!.shadowDone, let shadow = block!.shadow {
            let cutter = shadow.cutter
            output(
                Piece(
                    raw: cutter.pieceStart..<end,
                    content: cutter.contentStart..<max(cutter.contentStart, min(cutter.contentEnd, end)),
                    shape: shadow.shape, closed: true), &input, &out)
            block!.main.advance(to: end)
            block!.adopted = false
            block!.shadow = nil
            block!.shadowDone = false
        }
    }

    // MARK: Chunking

    private mutating func registerBoundary(at offset: Int, _ input: inout Input) {
        guard let current = block, offset > current.start, offset < input.count else { return }
        let columnZero = !isSpaceLike(input[offset])
        if case .prose = current.mode {
            if !container.isOpen, nested == nil { block!.main.boundary(offset, columnZero: columnZero) }
        } else {
            block!.main.boundary(offset, columnZero: columnZero)
        }
        if let shadow = current.shadow, offset > shadow.start {
            block!.shadow!.cutter.boundary(offset, columnZero: false)
        }
    }

    private mutating func consume(_ range: Range<Int>, _ input: inout Input, _ out: inout Output) {
        guard !range.isEmpty else { return }
        input.scanned(range.count)
        var event = nextEvent(input.limits)
        for offset in range {
            if offset >= event {
                handleEvents(at: offset, &input, &out)
                event = nextEvent(input.limits)
            }
            let byte = input[offset]
            if byte == space || byte == tab { lastSpaceEnd = offset + 1 }
        }
    }

    private func nextEvent(_ limits: SegmentLimits) -> Int {
        guard let current = block else { return .max }
        var event = current.oversized ? Int.max : current.start + limits.maximum
        if !current.adopted { event = min(event, current.main.limit) }
        if let shadow = current.shadow { event = min(event, shadow.cutter.limit) }
        return event
    }

    /// Decisions due when the byte at `offset` arrives and belongs to the current block.
    private mutating func handleEvents(at offset: Int, _ input: inout Input, _ out: inout Output) {
        if !block!.oversized, offset - block!.start >= input.limits.maximum { becomeOversized(&input, &out) }
        if !block!.adopted, offset == block!.main.limit {
            if case .prose = block!.mode, let shadow = block!.shadow, shadow.start == block!.main.contentStart {
                adopt(&input, &out)
            } else {
                let main = block!.main
                let cut = main.cut(at: offset, lastSpaceEnd: lastSpaceEnd, &input)
                emit(
                    Piece(
                        raw: main.pieceStart..<cut, content: main.contentStart..<cut, shape: block!.mode.shape,
                        closed: true), &input, &out)
                block!.main.advance(to: cut)
            }
        }
        if let shadow = block!.shadow, offset == shadow.cutter.limit {
            let cut = shadow.cutter.cut(at: offset, lastSpaceEnd: lastSpaceEnd, &input)
            let piece = Piece(
                raw: shadow.cutter.pieceStart..<cut, content: shadow.cutter.contentStart..<cut, shape: shadow.shape,
                closed: true)
            if block!.adopted {
                output(piece, &input, &out)
            } else {
                block!.shadow!.pending.append(piece)
            }
            block!.shadow!.cutter.advance(to: cut)
        }
    }

    private mutating func becomeOversized(_ input: inout Input, _ out: inout Output) {
        block!.oversized = true
        if let current = group { emitGroup(current, &input, &out) }
        group = nil
        let pending = block!.pending
        block!.pending = []
        for piece in pending { output(piece, &input, &out) }
    }

    private mutating func adopt(_ input: inout Input, _ out: inout Output) {
        block!.adopted = true
        let pending = block!.shadow!.pending
        block!.shadow!.pending = []
        for piece in pending { output(piece, &input, &out) }
    }

    private mutating func emit(_ piece: Piece, _ input: inout Input, _ out: inout Output) {
        if block!.oversized {
            output(piece, &input, &out)
        } else {
            block!.pending.append(piece)
        }
    }

    private mutating func output(_ piece: Piece, _ input: inout Input, _ out: inout Output) {
        let body: [UInt8]
        switch piece.shape {
        case .prose, .verbatim:
            body = input.copy(piece.raw)
        case .table(let header):
            body = header + input.copy(piece.content)
        case .fence(let plan):
            body = Self.fenceBody(plan, content: piece.content, closed: piece.closed, &input)
        }
        let kind = piece.shape.kind
        out.segments.append(
            StoredSegment(
                range: piece.raw, body: String(decoding: body, as: UTF8.self), kind: kind,
                acceptsDefinitions: kind != .verbatimPiece, continues: block!.emitted > 0))
        block!.emitted += 1
    }

    /// The rebuilt opener, the code with up to `strip` spaces of indentation removed from each
    /// line, and the closing fence.
    private static func fenceBody(_ plan: FencePlan, content: Range<Int>, closed: Bool, _ input: inout Input)
        -> [UInt8]
    {
        var body = plan.opener
        body.reserveCapacity(plan.opener.count + content.count + plan.closing.count + 1)
        var index = content.lowerBound
        var lineStart =
            content.lowerBound == plan.contentStart
            || (content.lowerBound > 0 && input[content.lowerBound - 1] == newline)
        while index < content.upperBound {
            if lineStart {
                var stripped = 0
                while stripped < plan.strip, index < content.upperBound, input[index] == space {
                    index += 1
                    stripped += 1
                }
                lineStart = false
                continue
            }
            let byte = input[index]
            body.append(byte)
            if byte == newline { lineStart = true }
            index += 1
        }
        if !content.isEmpty, body.last != newline { body.append(newline) }
        if closed { body += plan.closing }
        input.work.copiedBytes += body.count
        return body
    }

    // MARK: Artifacts

    /// Whether the document is an HTML or SVG artifact; nil until the first bytes decide it.
    static func artifactDecision(_ input: inout Input) -> Bool? {
        var index = 0
        while index < input.count, isSpaceLike(input[index]) { index += 1 }
        input.scanned(index)
        guard index < input.count else {
            return input.isFinal || index > input.limits.maximum ? false : nil
        }
        var head: [UInt8] = []
        while index < input.count, head.count < 14 {
            head.append(lower(input[index]))
            index += 1
        }
        input.scanned(head.count)
        if artifactPrefixes.contains(where: { head.starts(with: $0) }) { return true }
        if !input.isFinal, artifactPrefixes.contains(where: { head.count < $0.count && $0.starts(with: head) }) {
            return nil
        }
        return false
    }
}

private let artifactPrefixes = ["<!doctype html", "<html", "<svg"].map { Array($0.utf8) }

// MARK: - Line syntax

private enum Scan {
    /// The line at `start`, or nil while its role is undecided (it may still grow and is not
    /// longer than the maximum). With `provisional`, the last line ends at the end of the source.
    static func line(at start: Int, _ input: inout Input, provisional: Bool) -> Line? {
        let window = min(input.count, start + input.limits.maximum + 1)
        var index = start
        while index < window, input[index] != newline { index += 1 }
        input.scanned(index - start + 1)
        if index < window { return Line(start: start, end: index, next: index + 1, isLong: false) }
        if window - start > input.limits.maximum { return Line(start: start, end: window, next: window, isLong: true) }
        guard provisional || input.isFinal else { return nil }
        return Line(start: start, end: input.count, next: input.count, isLong: false)
    }

    static func facts(_ line: Line, _ input: inout Input) -> Facts {
        let blank = isBlank(line.range, &input)
        let columnZero = line.start < line.end && !isSpaceLike(input[line.start])
        let fence = blank ? nil : fenceOpener(line.range, &input)
        let marker = columnZero && fence == nil ? listMarker(line.range, &input) : nil
        return Facts(blank: blank, columnZero: columnZero, fence: fence, listMarker: marker)
    }

    static func isBlank(_ range: Range<Int>, _ input: inout Input) -> Bool {
        var index = range.lowerBound
        while index < range.upperBound, isSpaceLike(input[index]) { index += 1 }
        input.scanned(index - range.lowerBound + 1)
        return index == range.upperBound
    }

    /// First non-space offset when the line is indented by at most three spaces.
    static func contentStart(_ range: Range<Int>, _ input: Input) -> Int? {
        var index = range.lowerBound
        while index < range.upperBound, input[index] == space, index - range.lowerBound < 4 { index += 1 }
        guard index - range.lowerBound <= 3, index == range.upperBound || input[index] != tab else { return nil }
        return index
    }

    static func fenceOpener(_ range: Range<Int>, _ input: inout Input) -> FenceOpener? {
        guard let start = contentStart(range, input), start < range.upperBound else { return nil }
        return fenceRun(at: start, lineStart: range.lowerBound, end: range.upperBound, &input)
    }

    /// A run of three or more backticks or tildes at `start`; a backtick fence's info string has
    /// no backticks.
    static func fenceRun(at start: Int, lineStart: Int, end: Int, _ input: inout Input) -> FenceOpener? {
        let marker = input[start]
        guard marker == backtick || marker == tilde else { return nil }
        var index = start
        while index < end, input[index] == marker { index += 1 }
        guard index - start >= 3 else { return nil }
        input.scanned(end - start)
        if marker == backtick, input.bytes[index..<end].contains(backtick) { return nil }
        return FenceOpener(marker: marker, length: index - start, indent: start - lineStart, info: index..<end)
    }

    static func isFenceCloser(_ range: Range<Int>, marker: UInt8, minimum: Int, _ input: inout Input) -> Bool {
        guard let start = contentStart(range, input) else { return false }
        var index = start
        while index < range.upperBound, input[index] == marker { index += 1 }
        return index - start >= minimum && isBlank(index..<range.upperBound, &input)
    }

    /// A fence behind four or more spaces, a quote marker or a list marker: a fence nested in a
    /// list item or quote. It protects its lines from cuts but never suppresses block starts.
    static func nestedFence(_ range: Range<Int>, _ input: inout Input) -> NestedFence? {
        input.scanned(range.count)
        let end = range.upperBound
        var index = range.lowerBound
        var tabs = false
        func skipSpaces() -> Int {
            var count = 0
            while index < end, input[index] == space || input[index] == tab {
                if input[index] == tab { tabs = true }
                index += 1
                count += 1
            }
            return count
        }
        let leading = skipSpaces()
        var depth = 0
        while index < end, input[index] == greaterThan {
            depth += 1
            index += 1
            _ = skipSpaces()
        }
        var listPrefix = false
        if depth == 0, let markerEnd = listMarkerEnd(at: index, end: end, input) {
            listPrefix = true
            index = markerEnd
            _ = skipSpaces()
        }
        guard leading >= 4 || depth > 0 || listPrefix, index < end,
            let opener = fenceRun(at: index, lineStart: range.lowerBound, end: end, &input)
        else { return nil }
        return NestedFence(opener: opener, quoteDepth: depth, rebuildable: depth == 0 && !tabs)
    }

    static func isNestedCloser(_ range: Range<Int>, _ fence: NestedFence, _ input: inout Input) -> Bool {
        input.scanned(range.count)
        let end = range.upperBound
        var index = range.lowerBound
        func skipSpaces() { while index < end, input[index] == space || input[index] == tab { index += 1 } }
        skipSpaces()
        for _ in 0..<fence.quoteDepth {
            guard index < end, input[index] == greaterThan else { return false }
            index += 1
            skipSpaces()
        }
        let start = index
        while index < end, input[index] == fence.opener.marker { index += 1 }
        return index - start >= fence.opener.length && isBlank(index..<end, &input)
    }

    /// How a fence is rebuilt in each piece, or nil when even a bare fence exceeds the budget.
    static func fencePlan(_ line: Line, _ fence: FenceOpener, _ input: inout Input) -> FencePlan? {
        let run = [UInt8](repeating: fence.marker, count: fence.length)
        let closing = run + [newline]
        var info = fence.info
        while info.lowerBound < info.upperBound, isSpaceLike(input[info.lowerBound]) {
            info = (info.lowerBound + 1)..<info.upperBound
        }
        while info.lowerBound < info.upperBound, isSpaceLike(input[info.upperBound - 1]) {
            info = info.lowerBound..<(info.upperBound - 1)
        }
        var options: [Range<Int>] = [info]
        if let wordEnd = input.bytes[info].firstIndex(where: { $0 == space || $0 == tab }) {
            options.append(info.lowerBound..<wordEnd)
        }
        if !info.isEmpty { options.append(info.lowerBound..<info.lowerBound) }
        for option in options where run.count + option.count + 1 + closing.count <= input.limits.syntax {
            return FencePlan(
                opener: run + input.copy(option) + [newline], closing: closing, strip: fence.indent,
                contentStart: line.next)
        }
        return nil
    }

    static func htmlTerminator(_ range: Range<Int>, _ input: inout Input) -> [UInt8]? {
        guard let start = contentStart(range, input), start < range.upperBound, input[start] == lessThan else {
            return nil
        }
        let line = input.bytes[start..<range.upperBound]
        if line.starts(with: commentOpen) {
            return contains(commentClose, in: (start + 4)..<range.upperBound, &input) ? nil : commentClose
        }
        for (open, close) in htmlBlockTags {
            guard line.count >= open.count, zip(line, open).allSatisfy({ lower($0) == $1 }) else { continue }
            let after = start + open.count
            guard after == range.upperBound || [space, tab, greaterThan].contains(input[after]) else { continue }
            return contains(close, in: start..<range.upperBound, &input) ? nil : close
        }
        return nil
    }

    /// Case-insensitive search for a lowercase needle.
    static func contains(_ needle: [UInt8], in range: Range<Int>, _ input: inout Input) -> Bool {
        input.scanned(range.count)
        guard !needle.isEmpty, range.count >= needle.count else { return false }
        var index = range.lowerBound
        while index + needle.count <= range.upperBound {
            var offset = 0
            while offset < needle.count, lower(input[index + offset]) == needle[offset] { offset += 1 }
            if offset == needle.count { return true }
            index += 1
        }
        return false
    }

    static func isMathFence(_ range: Range<Int>, _ input: inout Input) -> Bool {
        guard let start = contentStart(range, input) else { return false }
        return input.bytes[start..<range.upperBound].starts(with: [dollar, dollar])
    }

    static func isSingleLineMath(_ range: Range<Int>, _ input: inout Input) -> Bool {
        guard let start = contentStart(range, input) else { return false }
        var end = range.upperBound
        while end > start, isSpaceLike(input[end - 1]) { end -= 1 }
        input.scanned(range.upperBound - end + 2)
        return end - start >= 4 && input[end - 1] == dollar && input[end - 2] == dollar
    }

    static func containsPipe(_ range: Range<Int>, _ input: inout Input) -> Bool {
        input.scanned(range.count)
        return input.bytes[range].contains(pipe)
    }

    /// A line that could head a table (checked before its delimiter row is known).
    static func mayBeTableHeader(_ range: Range<Int>, _ input: inout Input) -> Bool {
        containsPipe(range, &input)
    }

    static func isTableDelimiter(_ range: Range<Int>, _ input: inout Input) -> Bool {
        input.scanned(range.count)
        let line = input.bytes[range]
        guard line.contains(pipe), line.contains(hyphen) else { return false }
        return line.allSatisfy { [pipe, colon, hyphen, space, tab, carriageReturn].contains($0) }
    }

    /// The marker of a column-0 list item, excluding thematic breaks.
    static func listMarker(_ range: Range<Int>, _ input: inout Input) -> ListMarker? {
        guard let end = listMarkerEnd(at: range.lowerBound, end: range.upperBound, input) else { return nil }
        let marker = input[end - 1] == space || input[end - 1] == tab ? input[end - 2] : input[end - 1]
        if marker == hyphen || marker == asterisk || marker == plus {
            if isThematicBreak(range, &input) { return nil }
            return .bullet(marker)
        }
        return .ordered(marker)
    }

    /// The offset after a list marker and its following space at `start`, if there is one.
    static func listMarkerEnd(at start: Int, end: Int, _ input: Input) -> Int? {
        guard start < end else { return nil }
        var index = start
        let first = input[index]
        if first == hyphen || first == asterisk || first == plus {
            index += 1
        } else {
            while index < end, index - start < 9, (48...57).contains(input[index]) { index += 1 }
            guard index > start, index < end, input[index] == period || input[index] == closeParen else {
                return nil
            }
            index += 1
        }
        if index == end { return index }
        guard input[index] == space || input[index] == tab else { return nil }
        return index + 1
    }

    static func isThematicBreak(_ range: Range<Int>, _ input: inout Input) -> Bool {
        input.scanned(range.count)
        guard let first = input.bytes[range].first(where: { $0 != space && $0 != tab }),
            first == hyphen || first == asterisk || first == underscore
        else { return false }
        var count = 0
        for byte in input.bytes[range] {
            if byte == first {
                count += 1
            } else if !isSpaceLike(byte) {
                return false
            }
        }
        return count >= 3
    }

    /// A reference-style link definition line (`[label]: destination`), trimmed.
    static func definition(_ range: Range<Int>, _ input: inout Input) -> [UInt8]? {
        input.scanned(range.count)
        guard let start = contentStart(range, input), start + 1 < range.upperBound, input[start] == openBracket,
            input[start + 1] != caret
        else { return nil }
        var close = start + 1
        while close < range.upperBound, input[close] != closeBracket { close += 1 }
        guard close + 2 < range.upperBound, input[close + 1] == colon else { return nil }
        var end = range.upperBound
        while end > close + 2, isSpaceLike(input[end - 1]) { end -= 1 }
        guard end > close + 2, end - start <= MarkdownSegmenter.definitionLimit else { return nil }
        return input.copy(start..<end)
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
private let asterisk = UInt8(ascii: "*")
private let plus = UInt8(ascii: "+")
private let underscore = UInt8(ascii: "_")
private let period = UInt8(ascii: ".")
private let closeParen = UInt8(ascii: ")")
private let colon = UInt8(ascii: ":")
private let dollar = UInt8(ascii: "$")
private let lessThan = UInt8(ascii: "<")
private let greaterThan = UInt8(ascii: ">")
private let openBracket = UInt8(ascii: "[")
private let closeBracket = UInt8(ascii: "]")
private let caret = UInt8(ascii: "^")

private let commentOpen = Array("<!--".utf8)
private let commentClose = Array("-->".utf8)
private let htmlBlockTags = ["pre", "script", "style", "textarea"].map {
    (Array("<\($0)".utf8), Array("</\($0)>".utf8))
}

private func lower(_ byte: UInt8) -> UInt8 {
    (65...90).contains(byte) ? byte + 32 : byte
}

private func isSpaceLike(_ byte: UInt8) -> Bool {
    byte == space || byte == tab || byte == newline || byte == carriageReturn
}
