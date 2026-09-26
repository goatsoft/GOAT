import Bleet
import Foundation
import Hoofprint
import MarkdownUI
import SwiftUI

/// One prepared segment of a reply (#60 A1 step 2, ADR-0091).
struct PreparedMarkdownSegment: Sendable {
    let index: Int
    /// The Markdown rendered: the segment body followed by the reply's reference definitions.
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

    func updating(isSettled: Bool, continuesPrevious: Bool, endsInParagraph: Bool?) -> PreparedMarkdownSegment {
        PreparedMarkdownSegment(
            index: index, text: text, definitionSuffix: definitionSuffix, kind: kind,
            continuesPrevious: continuesPrevious, isSettled: isSettled, preparation: preparation,
            preparationID: preparationID, leadingMargin: leadingMargin, trailingMargin: trailingMargin,
            endsInParagraph: endsInParagraph)
    }
}

/// A reply's prepared segments for one source.
struct PreparedMarkdownDocument: Sendable {
    let source: String
    let isComplete: Bool
    let segments: [PreparedMarkdownSegment]
    /// UTF-8 bytes the segments render: bodies with any rebuilt syntax, whole artifacts and the
    /// definition suffix of every segment that carries it. Window and cache budgets charge this.
    let renderedBytes: Int

    /// What caches charge for a document: the rendered bytes plus the retained source.
    var cost: Int { renderedBytes + source.utf8.count }
}

