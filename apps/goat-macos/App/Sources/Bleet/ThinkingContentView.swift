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
    /// Past this many blocks the source stays prose: segments bound its layout either way (#60 A1).
    static let maximumBlocks = 4_096

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

    /// A fence's language as segments keep it: the info string's first word, bounded. The highlighter
    /// reads nothing else, so an unbounded info string is never retained.
    static func language(_ info: String?) -> String? {
        info.map { String($0.prefix(maximumLanguageCharacters).prefix(while: { !$0.isWhitespace })) }
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
    let segments: [ThinkingSegment]
    /// UTF-8 bytes of every segment's text.
    let bytes: Int
    /// What caches charge: every segment's `cost`.
    let cost: Int
    /// The segments laid out; nil when every segment is.
    var window: Range<Int>? = nil

    init(revision: TextRevision, segments: [ThinkingSegment]) {
        self.revision = revision
        self.segments = segments
        bytes = segments.reduce(0) { $0 + $1.bytes }
        cost = segments.reduce(0) { $0 + $1.cost }
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
/// Lines before the last non-blank line are final: each is parsed once and its completed segments are
/// kept. A refresh parses the lines completed since the last one, then the last line and the open
/// piece on a copy, so its work is bounded by the appended bytes, the last line and one piece, not
/// by the reasoning. Extend it only with text that extends the text it last saw (an append
/// revision); an edit or trim starts a new one.
struct ThinkingSegmentation {
    /// UTF-8 bytes parsed since this segmentation was created: completed lines once each, and every
    /// refresh's last line.
    private(set) var scannedBytes = 0
    private var state = LineState()
    /// UTF-8 offset of the first non-blank line, once there is one.
    private var start: Int?
    /// UTF-8 offset up to which lines are parsed into `state`: the start of the last non-blank line.
    private var committed = 0

    mutating func extend(to source: String) -> [ThinkingSegment] {
        let utf8 = source.utf8
        var lower = utf8.index(utf8.startIndex, offsetBy: min(committed, utf8.count))
        if start == nil {
            // Leading blank lines are trimmed. An unterminated blank line can still gain text.
            while let lineEnd = source[lower...].firstIndex(of: "\n"),
                source[lower..<lineEnd].allSatisfy(\.isWhitespace)
            {
                lower = source.index(after: lineEnd)
            }
            committed = utf8.distance(from: utf8.startIndex, to: lower)
            guard !source[lower...].allSatisfy(\.isWhitespace) else { return [] }
            start = committed
        }
        // Trailing blank lines are trimmed with the line break before them. The line at `lower` was
        // the last non-blank line, and appending keeps it non-blank.
        var end = source.endIndex
        while lower < end {
            let newline = source[lower..<end].lastIndex(of: "\n")
            let lineStart = newline.map { source.index(after: $0) } ?? lower
            guard source[lineStart..<end].allSatisfy(\.isWhitespace) else { break }
            end = newline ?? lower
        }
        guard lower < end else {
            // Not an extension of the text last seen: start again.
            self = ThinkingSegmentation()
            return extend(to: source)
        }
        let lastLine = source[lower..<end].lastIndex(of: "\n").map { source.index(after: $0) } ?? lower
        let first = utf8.index(utf8.startIndex, offsetBy: start ?? 0)
        // Lines before the last are final.
        while lower < lastLine, let lineEnd = source[lower..<lastLine].firstIndex(of: "\n") {
            let line = source[lower..<lineEnd]
            scannedBytes += line.utf8.count + 1
            if !state.feed(line, newline: true) {
                // Past the block cap everything is prose, as `ThinkingFenceParser.parse` falls back.
                state = LineState(proseOnly: true)
                refeed(source, from: first, to: source.index(after: lineEnd))
            }
            lower = source.index(after: lineEnd)
        }
        committed = utf8.distance(from: utf8.startIndex, to: lastLine)
        // The last line can still change, so it is parsed on a copy.
        let line = source[lastLine..<end]
        scannedBytes += line.utf8.count
        var tail = state
        guard tail.feed(line, newline: false) else {
            let text = String(source[first..<end])
            scannedBytes += text.utf8.count
            return ThinkingSegmenter.segments([ThinkingFenceParser.Block(text: text, language: nil)])
        }
        tail.endBlock()
        return tail.segments
    }

    private mutating func refeed(_ source: String, from lower: String.Index, to upper: String.Index) {
        var cursor = lower
        while cursor < upper, let lineEnd = source[cursor..<upper].firstIndex(of: "\n") {
            let line = source[cursor..<lineEnd]
            scannedBytes += line.utf8.count + 1
            _ = state.feed(line, newline: true)
            cursor = source.index(after: lineEnd)
        }
    }

    /// The parser's and segmenter's state after whole lines: the steps of `ThinkingFenceParser.parse`
    /// and `ThinkingSegmenter.pieces`, one line at a time.
    private struct LineState {
        var proseOnly = false
        var segments: [ThinkingSegment] = []
        var opening: ThinkingFenceParser.Fence?
        /// The open block's language, as segments keep it; nil for prose.
        var language: String?
        var blockCount = 0
        var blockPieces = 0
        var piece = ""
        var pieceBytes = 0

        /// Parses one line; false once the blocks reach `ThinkingFenceParser.maximumBlocks`.
        mutating func feed(_ line: Substring, newline: Bool) -> Bool {
            let text = String(line)
            let ending = newline ? "\n" : ""
            if proseOnly {
                add(text + ending)
                return true
            }
            if let active = opening {
                if let candidate = ThinkingFenceParser.fence(in: text), candidate.marker == active.marker,
                    candidate.count >= active.count, candidate.quoteDepth == active.quoteDepth,
                    candidate.info.isEmpty
                {
                    endBlock()
                    opening = nil
                    language = nil
                } else {
                    add(ThinkingFenceParser.codeLine(text, fence: active) + ending)
                }
            } else if let candidate = ThinkingFenceParser.fence(in: text) {
                endBlock()
                opening = candidate
                language = ThinkingSegmenter.language(candidate.info)
            } else {
                add(text + ending)
            }
            return blockCount < ThinkingFenceParser.maximumBlocks
        }

        /// Ends the open block, when it has text, as the parser flushes a non-empty buffer.
        mutating func endBlock() {
            guard blockPieces > 0 || !piece.isEmpty else { return }
            flushPiece()
            blockCount += 1
            blockPieces = 0
        }

        private mutating func add(_ full: String) {
            let limit = max(4, ThinkingSegmenter.targetBytes)
            let bytes = full.utf8.count
            if bytes > limit {
                flushPiece()
                for part in (try? TranscriptTextParts.split(full, maximumBytes: limit)) ?? [full] { emit(part) }
            } else {
                if pieceBytes + bytes > limit { flushPiece() }
                piece += full
                pieceBytes += bytes
            }
        }

        private mutating func flushPiece() {
            guard !piece.isEmpty else { return }
            emit(piece)
            piece = ""
            pieceBytes = 0
        }

        private mutating func emit(_ text: String) {
            segments.append(
                ThinkingSegment(
                    index: segments.count, text: text, language: language, continuesPrevious: blockPieces > 0,
                    bytes: text.utf8.count))
            blockPieces += 1
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
        let segments = segmentation.extend(to: source)
        streams[id] = Stream(revision: revision, segmentation: segmentation, access: access)
        while streams.count > Self.maximumStreams,
            let victim = streams.min(by: { $0.value.access < $1.value.access })?.key
        {
            streams[victim] = nil
        }
        return PreparedThinking(revision: revision, segments: segments)
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
    @State private var segments: [ThinkingSegment] = []

    var body: some View {
        ThinkingSegmentsView(segments: segments)
            .task(id: source) {
                guard let prepared = try? await ThinkingPreparation.shared.segments(source), !Task.isCancelled
                else { return }
                segments = prepared
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
        Group {
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
    let segments: [ThinkingSegment]
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
