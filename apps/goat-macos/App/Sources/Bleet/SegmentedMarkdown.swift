import Bleet
import Foundation
import Hoofprint
import MarkdownUI
import SwiftUI

/// One prepared segment of a reply (#60 A1, ADR-0091).
struct PreparedMarkdownSegment: Sendable {
    let index: Int
    /// The Markdown rendered: the segment body followed by the reference definitions it was prepared
    /// with. A segment that cannot use definitions keeps its preparation when they grow, so this can
    /// carry an earlier suffix than the segmentation's.
    let text: String
    let definitionSuffix: String
    let kind: MarkdownSegment.Kind
    let continuesPrevious: Bool
    let isSettled: Bool
    /// Parsed Markdown, or `.plainText` for a verbatim piece (rendered as monospaced plain text).
    let preparation: MarkdownPreparation
    /// Identifies `preparation`: segments with the same identifier render the same content.
    let preparationID: UInt64
    /// MarkdownUI margins of the first and last block, in base font sizes (see `MarkdownSegmentSpacing`).
    let leadingMargin: Double?
    let trailingMargin: Double?
    /// While this segment is the streaming tail, whether its last leaf block is a paragraph, which then
    /// carries the caret (#60 B1); nil for any other segment.
    let endsInParagraph: Bool?
    /// Whether reference definitions can change how the segment renders. A reference always has a
    /// closing bracket, so a parsed segment without one renders the same with any definitions.
    let usesDefinitions: Bool
    /// UTF-8 bytes of the body at the start of `text`.
    let bodyBytes: Int

    func updating(isSettled: Bool, continuesPrevious: Bool, endsInParagraph: Bool?) -> PreparedMarkdownSegment {
        PreparedMarkdownSegment(
            index: index, text: text, definitionSuffix: definitionSuffix, kind: kind,
            continuesPrevious: continuesPrevious, isSettled: isSettled, preparation: preparation,
            preparationID: preparationID, leadingMargin: leadingMargin, trailingMargin: trailingMargin,
            endsInParagraph: endsInParagraph, usesDefinitions: usesDefinitions, bodyBytes: bodyBytes)
    }
}

/// Prepared segments stored in fixed-size chunks (#60 A1). A document handed to a view shares every
/// chunk with the cache, so preparing the next refresh copies only the chunk index and the chunks it
/// changes, never the whole reply's segments.
struct PreparedSegmentList: RandomAccessCollection, Sendable {
    static let chunkSize = 64
    private var chunks: [[PreparedMarkdownSegment]] = []
    private(set) var endIndex = 0
    var startIndex: Int { 0 }

    init() {}

    init(_ segments: some Sequence<PreparedMarkdownSegment>) {
        for segment in segments { set(segment, at: endIndex) }
    }

    subscript(position: Int) -> PreparedMarkdownSegment {
        chunks[position / Self.chunkSize][position % Self.chunkSize]
    }

    /// Replaces the segment at `position`, or appends when `position` is `endIndex`.
    mutating func set(_ segment: PreparedMarkdownSegment, at position: Int) {
        precondition(position >= 0 && position <= endIndex)
        if position < endIndex {
            chunks[position / Self.chunkSize][position % Self.chunkSize] = segment
            return
        }
        if position % Self.chunkSize == 0 {
            var chunk: [PreparedMarkdownSegment] = []
            chunk.reserveCapacity(Self.chunkSize)
            chunks.append(chunk)
        }
        chunks[chunks.count - 1].append(segment)
        endIndex += 1
    }

    /// Removes the segments from `position` on.
    mutating func removeSuffix(from position: Int) {
        guard position < endIndex else { return }
        let keptChunks = (position + Self.chunkSize - 1) / Self.chunkSize
        chunks.removeLast(chunks.count - keptChunks)
        let kept = position % Self.chunkSize
        if kept > 0 { chunks[chunks.count - 1].removeLast(chunks[chunks.count - 1].count - kept) }
        endIndex = position
    }
}