/// Prepares replies as independently parsed segments (#60 A1/A3 step 2, ADR-0091).
///
/// Each streaming reply holds one uniquely referenced `MarkdownSegmentation`, extended in place as
/// the reply grows. A source that does not extend the previous one (an edit, a trim at completion)
/// starts a new segmentation. Within one segmentation a settled segment is parsed once and reused
/// while the reply's definition suffix is unchanged; provisional segments are reused only when their
/// text is unchanged. Parsing happens here, never while SwiftUI evaluates a transcript row.
///
/// Entries are retained under a deterministic budget of rendered bytes plus source bytes. A reply
/// whose cost exceeds `maximumEntryCost` is prepared and returned but not retained. Least recently
/// used entries are evicted with their segmentation. Memory pressure clears it through
/// `RenderingCaches`.
actor MarkdownSegmentCache {
    struct Snapshot: Sendable, Equatable {
        let entryCount: Int
        let streamCount: Int
        let cost: Int
        /// Segments parsed, and the bytes they rendered, since this cache was created (#60 measurement 1).
        let parseCount: Int
        let parsedBytes: Int
    }

    static let shared = MarkdownSegmentCache()

    private struct Entry {
        var document: PreparedMarkdownDocument
        var access: UInt64
    }

    let maximumEntries: Int
    let maximumCost: Int
    let maximumEntryCost: Int
    private let targetBytes: Int
    private let maximumBytes: Int
    private var entries: [UUID: Entry] = [:]
    /// Present only while the entry for the same reply was prepared from it and the reply streams.
    private var streams: [UUID: MarkdownSegmentation] = [:]
    private var cost = 0
    private var access: UInt64 = 0
    private var parseCount = 0
    private var parsedBytes = 0
    private var preparationCount: UInt64 = 0

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
    func prepare(id: UUID, source: String, isComplete: Bool) -> PreparedMarkdownDocument? {
        guard !Task.isCancelled else { return nil }
        access &+= 1
        let previous = takeEntry(id)
        if let previous, previous.document.isComplete == isComplete, previous.document.source == source {
            insert(previous.document, for: id)
            return previous.document
        }

        // A held segmentation always produced `previous`, so its settled segments are this one's.
        let continues = streams[id].map { Self.source(source, extends: $0.source) } ?? false
        if !continues {
            streams[id] = MarkdownSegmentation(targetBytes: targetBytes, maximumBytes: maximumBytes)
        }
        // Mutates the stored value in place, keeping it uniquely referenced.
        streams[id]?.extend(to: source, isComplete: isComplete)
        guard let segmentation = streams[id] else { return nil }

        let prior = previous?.document.segments ?? []
        let tailIndex = isComplete ? nil : segmentation.indices.last
        var segments: [PreparedMarkdownSegment] = []
        segments.reserveCapacity(segmentation.count)
        var renderedBytes = 0
        for segment in segmentation {
            let old = segment.index < prior.count ? prior[segment.index] : nil
            let reused: PreparedMarkdownSegment?
            if let old, continues, old.isSettled, segment.isSettled, old.definitionSuffix == segment.definitionSuffix {
                // A settled segment's range, kind and body never change within one segmentation.
                reused = old
            } else if let old, old.kind == segment.kind, old.text == segment.text {
                reused = old
            } else {
                reused = nil
            }
            let prepared = reused ?? parse(segment)
            let isTail = segment.index == tailIndex
            segments.append(
                prepared.updating(
                    isSettled: segment.isSettled, continuesPrevious: segment.continuesPrevious,
                    endsInParagraph: isTail ? (prepared.endsInParagraph ?? Self.endsInParagraph(prepared)) : nil))
            renderedBytes += prepared.text.utf8.count
        }

        let document = PreparedMarkdownDocument(
            source: source, isComplete: isComplete, segments: segments, renderedBytes: renderedBytes)
        if isComplete { streams[id] = nil }
        if !insert(document, for: id) { streams[id] = nil }
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
            parsedBytes: parsedBytes)
    }

    private func parse(_ segment: MarkdownSegment) -> PreparedMarkdownSegment {
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
            endsInParagraph: nil)
    }

    private func takeEntry(_ id: UUID) -> Entry? {
        guard let entry = entries.removeValue(forKey: id) else { return nil }
        cost -= entry.document.cost
        return entry
    }

    /// Returns whether the document was retained.
    @discardableResult
    private func insert(_ document: PreparedMarkdownDocument, for id: UUID) -> Bool {
        _ = takeEntry(id)
        guard document.cost <= maximumEntryCost else { return false }
        entries[id] = Entry(document: document, access: access)
        cost += document.cost
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
/// requires the exact source; `latest(for:)` serves a streaming reply its last prepared document until
/// the current one is ready. Cost is `PreparedMarkdownDocument.cost`, retained under the same kind of
/// deterministic byte budget as `TranscriptPartsCache`. Memory pressure clears it through
/// `RenderingCaches`.
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

    func document(for id: UUID, source: String) -> PreparedMarkdownDocument? {
        guard let entry = entries[id], entry.document.source == source else { return nil }
        return touch(id)
    }

    func latest(for id: UUID) -> PreparedMarkdownDocument? {
        entries[id] == nil ? nil : touch(id)
    }

    /// The rendered bytes of the exact source when prepared, without changing recency.
    func renderedBytes(for id: UUID, source: String) -> Int? {
        guard let document = entries[id]?.document, document.source == source else { return nil }
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
                    isTail: isStreaming && segment.index == document.segments.count - 1,
                    codeSegment: Self.codeSegment(of: segment.index, in: document.segments)
                )
                .equatable()
                .padding(.top, gap(before: segment))
            }
        }
    }

    /// The segment code-block choices are kept by: a piece of an oversized fence uses the fence's
    /// first piece, so a choice applies to the whole fence.
    static func codeSegment<Segments: RandomAccessCollection>(of index: Int, in segments: Segments) -> Int
    where Segments.Element == PreparedMarkdownSegment, Segments.Index == Int {
        var index = index
        while index > 0, index < segments.count, segments[index].kind == .fencedCodePiece,
            segments[index].continuesPrevious, segments[index - 1].kind == .fencedCodePiece
        {
            index -= 1
        }
        return index
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
    let codeSegment: Int
    @Environment(AppModel.self) private var model
    @Environment(\.codeBlockMessageID) private var messageID

    nonisolated static func == (lhs: MarkdownSegmentView, rhs: MarkdownSegmentView) -> Bool {
        lhs.segment.preparationID == rhs.segment.preparationID
            && lhs.segment.endsInParagraph == rhs.segment.endsInParagraph && lhs.fontSize == rhs.fontSize
            && lhs.isStreaming == rhs.isStreaming && lhs.isTail == rhs.isTail && lhs.codeSegment == rhs.codeSegment
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
                .environment(
                    \.codeBlockScope,
                    messageID.map {
                        CodeBlockScope(
                            messageID: $0, segment: codeSegment, content: content,
                            preparationID: segment.preparationID, isFencePiece: segment.kind == .fencedCodePiece)
                    })
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
