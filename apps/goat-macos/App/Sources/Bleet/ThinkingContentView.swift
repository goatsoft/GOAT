import Bleet
import Foundation
import HighlightKit
import SwiftUI

/// Fences in reasoning are formatting, not interactive artifacts. Keep prose unchanged and
/// present code without fence markers, cards, toolbars or line-number gutters.
enum ThinkingFenceParser {
    struct Block: Equatable, Sendable {
        let text: String
        /// nil is prose; an empty language is an unlabelled, plain monospaced block.
        let language: String?
    }

    struct Fence {
        let marker: Character
        let count: Int
        let quoteDepth: Int
        let indent: Int
        let info: String
    }

    static let maximumBytes = ReplyWindow.richLimit
    /// Past this many blocks the rest of the source is prose, so pathological fences stay bounded.
    static let maximumBlocks = 4_096

    static func parse(_ source: String) -> [Block] {
        guard source.utf8.count <= maximumBytes else { return [Block(text: source, language: nil)] }
        var blocks: [Block] = []
        var opening: Fence?
        var proseOnly = false
        var buffer = ""
        func flush(language: String?) {
            if !buffer.isEmpty { blocks.append(Block(text: buffer, language: language)) }
            buffer = ""
        }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in lines.enumerated() {
            let line = String(rawLine)
            let newline = index < lines.count - 1 ? "\n" : ""
            if proseOnly {
                buffer += line + newline
            } else if let active = opening {
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
            if !proseOnly, blocks.count >= maximumBlocks {
                proseOnly = true
                opening = nil
            }
        }
        // An unfinished fence is code too: don't flash raw delimiters while tokens arrive.
        flush(language: opening?.info)
        return blocks
    }

    static func isFenceLine(_ line: String) -> Bool { fence(in: line) != nil }

    static func fence(in line: String) -> Fence? {
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

    static func codeLine(_ line: String, fence: Fence) -> String {
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

/// One bounded piece of reasoning (#60 A1): prose or code from a single block, split at line
/// boundaries so no piece lays out more than `ThinkingSegmenter.targetBytes`.
struct ThinkingSegment: Equatable, Sendable {
    let index: Int
    let text: String
    /// nil is prose; an empty language is an unlabelled, plain monospaced block.
    let language: String?
    /// A later piece of the same block, which joins the piece before it without a gap.
    let continuesPrevious: Bool
    let bytes: Int

    /// What caches charge for retaining this segment: its text, its language and its own storage.
    var cost: Int { bytes + (language?.utf8.count ?? 0) + MemoryLayout<ThinkingSegment>.stride }
}

/// Splits parsed reasoning into bounded segments (#60 A1, ADR-0091). Joining the segments' text
/// reproduces the blocks' text exactly.
enum ThinkingSegmenter {
    static let targetBytes = MarkdownSegmenter.targetBytes
    static let maximumLanguageCharacters = 32
    static let maximumLanguageScalars = 128

    /// A fence's language as segments keep it: the info string's first word, bounded. The highlighter
    /// reads nothing else, so an unbounded info string is never retained.
    static func language(_ info: String?) -> String? {
        info.map { language(scalars: $0.unicodeScalars) }
    }

    /// The language of an info string given as scalars, which may still end in whitespace: its first
    /// word within its first `maximumLanguageScalars` scalars and `maximumLanguageCharacters` characters.
    static func language<Scalars: Sequence<Unicode.Scalar>>(scalars: Scalars) -> String {
        var head = String.UnicodeScalarView()
        head.append(
            contentsOf: scalars.lazy.drop(while: { CharacterSet.whitespacesAndNewlines.contains($0) })
                .prefix(maximumLanguageScalars))
        return String(String(head).prefix(maximumLanguageCharacters).prefix(while: { !$0.isWhitespace }))
    }

    static func segments(_ blocks: [ThinkingFenceParser.Block], targetBytes: Int = targetBytes) -> [ThinkingSegment] {
        var segments: [ThinkingSegment] = []
        for block in blocks {
            for (offset, piece) in pieces(block.text, targetBytes: targetBytes).enumerated() {
                segments.append(
                    ThinkingSegment(
                        index: segments.count, text: piece, language: language(block.language),
                        continuesPrevious: offset > 0, bytes: piece.utf8.count))
            }
        }
        return segments
    }

    /// `text` as whole lines within `targetBytes` each; a longer line is split at scalar boundaries.
    static func pieces(_ text: String, targetBytes: Int = targetBytes) -> [String] {
        let limit = max(4, targetBytes)
        guard text.utf8.count > limit else { return [text] }
        var pieces: [String] = []
        var piece = ""
        var pieceBytes = 0
        func flush() {
            if !piece.isEmpty { pieces.append(piece) }
            piece = ""
            pieceBytes = 0
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (offset, line) in lines.enumerated() {
            let full = offset < lines.count - 1 ? String(line) + "\n" : String(line)
            let bytes = full.utf8.count
            if bytes > limit {
                flush()
                pieces.append(contentsOf: (try? TranscriptTextParts.split(full, maximumBytes: limit)) ?? [full])
            } else {
                if pieceBytes + bytes > limit { flush() }
                piece += full
                pieceBytes += bytes
            }
        }
        flush()
        return pieces
    }
}

/// Expanded reasoning prepared as bounded segments (#60 A1), and the window of them laid out.
struct PreparedThinking: Sendable {
    /// The reasoning revision prepared. Views and caches match it instead of comparing text.
    let revision: TextRevision
    let segments: ChunkedList<ThinkingSegment>
    /// UTF-8 bytes of every segment's text.
    let bytes: Int
    /// What caches charge: every segment's `cost`.
    let cost: Int
    /// The segments laid out; nil when every segment is.
    var window: Range<Int>? = nil

    init(revision: TextRevision, segments: ChunkedList<ThinkingSegment>, bytes: Int, cost: Int) {
        self.revision = revision
        self.segments = segments
        self.bytes = bytes
        self.cost = cost
    }

    init(revision: TextRevision, segments: some Sequence<ThinkingSegment>) {
        let list = ChunkedList(segments)
        self.init(
            revision: revision, segments: list, bytes: list.reduce(0) { $0 + $1.bytes },
            cost: list.reduce(0) { $0 + $1.cost })
    }

    var shownSegments: Range<Int> { window ?? 0..<segments.count }

    /// The window `request` shows of these segments, or nil for every segment.
    func resolve(_ request: SegmentWindow) -> Range<Int>? {
        request.resolve(count: segments.count, cost: { segments[$0].bytes })
    }
}

/// Parses and segments reasoning as it streams (#60 A1). The result equals
/// `ThinkingSegmenter.segments(ThinkingFenceParser.parse(TranscriptText.removingBoundaryBlankLines(source)))`.
///
/// Each refresh lexes only the characters appended since the last one, one at a time, plus the
/// source's last character, which can still combine with text appended later and so is lexed on a
/// copy. Fence syntax is recognised as the characters arrive, and a line's text is split into parts
/// as it grows, so a long unfinished line is never lexed again: its parts are kept once the line is
/// certainly text. The last non-blank line stays open, because trailing blank lines are trimmed with
/// the line break before them. A refresh copies at most one open piece and one chunk of segments.
/// Extend it only with text that extends the text it last saw (an append revision); an edit or trim
/// starts a new one.
struct ThinkingSegmentation {
    /// Work since this segmentation was created: deterministic counters for tests.
    struct Work: Equatable, Sendable {
        /// UTF-8 bytes lexed, counting each refresh's held-back last character again, and a line's
        /// leading blanks and the blank lines kept inside the reasoning twice.
        var lexedBytes = 0
        /// Segments built, and bytes copied into segment text, final or provisional.
        var builtSegments = 0
        var builtBytes = 0
    }

    /// The segments of the text so far, their text's UTF-8 bytes and what caches charge for them.
    typealias Output = (segments: ChunkedList<ThinkingSegment>, bytes: Int, cost: Int)

    private(set) var work = Work()
    /// Everything before `line`, and the parts of `line` already final.
    private var state = LineState()
    /// The last non-blank line so far; nil before the first.
    private var line: PendingLine?
    /// UTF-8 offset lexed up to: a character boundary before the last character seen.
    private var lexed = 0
    /// Where the line being lexed starts while it is blank so far and not `line`.
    private var blankStart: Int? = 0
    /// Blank lines after `line`, without their line breaks: trimmed unless a non-blank line follows.
    private var blankLines: [Range<Int>] = []

    /// The segments of `source`, which extends the text last seen.
    mutating func extend(to source: String) -> Output {
        let utf8 = source.utf8
        guard lexed <= utf8.count else {
            self = ThinkingSegmentation()
            return extend(to: source)
        }
        var index = utf8.index(utf8.startIndex, offsetBy: lexed)
        var offset = lexed
        while index < source.endIndex {
            let next = source.index(after: index)
            guard next < source.endIndex else { break }
            consume(source[index], at: offset, in: source)
            offset += utf8.distance(from: index, to: next)
            index = next
        }
        lexed = offset
        // The last character can still combine with text appended later.
        var open = self
        if index < source.endIndex { open.consume(source[index], at: offset, in: source) }
        let result = open.finish(source)
        work = open.work
        return result
    }

    private mutating func consume(_ character: Character, at offset: Int, in source: String) {
        let size = character.utf8.count
        work.lexedBytes += size
        if let start = blankStart {
            if character == "\n" {
                // Blank lines before the first non-blank line are trimmed; later ones wait.
                if line != nil { blankLines.append(start..<offset) }
                blankStart = offset + size
            } else if !character.isWhitespace {
                begin(at: start, before: offset, in: source)
                withLine { $0.consume(character, at: offset, into: &$1, work: &$2) }
            }
        } else if character == "\n" {
            // `line` stays open while only blank lines follow it.
            line?.end = offset
            blankStart = offset + size
        } else {
            withLine { $0.consume(character, at: offset, into: &$1, work: &$2) }
        }
    }

    /// Mutates `line` in place, with the state and work its commits change.
    private mutating func withLine(_ body: (inout PendingLine, inout LineState, inout Work) -> Void) {
        guard var current = line else { return }
        line = nil
        body(&current, &state, &work)
        line = current
    }

    /// A non-blank character at `offset` makes the line from `start` the last non-blank line, so the
    /// previous one and the blank lines after it are final.
    private mutating func begin(at start: Int, before offset: Int, in source: String) {
        let utf8 = source.utf8
        if var previous = line {
            line = nil
            previous.finish(into: &state, newline: true, source: source, work: &work)
            for blank in blankLines {
                let lower = utf8.index(utf8.startIndex, offsetBy: blank.lowerBound)
                let upper = utf8.index(utf8.startIndex, offsetBy: blank.upperBound)
                work.lexedBytes += blank.count
                state.feed(String(source[lower..<upper]), newline: true, work: &work)
            }
        }
        blankLines.removeAll()
        blankStart = nil
        line = PendingLine(start: start, state: state)
        // The line's leading blanks were lexed as a blank line so far; the line lexes them again.
        var index = utf8.index(utf8.startIndex, offsetBy: start)
        let upper = utf8.index(utf8.startIndex, offsetBy: offset)
        var position = start
        while index < upper {
            let next = source.index(after: index)
            let character = source[index]
            work.lexedBytes += character.utf8.count
            withLine { $0.consume(character, at: position, into: &$1, work: &$2) }
            position += utf8.distance(from: index, to: next)
            index = next
        }
    }

    /// The segments with the last non-blank line ended, without its line break.
    private mutating func finish(_ source: String) -> Output {
        if var current = line {
            line = nil
            current.finish(into: &state, newline: false, source: source, work: &work)
            state.endBlock(work: &work)
        }
        return (state.segments, state.bytes, state.cost)
    }

    /// The steps of `ThinkingFenceParser.parse` and `ThinkingSegmenter.pieces` after whole lines.
    private struct LineState {
        var proseOnly = false
        var segments = ChunkedList<ThinkingSegment>()
        var bytes = 0
        var cost = 0
        var opening: ThinkingFenceParser.Fence?
        /// The open block's language, as segments keep it; nil for prose.
        var language: String?
        var blockCount = 0
        var blockPieces = 0
        var piece = ""
        var pieceBytes = 0

        /// Parses one whole line, as `ThinkingFenceParser.parse` does.
        mutating func feed(_ line: String, newline: Bool, work: inout Work) {
            let ending = newline ? "\n" : ""
            if proseOnly {
                add(line + ending, work: &work)
            } else if let active = opening {
                if let candidate = ThinkingFenceParser.fence(in: line), candidate.marker == active.marker,
                    candidate.count >= active.count, candidate.quoteDepth == active.quoteDepth,
                    candidate.info.isEmpty
                {
                    endBlock(work: &work)
                    opening = nil
                    language = nil
                } else {
                    add(ThinkingFenceParser.codeLine(line, fence: active) + ending, work: &work)
                }
            } else if let candidate = ThinkingFenceParser.fence(in: line) {
                endBlock(work: &work)
                opening = candidate
                language = ThinkingSegmenter.language(candidate.info)
            } else {
                add(line + ending, work: &work)
            }
            if newline { capIfNeeded() }
        }

        /// Past `ThinkingFenceParser.maximumBlocks`, the lines after this one are prose.
        mutating func capIfNeeded() {
            guard !proseOnly, blockCount >= ThinkingFenceParser.maximumBlocks else { return }
            proseOnly = true
            opening = nil
            language = nil
        }

        /// Ends the open block, when it has text, as the parser flushes a non-empty buffer.
        mutating func endBlock(work: inout Work) {
            guard blockPieces > 0 || !piece.isEmpty else { return }
            flushPiece(work: &work)
            blockCount += 1
            blockPieces = 0
        }

        /// Adds a line's text to the open block, as `ThinkingSegmenter.pieces` does.
        mutating func add(_ full: String, work: inout Work) {
            let limit = ThinkingSegmentation.limit
            guard full.utf8.count > limit else { return pack(full, work: &work) }
            flushPiece(work: &work)
            work.builtBytes += full.utf8.count
            for part in (try? TranscriptTextParts.split(full, maximumBytes: limit)) ?? [full] {
                emit(part, work: &work)
            }
        }

        /// Adds text of at most `limit` bytes to the open piece, closing the piece first when it would
        /// grow past the limit.
        mutating func pack(_ full: String, work: inout Work) {
            let size = full.utf8.count
            if pieceBytes + size > ThinkingSegmentation.limit { flushPiece(work: &work) }
            piece += full
            pieceBytes += size
            work.builtBytes += size
        }

        mutating func flushPiece(work: inout Work) {
            guard !piece.isEmpty else { return }
            emit(piece, work: &work)
            piece = ""
            pieceBytes = 0
        }

        mutating func emit(_ text: String, work: inout Work) {
            let segment = ThinkingSegment(
                index: segments.count, text: text, language: language, continuesPrevious: blockPieces > 0,
                bytes: text.utf8.count)
            segments.append(segment)
            bytes += segment.bytes
            cost += segment.cost
            blockPieces += 1
            work.builtSegments += 1
        }
    }

    static var limit: Int { max(4, ThinkingSegmenter.targetBytes) }

    /// `TranscriptTextParts.split`, a character at a time: parts of at most `limit` UTF-8 bytes.
    private struct Splitter {
        /// Closed parts not yet moved into the state, and the number closed in all.
        var closed: [String] = []
        var closedCount = 0
        var part = ""
        var partBytes = 0

        /// Whether the text is longer than `limit`, so it is split rather than packed.
        var isSplit: Bool { closedCount > 0 }

        mutating func append(_ character: Character, work: inout Work) {
            for scalar in character.unicodeScalars {
                let size = UTF8.width(scalar)
                if partBytes + size > ThinkingSegmentation.limit {
                    closed.append(part)
                    closedCount += 1
                    part = ""
                    partBytes = 0
                }
                part.unicodeScalars.append(scalar)
                partBytes += size
            }
            work.builtBytes += character.utf8.count
        }

        /// Moves the closed parts into `state`, closing its open piece first, as a split line does.
        mutating func commit(into state: inout LineState, flushed: inout Bool, work: inout Work) {
            guard !closed.isEmpty else { return }
            if !flushed {
                state.flushPiece(work: &work)
                flushed = true
            }
            for part in closed { state.emit(part, work: &work) }
            closed.removeAll()
        }

        /// Adds the whole text to `state`, as `LineState.add` does.
        mutating func finish(into state: inout LineState, flushed: inout Bool, work: inout Work) {
            guard isSplit else { return state.pack(part, work: &work) }
            commit(into: &state, flushed: &flushed, work: &work)
            if !part.isEmpty { state.emit(part, work: &work) }
        }
    }

    /// `ThinkingFenceParser.fence(in:)`, a character at a time.
    private struct FenceLexer {
        enum Phase: Equatable {
            case indent(Int)
            case quotes(afterQuote: Bool)
            case quoteIndent(Int)
            case run
            case info
            case rejected
        }

        var phase = Phase.indent(0)
        var depth = 0
        var indent = 0
        var marker: Character = "`"
        var count = 0
        /// A backtick in a backtick fence's info, which makes the line not a fence.
        var backtick = false
        /// UTF-8 offset of the info's first scalar that trimming keeps; nil while the info is blank.
        var infoStart: Int?

        /// Whether the line so far is a fence.
        var isFence: Bool {
            switch phase {
            case .run: return count >= 3
            case .info: return !backtick
            default: return false
            }
        }

        /// Whether the line can no longer become a fence.
        var neverOpens: Bool { phase == .rejected || (phase == .info && backtick) }

        /// Whether the line can no longer close `opening`.
        func neverCloses(_ opening: ThinkingFenceParser.Fence) -> Bool {
            switch phase {
            case .rejected:
                return true
            case .info:
                return backtick || infoStart != nil || marker != opening.marker || depth != opening.quoteDepth
                    || count < opening.count
            case .run:
                return marker != opening.marker || depth != opening.quoteDepth
            case .quoteIndent:
                return depth != opening.quoteDepth
            default:
                return false
            }
        }

        /// Whether the line so far closes `opening`.
        func closes(_ opening: ThinkingFenceParser.Fence) -> Bool {
            isFence && marker == opening.marker && count >= opening.count && depth == opening.quoteDepth
                && infoStart == nil
        }

        mutating func consume(_ character: Character, at offset: Int) {
            switch phase {
            case .indent(let spaces):
                if character == " ", spaces < 3 {
                    phase = .indent(spaces + 1)
                } else {
                    indent = spaces
                    if character == ">" {
                        depth = 1
                        phase = .quotes(afterQuote: true)
                    } else {
                        startRun(character)
                    }
                }
            case .quotes(let afterQuote):
                if character == ">" {
                    depth += 1
                    phase = .quotes(afterQuote: true)
                } else if afterQuote, character == " " {
                    phase = .quotes(afterQuote: false)
                } else {
                    phase = .quoteIndent(0)
                    consume(character, at: offset)
                }
            case .quoteIndent(let spaces):
                if character == " ", spaces < 3 {
                    phase = .quoteIndent(spaces + 1)
                } else {
                    indent = spaces
                    startRun(character)
                }
            case .run:
                if character == marker {
                    count += 1
                } else if count >= 3 {
                    phase = .info
                    consumeInfo(character, at: offset)
                } else {
                    phase = .rejected
                }
            case .info:
                consumeInfo(character, at: offset)
            case .rejected:
                break
            }
        }

        private mutating func startRun(_ character: Character) {
            guard character == "`" || character == "~" else {
                phase = .rejected
                return
            }
            marker = character
            count = 1
            phase = .run
        }

        private mutating func consumeInfo(_ character: Character, at offset: Int) {
            if marker == "`", character == "`" { backtick = true }
            guard infoStart == nil else { return }
            var position = offset
            for scalar in character.unicodeScalars {
                guard CharacterSet.whitespacesAndNewlines.contains(scalar) else {
                    infoStart = position
                    return
                }
                position += UTF8.width(scalar)
            }
        }
    }

    /// `ThinkingFenceParser.codeLine`'s quote and indent prefix, a character at a time.
    private enum Strip: Equatable {
        case leading(Int)
        /// Quotes consumed so far, fewer than the fence's depth.
        case quote(Int)
        /// After a quote, which may be followed by one space.
        case space(Int)
        case indent(Int)
        /// The code has started.
        case content
        /// A quote is missing, so the line is code as it is.
        case whole

        /// Whether the code is the text after the prefix, rather than the whole line, if the line
        /// ended now.
        func usesCode(depth: Int) -> Bool {
            switch self {
            case .indent, .content: return true
            case .space(let quotes): return quotes == depth
            case .leading, .quote, .whole: return false
            }
        }

        /// Consumes a character; true when it is code.
        mutating func consume(_ character: Character, depth: Int, indent: Int) -> Bool {
            switch self {
            case .leading(let spaces):
                if character == " ", spaces < 3 {
                    self = .leading(spaces + 1)
                    return false
                }
                self = .quote(0)
                return consume(character, depth: depth, indent: indent)
            case .quote(let quotes):
                guard character == ">" else {
                    self = .whole
                    return false
                }
                self = .space(quotes + 1)
                return false
            case .space(let quotes):
                if character == " " {
                    self = quotes == depth ? .indent(0) : .quote(quotes)
                    return false
                }
                self = quotes == depth ? .indent(0) : .quote(quotes)
                return consume(character, depth: depth, indent: indent)
            case .indent(let spaces):
                if character == " ", spaces < indent {
                    self = .indent(spaces + 1)
                    return false
                }
                self = .content
                return true
            case .content:
                return true
            case .whole:
                return false
            }
        }
    }

    /// The last non-blank line, lexed as it arrives.
    private struct PendingLine {
        let start: Int
        let proseOnly: Bool
        /// The fence the line is in, if any.
        let opening: ThinkingFenceParser.Fence?
        /// Where the line ends, once its line break has arrived.
        var end: Int?
        var fence = FenceLexer()
        var strip: Strip
        /// The whole line, and, in a fence, its code after the quote and indent prefix.
        var whole = Splitter()
        var code = Splitter()
        /// Whether the open piece was closed for this line's parts.
        var flushed = false

        init(start: Int, state: LineState) {
            self.start = start
            proseOnly = state.proseOnly
            opening = state.proseOnly ? nil : state.opening
            strip = (opening?.quoteDepth ?? 0) > 0 ? .leading(0) : .indent(0)
        }

        mutating func consume(_ character: Character, at offset: Int, into state: inout LineState, work: inout Work) {
            if !proseOnly { fence.consume(character, at: offset) }
            if let opening {
                // The whole line is code only if a quote is missing.
                if strip != .content { whole.append(character, work: &work) }
                if strip.consume(character, depth: opening.quoteDepth, indent: opening.indent) {
                    code.append(character, work: &work)
                }
            } else {
                whole.append(character, work: &work)
            }
            // A line that is certainly text keeps its closed parts.
            if let isCode = certainText {
                if isCode {
                    code.commit(into: &state, flushed: &flushed, work: &work)
                } else {
                    whole.commit(into: &state, flushed: &flushed, work: &work)
                }
            }
        }

        /// Whether the line is certainly text, and whether its text is `code` rather than `whole`;
        /// nil while it can still be fence syntax.
        private var certainText: Bool? {
            if proseOnly { return false }
            guard let opening else { return fence.neverOpens ? false : nil }
            guard fence.neverCloses(opening) else { return nil }
            switch strip {
            case .content: return true
            case .whole: return false
            default: return nil
            }
        }

        /// Adds the line to `state` as the parser would, with or without its line break.
        mutating func finish(into state: inout LineState, newline: Bool, source: String, work: inout Work) {
            if !proseOnly, let opening, fence.closes(opening) {
                state.endBlock(work: &work)
                state.opening = nil
                state.language = nil
            } else if !proseOnly, opening == nil, fence.isFence {
                state.endBlock(work: &work)
                state.opening = ThinkingFenceParser.Fence(
                    marker: fence.marker, count: fence.count, quoteDepth: fence.depth, indent: fence.indent, info: "")
                state.language = language(in: source)
            } else if let opening, strip.usesCode(depth: opening.quoteDepth) {
                if newline { code.append("\n", work: &work) }
                code.finish(into: &state, flushed: &flushed, work: &work)
            } else {
                if newline { whole.append("\n", work: &work) }
                whole.finish(into: &state, flushed: &flushed, work: &work)
            }
            if newline { state.capIfNeeded() }
        }

        /// The opening fence's language, read from at most a bounded run of its info.
        private func language(in source: String) -> String {
            guard let infoStart = fence.infoStart else { return "" }
            let utf8 = source.utf8
            let lower = utf8.index(utf8.startIndex, offsetBy: infoStart)
            let upper = utf8.index(utf8.startIndex, offsetBy: end ?? utf8.count)
            return ThinkingSegmenter.language(scalars: source.unicodeScalars[lower..<upper])
        }
    }
}

/// Parses and segments reasoning off the main actor. Streaming reasoning keeps its segmentation per
/// message, extended while its revision only appends; at most `maximumStreams` are kept, each about
/// the size of its reasoning.
actor ThinkingPreparation {
    static let shared = ThinkingPreparation()
    static let maximumStreams = 4

    private struct Stream {
        var revision: TextRevision
        var segmentation: ThinkingSegmentation
        var access: UInt64
    }

    private var streams: [UUID: Stream] = [:]
    private var access: UInt64 = 0

    func segments(_ source: String) throws -> [ThinkingSegment] {
        try Task.checkCancellation()
        return ThinkingSegmenter.segments(ThinkingFenceParser.parse(source))
    }

    /// `source` without its boundary blank lines, as bounded segments.
    func prepare(id: UUID, source: String, revision: TextRevision) throws -> PreparedThinking {
        try Task.checkCancellation()
        access &+= 1
        // Taken out of the dictionary, so it is extended in place.
        let held = streams.removeValue(forKey: id)
        var segmentation =
            held.flatMap { revision.extends($0.revision) ? $0.segmentation : nil } ?? ThinkingSegmentation()
        let output = segmentation.extend(to: source)
        streams[id] = Stream(revision: revision, segmentation: segmentation, access: access)
        while streams.count > Self.maximumStreams,
            let victim = streams.min(by: { $0.value.access < $1.value.access })?.key
        {
            streams[victim] = nil
        }
        return PreparedThinking(revision: revision, segments: output.segments, bytes: output.bytes, cost: output.cost)
    }

    func removeAll() {
        streams.removeAll()
    }
}

/// Prepared expanded reasoning keyed by message, so reasoning already prepared renders on its first
/// frame (#60 A1). A hit requires the exact reasoning revision; `latest(for:)` serves streaming
/// reasoning its last preparation until the current one is ready. Retained under a deterministic byte
/// budget like `PreparedMarkdownDocumentCache`. Memory pressure clears it through `RenderingCaches`.
@MainActor
final class PreparedThinkingCache {
    static let shared = PreparedThinkingCache()

    struct Snapshot: Equatable {
        let entryCount: Int
        let totalCost: Int
    }

    private struct Entry {
        let thinking: PreparedThinking
        var access: UInt64
    }

    let maximumEntries: Int
    let maximumTotalCost: Int
    let maximumEntryCost: Int
    private var entries: [UUID: Entry] = [:]
    private var totalCost = 0
    private var clock: UInt64 = 0

    /// Defaults retain reasoning through `ReplyWindow.richLimit` and at most 8 MiB in all.
    init(
        maximumEntries: Int = 32, maximumTotalCost: Int = 8 * 1_024 * 1_024,
        maximumEntryCost: Int = ReplyWindow.richLimit + 512 * 1_024
    ) {
        self.maximumEntries = max(1, maximumEntries)
        self.maximumTotalCost = max(1, maximumTotalCost)
        self.maximumEntryCost = max(1, min(maximumEntryCost, maximumTotalCost))
    }

    /// The reasoning prepared from exactly `revision`.
    func thinking(for id: UUID, revision: TextRevision) -> PreparedThinking? {
        guard let entry = entries[id], entry.thinking.revision == revision else { return nil }
        return touch(id)
    }

    func latest(for id: UUID) -> PreparedThinking? {
        entries[id] == nil ? nil : touch(id)
    }

    /// Returns whether the preparation was retained. A declined store also drops the older entry.
    @discardableResult
    func store(_ thinking: PreparedThinking, for id: UUID) -> Bool {
        remove(id)
        guard thinking.cost <= maximumEntryCost else { return false }
        clock &+= 1
        entries[id] = Entry(thinking: thinking, access: clock)
        totalCost += thinking.cost
        while totalCost > maximumTotalCost || entries.count > maximumEntries,
            let victim = entries.min(by: { $0.value.access < $1.value.access })?.key
        {
            remove(victim)
        }
        return entries[id] != nil
    }

    func removeAll() {
        entries.removeAll()
        totalCost = 0
    }

    func snapshot() -> Snapshot { Snapshot(entryCount: entries.count, totalCost: totalCost) }

    private func touch(_ id: UUID) -> PreparedThinking? {
        guard var entry = entries[id] else { return nil }
        clock &+= 1
        entry.access = clock
        entries[id] = entry
        return entry.thinking
    }

    private func remove(_ id: UUID) {
        guard let old = entries.removeValue(forKey: id) else { return }
        totalCost -= old.thinking.cost
    }
}

/// A bounded reasoning excerpt, prepared off the main actor and laid out whole.
struct ThinkingContentView: View {
    let source: String
    var onPrepared: () -> Void = {}
    @State private var segments = ChunkedList<ThinkingSegment>()

    var body: some View {
        ThinkingSegmentsView(segments: segments)
            .task(id: source) {
                guard let prepared = try? await ThinkingPreparation.shared.segments(source), !Task.isCancelled
                else { return }
                segments = ChunkedList(prepared)
                onPrepared()
            }
    }
}

/// Expanded reasoning through `ReplyWindow.richLimit` (#60 A1, ADR-0091). It is prepared off the main
/// actor into bounded segments, and a window of them is laid out, as for a long answer. The
/// navigation owner pages it under `TranscriptSegmentOwner.reasoning(of:)`, independently of the
/// answer below it. Longer reasoning keeps bounded selectable text parts; the disclosure's copy action
/// copies all of it.
struct ExpandedThinkingView: View {
    @Bindable var message: ChatMessage
    var onPrepared: () -> Void = {}
    @Environment(AppModel.self) private var model
    @Environment(\.transcriptSegments) private var navigation
    @State private var snapshot: Snapshot
    @State private var prepared: PreparedThinking?
    /// A reader's window when no navigation owner hosts this view.
    @State private var localWindow: Range<Int>?

    /// The reasoning sampled with its revision, so a preparation always matches its revision. The
    /// revision identifies the text, so equality never reads it.
    private struct Snapshot: Equatable {
        let revision: TextRevision
        let source: String

        static func == (lhs: Snapshot, rhs: Snapshot) -> Bool { lhs.revision == rhs.revision }
    }

    private struct Preparation: Equatable {
        let revision: TextRevision
        let window: SegmentWindow
    }

    init(message: ChatMessage, onPrepared: @escaping () -> Void = {}) {
        self.message = message
        self.onPrepared = onPrepared
        _snapshot = State(initialValue: Snapshot(revision: message.thinkingRevision, source: message.thinking))
        // A lookup only: SwiftUI evaluates this initializer on every parent update.
        let cache = PreparedThinkingCache.shared
        _prepared = State(
            initialValue: cache.thinking(for: message.id, revision: message.thinkingRevision)
                ?? (message.complete ? nil : cache.latest(for: message.id)))
    }

    private var key: UUID { TranscriptSegmentOwner.reasoning(of: message.id) }

    /// The segments to show: the window the owner holds for this reasoning, else its latest segments.
    /// While the reader owns the viewport, the segments shown are kept, as for an answer.
    private var requestedWindow: SegmentWindow {
        guard let viewport = navigation.viewport else { return localWindow.map(SegmentWindow.segments) ?? .latest }
        if let held = viewport.segmentWindow(for: key) { return .segments(held) }
        if let kept = keptWindow { return .segments(kept) }
        return .latest
    }

    /// The shown window this reasoning keeps because the reader owns the viewport, until the owner holds it.
    private var keptWindow: Range<Int>? {
        guard let viewport = navigation.viewport, viewport.readerOwnsViewport,
            viewport.segmentWindow(for: key) == nil
        else { return nil }
        return prepared?.window
    }

    var body: some View {
        let window = requestedWindow
        // A stack, unlike an empty group, appears before anything is prepared, so its tasks run.
        VStack(alignment: .leading, spacing: 0) {
            if snapshot.revision.utf8Count > ReplyWindow.richLimit {
                TranscriptTextPartsView(
                    source: TranscriptText.removingBoundaryBlankLines(snapshot.source),
                    fontSize: model.chatFontSize - 1, cacheKey: "\(message.id.uuidString):thinking",
                    onPrepared: onPrepared)
            } else if let prepared {
                ThinkingSegmentsView(
                    segments: prepared.segments, window: prepared.window, navigationKey: key,
                    page: { page(to: $0, keeping: $1, segmentCount: $2) })
            }
        }
        .task(id: Preparation(revision: snapshot.revision, window: window)) {
            let request = snapshot
            guard request.revision.utf8Count <= ReplyWindow.richLimit else { return }
            var next = prepared
            if next?.revision != request.revision {
                guard
                    let fresh = try? await ThinkingPreparation.shared.prepare(
                        id: message.id, source: request.source, revision: request.revision),
                    !Task.isCancelled
                else { return }
                next = fresh
            }
            guard var ready = next else { return }
            ready.window = ready.resolve(window)
            let changed = ready.revision != prepared?.revision || ready.window != prepared?.window
            prepared = ready
            PreparedThinkingCache.shared.store(ready, for: message.id)
            if changed { onPrepared() }
        }
        .task(id: message.id) {
            while !message.complete {
                sample()
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
            }
            sample()
        }
        .onChange(of: message.complete) { sample() }
        .onChange(of: keptWindow, initial: true) { holdIfKept() }
    }

    /// Registers a kept window with the owner, so the owner, not this view, knows it is held.
    private func holdIfKept() {
        guard let kept = keptWindow, let prepared else { return }
        navigation.hold(key, kept, prepared.segments.count)
    }

    /// Pages the shown window to `target` of `segmentCount` segments, keeping segment `kept` where the
    /// reader sees it.
    private func page(to target: Range<Int>, keeping kept: Int, segmentCount: Int) {
        if navigation.viewport != nil {
            navigation.page(key, target, kept, segmentCount)
        } else {
            // Without an owner, a window at the end shows the latest segments again.
            localWindow = target.upperBound >= segmentCount ? nil : target
        }
    }

    private func sample() {
        let revision = message.thinkingRevision
        guard revision != snapshot.revision else { return }
        snapshot = Snapshot(revision: revision, source: message.thinking)
    }
}

/// Reasoning segments as muted prose and plain code, with loaders at a window's edges that page it
/// like a long answer's (#60 A1). Pieces of one block join without a gap.
struct ThinkingSegmentsView: View {
    let segments: ChunkedList<ThinkingSegment>
    /// The segments laid out; nil lays out every segment.
    var window: Range<Int>? = nil
    /// The key the navigation owner pages these segments under, when it hosts them.
    var navigationKey: UUID? = nil
    /// Pages the window: the new window, the segment to keep in place, and the segment count.
    var page: (_ window: Range<Int>, _ kept: Int, _ segmentCount: Int) -> Void = { _, _, _ in }
    @Environment(AppModel.self) private var model
    @Environment(\.transcriptSegments) private var navigation

    var body: some View {
        let shown = window ?? 0..<segments.count
        let isWindowed = window != nil
        VStack(alignment: .leading, spacing: 0) {
            if isWindowed, shown.lowerBound > 0 {
                SegmentLoader(label: "Earlier reasoning") {
                    page(
                        ReplyWindow.earlier(shown, count: segments.count, cost: cost), shown.lowerBound,
                        segments.count)
                }
            }
            ForEach(shown, id: \.self) { index in
                ThinkingSegmentView(
                    segment: segments[index],
                    joinsNext: index + 1 < segments.count && segments[index + 1].continuesPrevious
                )
                // Measured before the gap, in the transcript's content coordinates.
                .onGeometryChange(for: CGRect?.self, of: { isWindowed ? Self.contentFrame($0) : nil }) { frame in
                    if let navigationKey, isWindowed { navigation.recordFrame(navigationKey, index, frame, shown) }
                }
                .onDisappear {
                    if let navigationKey, isWindowed { navigation.recordFrame(navigationKey, index, nil, shown) }
                }
                .padding(.top, index == shown.lowerBound || segments[index].continuesPrevious ? 0 : 8)
            }
            if isWindowed, shown.upperBound < segments.count {
                SegmentLoader(label: "Later reasoning") {
                    page(
                        ReplyWindow.later(shown, count: segments.count, cost: cost), shown.upperBound - 1,
                        segments.count)
                }
            }
        }
        .foregroundStyle(model.theme.tokens.ink)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A held window that reached the end stops reaching it as the reasoning grows.
        .onChange(of: segments.count) { _, count in
            if let navigationKey { navigation.recordSegmentCount(navigationKey, count) }
        }
    }

    private func cost(_ index: Int) -> Int { segments[index].bytes }

    nonisolated private static func contentFrame(_ proxy: GeometryProxy) -> CGRect {
        proxy.frame(in: .named(transcriptContentSpace))
    }
}

private struct ThinkingSegmentView: View {
    let segment: ThinkingSegment
    /// The next segment continues this one, so the line break ending this one is where they join.
    let joinsNext: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let text = joinsNext && segment.text.hasSuffix("\n") ? String(segment.text.dropLast()) : segment.text
        if let language = segment.language {
            ThinkingCodeText(code: text, language: language)
                .font(Font(ReadingFonts.nsFont(model.effectiveCodeFontID, size: model.codeFontSize, role: .code)))
        } else {
            // Reasoning prose is secondary to the answer: muted and italic (DESIGN.md §3, §5).
            Text(text)
                .font(Font(ReadingFonts.nsFont(model.effectiveChatFontID, size: model.chatFontSize - 1, role: .chat)))
                .italic()
                .foregroundStyle(model.theme.tokens.muted)
                .lineSpacing(4)
        }
    }
}

actor ThinkingCodeHighlighter {
    static let shared = ThinkingCodeHighlighter()

    func render(_ code: String, language: String, dark: Bool, palette: SyntaxPalette? = nil) async throws
        -> AttributedString
    {
        let alias = language.split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased() ?? ""
        guard code.utf8.count <= HighlightedCodeView.maximumHighlightedBytes,
            !["", "text", "plain", "plaintext"].contains(alias)
        else { return AttributedString(code) }
        if alias == "vue" { return try await VueSyntaxHighlighter.shared.render(code, dark: dark, palette: palette) }
        return try await CodeSyntaxHighlighter.shared.render(code, language: alias, dark: dark, palette: palette)
    }
}

private struct ThinkingCodeText: View {
    let code: String
    let language: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.syntaxPalette) private var palette
    @State private var rendered: AttributedString?
    @State private var renderedKey: Key?
    private struct Key: Equatable {
        let code: String
        let language: String
        let dark: Bool
        let palette: SyntaxPalette?
    }

    private var currentText: AttributedString {
        let key = Key(code: code, language: language, dark: colorScheme == .dark, palette: palette)
        if renderedKey == key, let rendered {
            return rendered
        }
        // A theme change keeps the previous colours until the new ones are ready.
        if let rendered, let prevKey = renderedKey, prevKey.language == language, prevKey.code == code {
            return rendered
        }
        if let rendered, let prevKey = renderedKey,
            prevKey.language == language,
            prevKey.dark == key.dark, prevKey.palette == key.palette,
            code.hasPrefix(prevKey.code)
        {
            var combined = rendered
            let suffix = code.dropFirst(prevKey.code.count)
            combined.append(AttributedString(suffix))
            return combined
        }
        return AttributedString(code)
    }

    var body: some View {
        let key = Key(code: code, language: language, dark: colorScheme == .dark, palette: palette)
        Text(currentText)
            .fixedSize(horizontal: false, vertical: true)
            .task(id: key) {
                do {
                    // Current source stays visible while an active fence settles. Closed fences
                    // retain their highlights as later reasoning streams into other blocks.
                    try await Task.sleep(for: .milliseconds(120))
                    let result = try await ThinkingCodeHighlighter.shared.render(
                        code, language: language, dark: key.dark, palette: key.palette)
                    try Task.checkCancellation()
                    rendered = result
                    renderedKey = key
                } catch {}
            }
    }
}