/// A reply's prepared segments for one source.
struct PreparedMarkdownDocument: Sendable {
    let source: String
    /// The message text revision prepared, when the caller supplied one. Views and caches match
    /// documents by revision, never by comparing text.
    let revision: TextRevision?
    let isComplete: Bool
    let segments: PreparedSegmentList
    /// UTF-8 bytes the segments render: bodies with any rebuilt syntax, whole artifacts and the
    /// definition suffix of every segment that carries it. Window and cache budgets charge this.
    let renderedBytes: Int

    /// What caches charge for a document: the rendered bytes plus the retained source.
    var cost: Int { renderedBytes + source.utf8.count }

    func matches(_ revision: TextRevision, isComplete: Bool) -> Bool {
        self.revision == revision && self.isComplete == isComplete
    }
}

/// Prepares replies as independently parsed segments (#60 A1/A3, ADR-0091).
///
/// Each streaming reply holds one uniquely referenced `MarkdownSegmentation` and its prepared
/// segments, updated in place as the reply grows. The caller's `TextRevision` says whether the new
/// source extends the held one, so a refresh never compares the reply's text: an edit, a trim or a
/// replacement starts a new segmentation, which reuses earlier preparations whose kind and text are
/// unchanged. Within one segmentation a refresh visits only segments that settled since the last
/// refresh and the provisional tail. Settled segments are parsed once; when the reply's reference
/// definitions change, only settled segments with a closing bracket are prepared again. Parsing
/// happens here, never while SwiftUI evaluates a transcript row.
///
/// Entries are retained under a deterministic budget: rendered bytes plus source bytes, plus the
/// source bytes again for the segment bodies a streaming reply's scanner holds. A reply whose cost
/// exceeds `maximumEntryCost` is prepared and returned but not retained, and keeps no scanner state.
/// Least recently used entries are evicted with their scanner state. Memory pressure clears it
/// through `RenderingCaches`.
actor MarkdownSegmentCache {
    struct Snapshot: Sendable, Equatable {
        let entryCount: Int
        let streamCount: Int
        let cost: Int
        /// Segments parsed, and the bytes they rendered, since this cache was created (#60 measurement 1).
        let parseCount: Int
        let parsedBytes: Int
        let work: Work
    }

    /// The whole preparation path's work since this cache was created (#60 A1). Counters are
    /// deterministic; durations are wall-clock observations for profiles, not thresholds.
    struct Work: Sendable, Equatable {
        /// `prepare` calls that were not exact hits.
        var refreshes = 0
        /// Prepared segments examined or rebuilt while assembling documents, and the most in one refresh.
        var visitedSegments = 0
        var maximumVisitedSegments = 0
        /// Settled segments examined because the reply's reference definitions changed.
        var definitionVisits = 0
        /// Bytes compared to decide reuse, or whether a source extends the held one.
        var comparedBytes = 0
        /// Bytes the segmenter read and copied.
        var scannedBytes = 0
        var copiedBytes = 0
        /// HTML rendered to decide whether the tail carries the caret.
        var caretBytes = 0
        var segmentationTime = Duration.zero
        var parseTime = Duration.zero
        var assemblyTime = Duration.zero
    }

    static let shared = MarkdownSegmentCache()

    private struct Entry {
        var document: PreparedMarkdownDocument
        var cost: Int
        var access: UInt64
    }

    /// A streaming reply's scanner and prepared segments, held uniquely so both update in place.
    private struct Stream {
        var segmentation: MarkdownSegmentation
        var revision: TextRevision?
        var prepared = PreparedSegmentList()
        var renderedBytes = 0
        /// Segments below this index were settled, and prepared against `settledSuffix`, at the last
        /// refresh.
        var preparedSettledCount = 0
        var settledSuffix = ""
        var tailIndex: Int?
    }

    let maximumEntries: Int
    let maximumCost: Int
    let maximumEntryCost: Int
    private let targetBytes: Int
    private let maximumBytes: Int
    private var entries: [UUID: Entry] = [:]
    /// Present only while the entry for the same reply was prepared from it and the reply streams.
    private var streams: [UUID: Stream] = [:]
    private var cost = 0
    private var access: UInt64 = 0
    private var parseCount = 0
    private var parsedBytes = 0
    private var preparationCount: UInt64 = 0
    private var work = Work()

    init(
        maximumEntries: Int = 32,
        maximumCost: Int = 8 * 1_024 * 1_024,
        maximumEntryCost: Int = 2 * 1_024 * 1_024,
        targetBytes: Int = MarkdownSegmenter.targetBytes,
        maximumBytes: Int = MarkdownSegmenter.maximumBytes
    ) {
        self.maximumEntries = max(1, maximumEntries)
        self.maximumCost = max(1, maximumCost)
        self.maximumEntryCost = max(1, min(maximumEntryCost, maximumCost))
        self.targetBytes = targetBytes
        self.maximumBytes = maximumBytes
    }

    /// The prepared segments of `source`, or nil when the calling task was cancelled first.
    ///
    /// Pass the message's `revision` for `source`: when it extends the held revision the held
    /// segmentation is extended without comparing text. Without a revision the held source is
    /// compared byte by byte, which callers on the streaming path should avoid.
    func prepare(id: UUID, source: String, revision: TextRevision? = nil, isComplete: Bool)
        -> PreparedMarkdownDocument?
    {
        guard !Task.isCancelled else { return nil }
        access &+= 1
        let previous = takeEntry(id)
        if let previous, previous.document.isComplete == isComplete,
            revision.map({ previous.document.revision == $0 }) ?? (previous.document.source == source)
        {
            insert(previous.document, cost: previous.cost, for: id)
            return previous.document
        }
        work.refreshes += 1
        let clock = ContinuousClock()

        // Segmentation: extend the held scanner when the source only grew.
        var started = clock.now
        var stream: Stream
        if let held = streams.removeValue(forKey: id), extends(held, source: source, revision: revision) {
            stream = held
        } else {
            stream = Stream(segmentation: MarkdownSegmentation(targetBytes: targetBytes, maximumBytes: maximumBytes))
            // Earlier preparations stay candidates for reuse, compared by kind and text below.
            if let previous {
                stream.prepared = previous.document.segments
                stream.renderedBytes = previous.document.renderedBytes
            }
        }
        stream.revision = revision
        let before = (work: stream.segmentation.work, restarts: stream.segmentation.restarts)
        stream.segmentation.extend(to: source, isComplete: isComplete)
        work.scannedBytes += stream.segmentation.work.scannedBytes - before.work.scannedBytes
        work.copiedBytes += stream.segmentation.work.copiedBytes - before.work.copiedBytes
        if stream.segmentation.restarts != before.restarts {
            stream.preparedSettledCount = 0
            stream.settledSuffix = ""
        }
        work.segmentationTime += clock.now - started

        started = clock.now
        assemble(&stream, isComplete: isComplete)
        work.assemblyTime += clock.now - started

        let document = PreparedMarkdownDocument(
            source: source, revision: revision, isComplete: isComplete, segments: stream.prepared,
            renderedBytes: stream.renderedBytes)
        // A streaming reply's scanner also holds its segment bodies, about the source again.
        let streamCost = isComplete ? 0 : source.utf8.count
        if !isComplete { streams[id] = stream }
        if !insert(document, cost: document.cost + streamCost, for: id) { streams[id] = nil }
        return document
    }

    func removeAll() {
        entries.removeAll()
        streams.removeAll()
        cost = 0
    }

    func snapshot() -> Snapshot {
        Snapshot(
            entryCount: entries.count, streamCount: streams.count, cost: cost, parseCount: parseCount,
            parsedBytes: parsedBytes, work: work)
    }

    /// Whether the held segmentation can be extended to `source`.
    private func extends(_ stream: Stream, source: String, revision: TextRevision?) -> Bool {
        if let revision, let held = stream.revision { return revision.extends(held) }
        work.comparedBytes += stream.segmentation.source.utf8.count
        return Self.source(source, extends: stream.segmentation.source)
    }

    /// Brings `stream.prepared` up to date with its segmentation, visiting only what can have changed.
    private func assemble(_ stream: inout Stream, isComplete: Bool) {
        let count = stream.segmentation.count
        let settledCount = stream.segmentation.settledCount
        let firstVisit = min(stream.preparedSettledCount, stream.prepared.count, settledCount)

        // Settled segments keep their range, kind and body; only new definitions can change them.
        let suffix = stream.segmentation.settledDefinitionSuffix
        if suffix != stream.settledSuffix {
            work.comparedBytes += suffix.utf8.count
            for index in 0..<firstVisit {
                work.definitionVisits += 1
                let old = stream.prepared[index]
                guard old.usesDefinitions, old.definitionSuffix != suffix else { continue }
                work.comparedBytes += old.definitionSuffix.utf8.count
                let revised = parse(stream.segmentation[index]).updating(
                    isSettled: true, continuesPrevious: old.continuesPrevious, endsInParagraph: nil)
                replace(&stream, at: index, with: revised)
            }
            stream.settledSuffix = suffix
        }
        if let tail = stream.tailIndex, tail < firstVisit {
            let old = stream.prepared[tail]
            let revised = old.updating(
                isSettled: old.isSettled, continuesPrevious: old.continuesPrevious, endsInParagraph: nil)
            replace(&stream, at: tail, with: revised)
        }

        // Segments that settled since the last refresh, and the provisional tail.
        let tailIndex = isComplete || count == 0 ? nil : count - 1
        for index in firstVisit..<count {
            let segment = stream.segmentation[index]
            let old = index < stream.prepared.count ? stream.prepared[index] : nil
            let prepared = old.flatMap { renders($0, segment) ? $0 : nil } ?? parse(segment)
            let caret = index == tailIndex ? (prepared.endsInParagraph ?? tailEndsInParagraph(prepared)) : nil
            let revised = prepared.updating(
                isSettled: segment.isSettled, continuesPrevious: segment.continuesPrevious, endsInParagraph: caret)
            replace(&stream, at: index, with: revised)
        }
        if stream.prepared.count > count {
            for index in count..<stream.prepared.count {
                stream.renderedBytes -= stream.prepared[index].text.utf8.count
            }
            stream.prepared.removeSuffix(from: count)
        }
        let visited = count - firstVisit
        work.visitedSegments += visited
        work.maximumVisitedSegments = max(work.maximumVisitedSegments, visited)
        stream.preparedSettledCount = settledCount
        stream.tailIndex = tailIndex
    }

    private func replace(_ stream: inout Stream, at index: Int, with segment: PreparedMarkdownSegment) {
        if index < stream.prepared.count { stream.renderedBytes -= stream.prepared[index].text.utf8.count }
        stream.renderedBytes += segment.text.utf8.count
        stream.prepared.set(segment, at: index)
    }

    /// Whether `old` renders `segment`: the same kind and body, and the same definitions unless the
    /// segment cannot use them.
    private func renders(_ old: PreparedMarkdownSegment, _ segment: MarkdownSegment) -> Bool {
        guard old.kind == segment.kind, old.bodyBytes == segment.body.utf8.count else { return false }
        work.comparedBytes += old.bodyBytes
        guard old.text.utf8.prefix(old.bodyBytes).elementsEqual(segment.body.utf8) else { return false }
        return !old.usesDefinitions || old.definitionSuffix == segment.definitionSuffix
    }

    private func parse(_ segment: MarkdownSegment) -> PreparedMarkdownSegment {
        let started = ContinuousClock.now
        defer { work.parseTime += ContinuousClock.now - started }
        let text = segment.text
        preparationCount &+= 1
        let preparation: MarkdownPreparation
        if segment.kind == .verbatimPiece {
            preparation = .plainText
        } else {
            // Only the reply's first segment can be an HTML or SVG artifact, as in the whole reply.
            preparation = .parsed(
                RenderSignposts.measure("MarkdownSegmentParse") {
                    PreparedMarkdownContent(
                        value: MarkdownContent(
                            GOATMarkdownSyntax.normalized(text, detectsArtifacts: segment.index == 0)))
                })
            parseCount += 1
            parsedBytes += text.utf8.count
        }
        return PreparedMarkdownSegment(
            index: segment.index, text: text, definitionSuffix: segment.definitionSuffix, kind: segment.kind,
            continuesPrevious: segment.continuesPrevious, isSettled: segment.isSettled, preparation: preparation,
            preparationID: preparationCount,
            leadingMargin: MarkdownSegmentSpacing.leadingMargin(of: segment.body, kind: segment.kind),
            trailingMargin: MarkdownSegmentSpacing.trailingMargin(of: segment.body, kind: segment.kind),
            endsInParagraph: nil,
            usesDefinitions: segment.kind != .verbatimPiece && segment.body.utf8.contains(UInt8(ascii: "]")),
            bodyBytes: segment.body.utf8.count)
    }

    private func tailEndsInParagraph(_ segment: PreparedMarkdownSegment) -> Bool {
        guard case .parsed(let content) = segment.preparation else { return false }
        let html = content.value.renderHTML()
        work.caretBytes += html.utf8.count
        return Self.endsInParagraph(html: html)
    }

    private func takeEntry(_ id: UUID) -> Entry? {
        guard let entry = entries.removeValue(forKey: id) else { return nil }
        cost -= entry.cost
        return entry
    }

    /// Returns whether the document was retained.
    @discardableResult
    private func insert(_ document: PreparedMarkdownDocument, cost entryCost: Int, for id: UUID) -> Bool {
        _ = takeEntry(id)
        guard entryCost <= maximumEntryCost else { return false }
        entries[id] = Entry(document: document, cost: entryCost, access: access)
        cost += entryCost
        while cost > maximumCost || entries.count > maximumEntries,
            let victim = entries.min(by: { $0.value.access < $1.value.access })?.key
        {
            _ = takeEntry(victim)
            streams[victim] = nil
        }
        return entries[id] != nil
    }

    /// Whether `text` begins with every UTF-8 byte of `prefix`.
    static func source(_ text: String, extends prefix: String) -> Bool {
        let count = prefix.utf8.count
        guard text.utf8.count >= count else { return false }
        let contiguous =
            prefix.utf8.withContiguousStorageIfAvailable { old in
                text.utf8.withContiguousStorageIfAvailable { new in new.prefix(count).elementsEqual(old) }
            } ?? nil
        return contiguous ?? text.utf8.prefix(count).elementsEqual(prefix.utf8)
    }

    /// Whether the last leaf block of a parsed segment is a paragraph, read from its structure rather
    /// than its text: cmark closes that paragraph last, inside any lists and quotes that hold it. A
    /// tight list item's paragraph closes without `</p>`. Code, headings, tables, thematic breaks,
    /// HTML blocks and image-only endings are not prose and carry no caret.
    static func endsInParagraph(_ segment: PreparedMarkdownSegment) -> Bool {
        guard case .parsed(let content) = segment.preparation else { return false }
        return endsInParagraph(html: content.value.renderHTML())
    }

    static func endsInParagraph(html: String) -> Bool {
        var html = Substring(html)
        var closesItem = false
        while true {
            html = html.dropLast(html.reversed().prefix(while: \.isWhitespace).count)
            guard let closer = ["</li>", "</ul>", "</ol>", "</blockquote>"].first(where: { html.hasSuffix($0) })
            else { break }
            // Only the innermost closer tells whether an item ended in its own inline content.
            closesItem = closer == "</li>"
            html = html.dropLast(closer.count)
        }
        // An image or thematic break ends the segment without text.
        if html.hasSuffix("/>") || html.hasSuffix("/></p>") { return false }
        if html.hasSuffix("</p>") { return true }
        guard closesItem, !html.hasSuffix("<li>") else { return false }
        let blockClosers = ["</pre>", "</table>", "</h1>", "</h2>", "</h3>", "</h4>", "</h5>", "</h6>"]
        return !blockClosers.contains(where: html.hasSuffix)
    }
}

/// Prepared documents keyed by reply, so a reply already prepared renders on its first frame. A hit
/// requires the exact text revision; `latest(for:)` serves a streaming reply its last prepared
/// document until the current one is ready. Cost is `PreparedMarkdownDocument.cost`, retained under
/// the same kind of deterministic byte budget as `TranscriptPartsCache`. Documents share their
/// parsed segments with `MarkdownSegmentCache`, and each layer charges what it retains. Memory
/// pressure clears it through `RenderingCaches`.
@MainActor
final class PreparedMarkdownDocumentCache {
    static let shared = PreparedMarkdownDocumentCache()

    struct Snapshot: Equatable {
        let entryCount: Int
        let totalCost: Int
    }

    private struct Entry {
        let document: PreparedMarkdownDocument
        var access: UInt64
    }

    let maximumEntries: Int
    let maximumTotalCost: Int
    let maximumEntryCost: Int
    private var entries: [UUID: Entry] = [:]
    private var totalCost = 0
    private var clock: UInt64 = 0

    init(maximumEntries: Int = 64, maximumTotalCost: Int = 8 * 1_024 * 1_024, maximumEntryCost: Int = 1_024 * 1_024) {
        self.maximumEntries = max(1, maximumEntries)
        self.maximumTotalCost = max(1, maximumTotalCost)
        self.maximumEntryCost = max(1, min(maximumEntryCost, maximumTotalCost))
    }

    /// The document prepared from exactly `revision`, complete or not.
    func document(for id: UUID, revision: TextRevision) -> PreparedMarkdownDocument? {
        guard let entry = entries[id], entry.document.revision == revision else { return nil }
        return touch(id)
    }

    func latest(for id: UUID) -> PreparedMarkdownDocument? {
        entries[id] == nil ? nil : touch(id)
    }

    /// The rendered bytes of exactly `revision` when prepared, without changing recency.
    func renderedBytes(for id: UUID, revision: TextRevision) -> Int? {
        guard let document = entries[id]?.document, document.revision == revision else { return nil }
        return document.renderedBytes
    }

    /// Returns whether the document was retained. A declined store also drops the older entry.
    @discardableResult
    func store(_ document: PreparedMarkdownDocument, for id: UUID) -> Bool {
        remove(id)
        guard document.cost <= maximumEntryCost else { return false }
        clock &+= 1
        entries[id] = Entry(document: document, access: clock)
        totalCost += document.cost
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

    private func touch(_ id: UUID) -> PreparedMarkdownDocument? {
        guard var entry = entries[id] else { return nil }
        clock &+= 1
        entry.access = clock
        entries[id] = entry
        return entry.document
    }

    private func remove(_ id: UUID) {
        guard let old = entries.removeValue(forKey: id) else { return }
        totalCost -= old.document.cost
    }
}

/// Spaces segments as MarkdownUI's block sequence spaces the same blocks in one document: the larger
/// of the previous block's bottom margin and the next block's top margin, or SwiftUI's default padding
/// when neither block specifies one. Margins follow MarkdownUI's basic theme with GOAT's styles:
/// paragraphs, lists, quotes and tables end 1 em below, headings start 1.5 rem above, thematic
/// breaks take 2 em on both sides, and GOAT's code blocks specify none. Margins are classified once,
/// when a segment is parsed, from its first and last non-blank lines.
enum MarkdownSegmentSpacing {
    static func gap(after previous: PreparedMarkdownSegment, before next: PreparedMarkdownSegment, fontSize: CGFloat)
        -> CGFloat?
    {
        if next.continuesPrevious { return 0 }
        guard let margin = [previous.trailingMargin, next.leadingMargin].compactMap({ $0 }).max() else { return nil }
        return (margin * fontSize).rounded()
    }

    static func leadingMargin(of body: String, kind: MarkdownSegment.Kind) -> Double? {
        switch kind {
        case .fencedCodePiece: return nil
        case .tablePiece, .verbatimPiece: return 0
        case .blocks, .blockPiece: break
        }
        let lines = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let start = lines.firstIndex(where: { !isBlank($0) }) else { return 0 }
        let first = lines[start]
        if fenceRun(first) >= 3 { return nil }
        if isHeading(first) { return 1.5 }
        if isThematicBreak(first) { return 2 }
        if start + 1 < lines.count, isSetextUnderline(lines[start + 1]), !"->*+|".contains(first.first ?? "-") {
            return 1.5
        }
        return 0
    }

    static func trailingMargin(of body: String, kind: MarkdownSegment.Kind) -> Double? {
        switch kind {
        case .fencedCodePiece: return nil
        case .tablePiece, .verbatimPiece: return 1
        case .blocks, .blockPiece: break
        }
        let lines = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let end = lines.lastIndex(where: { !isBlank($0) }) else { return 1 }
        let last = lines[end]
        // A column-0 fence ends a top-level code block (an indented one ends a list item).
        if fenceRun(last) >= 3, isBlank(last.drop(while: { $0 == last.first })) { return nil }
        // `---` directly under text is a setext heading underline, not a thematic break.
        if isThematicBreak(last), end == 0 || isBlank(lines[end - 1]) { return 2 }
        return 1
    }

    private static func isBlank(_ line: Substring) -> Bool { line.allSatisfy(\.isWhitespace) }

    private static func indentation(_ line: Substring) -> Substring? {
        let spaces = line.prefix(while: { $0 == " " })
        return spaces.count <= 3 ? line.dropFirst(spaces.count) : nil
    }

    /// The length of a column-0 backtick or tilde run.
    private static func fenceRun(_ line: Substring) -> Int {
        guard let marker = line.first, marker == "`" || marker == "~" else { return 0 }
        return line.prefix(while: { $0 == marker }).count
    }

    private static func isHeading(_ line: Substring) -> Bool {
        guard let text = indentation(line) else { return false }
        let hashes = text.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return false }
        let rest = text.dropFirst(hashes)
        return rest.isEmpty || rest.first == " " || rest.first == "\t"
    }

    private static func isThematicBreak(_ line: Substring) -> Bool {
        guard let text = indentation(line) else { return false }
        let marks = text.filter { $0 != " " && $0 != "\t" && !$0.isNewline }
        guard let marker = marks.first, "-*_".contains(marker) else { return false }
        return marks.count >= 3 && marks.allSatisfy { $0 == marker }
    }

    private static func isSetextUnderline(_ line: Substring) -> Bool {
        guard let text = indentation(line), let marker = text.first, marker == "=" || marker == "-" else {
            return false
        }
        return isBlank(text.drop(while: { $0 == marker }))
    }
}

/// A reply rendered as independently prepared segments (#60 A1 step 2, ADR-0091). Each segment is
/// its own Markdown view keyed by its index, so a settled segment keeps its view and prepared content
/// while later segments stream. Pieces of one oversized block join without a gap.
struct SegmentedMarkdownView: View {
    let document: PreparedMarkdownDocument
    let fontSize: CGFloat
    let isStreaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(document.segments, id: \.index) { segment in
                MarkdownSegmentView(
                    segment: segment, fontSize: fontSize, isStreaming: isStreaming,
                    isTail: isStreaming && segment.index == document.segments.count - 1
                )
                .equatable()
                .padding(.top, gap(before: segment))
            }
        }
    }

    private func gap(before segment: PreparedMarkdownSegment) -> CGFloat? {
        guard segment.index > 0, segment.index <= document.segments.count else { return 0 }
        return MarkdownSegmentSpacing.gap(
            after: document.segments[segment.index - 1], before: segment, fontSize: fontSize)
    }
}

/// Equal preparations render equal content, so SwiftUI skips a settled segment while the tail streams.
private struct MarkdownSegmentView: View, Equatable {
    let segment: PreparedMarkdownSegment
    let fontSize: CGFloat
    let isStreaming: Bool
    let isTail: Bool
    @Environment(AppModel.self) private var model

    nonisolated static func == (lhs: MarkdownSegmentView, rhs: MarkdownSegmentView) -> Bool {
        lhs.segment.preparationID == rhs.segment.preparationID
            && lhs.segment.endsInParagraph == rhs.segment.endsInParagraph && lhs.fontSize == rhs.fontSize
            && lhs.isStreaming == rhs.isStreaming && lhs.isTail == rhs.isTail
    }

    var body: some View {
        switch segment.preparation {
        case .parsed(let content):
            let showsCaret = isTail && segment.endsInParagraph == true
            Markdown(content.value)
                .markdownImageProvider(BlockedMarkdownImageProvider())
                .markdownInlineImageProvider(BlockedMarkdownInlineImageProvider())
                .goatMarkdownStyle(fontSize: fontSize, isStreaming: isStreaming)
                .textSelection(.enabled)
                // Text layouts arrive in view order, so when the segment ends in a paragraph the last
                // one is that paragraph's, wherever its text also appears earlier.
                .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                    if showsCaret, let last = layouts.last { StreamingCaretMark(text: last) }
                }
        case .plainText:
            let text = Text(verbatim: segment.text)
                .font(Font(ReadingFonts.nsFont(model.effectiveCodeFontID, size: model.codeFontSize, role: .code)))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if isTail { text.modifier(StreamingCaret()) } else { text }
        }
    }
}
