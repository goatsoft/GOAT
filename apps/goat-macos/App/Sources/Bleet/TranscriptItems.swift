import Bleet
import Foundation
import Observation
import SwiftUI

/// What the transcript's one lazy stack lays out (ADR-0104). A short message is one item. A long reply
/// is split into a head (avatar and reasoning disclosure), one item per reasoning segment while its
/// reasoning is open, one item per answer segment and a tail (tools, error, actions), so the lazy stack
/// lays out only the segments near the viewport. Text above the rich limit is split into plain parts the
/// same way. There is no window and nothing pages.
struct TranscriptItem: Identifiable, Equatable {
    enum Part: Hashable, Sendable {
        /// The whole message.
        case whole
        /// A split reply's avatar and reasoning disclosure, or a split user message's attachments.
        case head
        /// A segment of open reasoning.
        case reasoning(Int)
        /// A segment of the answer (or a plain part of text above the rich limit).
        case answer(Int)
        /// A split reply's tools, error and actions.
        case tail
    }

    struct ID: Hashable, Sendable {
        let message: UUID
        let part: Part
    }

    let row: TranscriptActivity.Row
    let part: Part
    var id: ID { ID(message: row.id, part: part) }
    var message: ChatMessage { row.messages[0] }

    /// The key and segment the navigation owner measures this item under: a message's first item by the
    /// message, its segments by the message (answer) or its reasoning key, its tail by its tail key.
    var frameKey: (key: UUID, segment: Int?) {
        switch part {
        case .whole, .head: (row.id, nil)
        case .reasoning(let index): (TranscriptSegmentOwner.reasoning(of: row.id), index)
        case .answer(let index): (row.id, index)
        case .tail: (TranscriptSegmentOwner.tail(of: row.id), nil)
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.row.messages.first === rhs.row.messages.first
            && lhs.row.isContinuation == rhs.row.isContinuation && lhs.row.startsDay == rhs.row.startsDay
            && lhs.row.joinsPreviousTools == rhs.row.joinsPreviousTools
            && lhs.row.joinsNextTools == rhs.row.joinsNextTools
    }

    /// The items for `rows`, splitting the messages whose text the store holds in more than one piece.
    @MainActor static func items(for rows: [TranscriptActivity.Row], texts: TranscriptTexts) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        items.reserveCapacity(rows.count + 8)
        for row in rows {
            let message = row.messages[0]
            switch texts.layout(of: message) {
            case .whole:
                items.append(TranscriptItem(row: row, part: .whole))
            case .split(let head, let reasoning, let answer, let tail):
                if head { items.append(TranscriptItem(row: row, part: .head)) }
                for index in 0..<reasoning { items.append(TranscriptItem(row: row, part: .reasoning(index))) }
                for index in 0..<answer { items.append(TranscriptItem(row: row, part: .answer(index))) }
                if tail { items.append(TranscriptItem(row: row, part: .tail)) }
            }
        }
        return items
    }
}

/// How a message is laid out: whole, or split into its pieces.
enum TranscriptMessageLayout: Equatable {
    case whole
    case split(head: Bool, reasoning: Int, answer: Int, tail: Bool)
}

/// The prepared text of the transcript's messages, held outside the rows: the lazy stack creates and
/// releases rows as they near or leave the viewport, and a split message's pieces share one preparation.
/// Each message has its own observable state, so a preparation invalidates only that message's items.
@MainActor final class TranscriptTexts {
    static let shared = TranscriptTexts()
    private var answers: [UUID: AnswerText] = [:]
    private var reasoning: [UUID: ReasoningText] = [:]
    /// Bounded: beyond this, entries that are neither streaming, shown nor held by an open transcript
    /// are dropped. An idle transcript holds at most a page cache of messages (ADR-0102); a turn loads
    /// the chat's complete history, which can exceed this, and those entries are held.
    static let maximumEntries = 256
    /// The messages each open transcript lays out, by chat. Their entries survive eviction: a chat
    /// longer than the bound would otherwise evict and re-prepare its own entries on every update.
    private var held: [UUID: Set<UUID>] = [:]

    /// The transcript for `chat` lays out `messages`.
    func hold(_ messages: Set<UUID>, for chat: UUID) {
        if held[chat] != messages { held[chat] = messages }
    }

    /// The transcript for `chat` is gone.
    func release(chat: UUID) {
        held[chat] = nil
    }

    private func isHeld(_ id: UUID) -> Bool {
        held.values.contains { $0.contains(id) }
    }

    func answer(for message: ChatMessage) -> AnswerText {
        if let existing = answers[message.id] { return existing }
        if answers.count >= Self.maximumEntries {
            answers = answers.filter { $0.value.isActive || isHeld($0.key) }
        }
        let text = AnswerText(message: message)
        answers[message.id] = text
        return text
    }

    func reasoning(for message: ChatMessage) -> ReasoningText {
        if let existing = reasoning[message.id] { return existing }
        if reasoning.count >= Self.maximumEntries {
            reasoning = reasoning.filter { $0.value.isActive || isHeld($0.key) }
        }
        let text = ReasoningText(message: message)
        reasoning[message.id] = text
        return text
    }

    /// Whether `message` is shown whole or split, read from observable state so the transcript lays out
    /// again when it changes.
    func layout(of message: ChatMessage) -> TranscriptMessageLayout {
        switch message.role {
        case .user:
            guard message.kind == .regular, message.textRevision.utf8Count > TranscriptTextParts.maximumBytes else {
                return .whole
            }
            return .split(
                head: !message.attachmentPaths.isEmpty, reasoning: 0, answer: max(1, answer(for: message).pieceCount),
                tail: true)
        case .assistant:
            guard message.kind == .regular, !TranscriptActivity.isEmpty(message) else { return .whole }
            let hasAnswer = TranscriptText.hasContent(message.text)
            let answerPieces = hasAnswer ? answer(for: message).pieceCount : 0
            // Reasoning breaks into segments at every code block, so short reasoning is laid out in its row:
            // only reasoning past one segment's target takes items of its own.
            let reasoningOpen =
                TranscriptText.hasContent(message.thinking) && ReasoningDisclosure.isOpen(message)
                && message.thinkingRevision.utf8Count > MarkdownSegmenter.targetBytes
            let reasoningPieces = reasoningOpen ? reasoning(for: message).pieceCount : 0
            guard
                answerPieces > 1 || reasoningPieces > 1 || answer(for: message).isPlain
                    || (reasoningOpen && reasoning(for: message).isPlain)
            else { return .whole }
            return .split(
                head: TranscriptText.hasContent(message.thinking), reasoning: reasoningPieces,
                answer: hasAnswer ? max(1, answerPieces) : 0,
                tail: !message.toolEvents.isEmpty || message.error != nil || MessageView.showsFooter(for: message)
                    || message.stats?.finishReason == "length")
        case .system, .tool:
            return .whole
        }
    }

    /// How many answer and reasoning entries are held, for tests.
    var entryCount: Int { answers.count + reasoning.count }

    func removeAll() {
        answers.removeAll()
        reasoning.removeAll()
    }
}

/// A message's answer text, prepared as Markdown segments (or plain parts above the rich limit, and for
/// user text above the parts threshold). Segments parse as their items come into view: preparation
/// covers the segments shown plus a margin, and releases parses far from them.
@MainActor @Observable final class AnswerText {
    @ObservationIgnored let message: ChatMessage
    /// The latest prepared document, while the text is rich.
    private(set) var document: PreparedMarkdownDocument?
    /// The plain parts, while the text is above the rich limit (or user text above the parts threshold).
    private(set) var parts: [String]?
    /// Hover over any of a split message's items shows its actions.
    var hovering = 0

    @ObservationIgnored private var shown: [Int: Int] = [:]
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var sampling: Task<Void, Never>?
    @ObservationIgnored private var prepared: (revision: TextRevision, isComplete: Bool, window: Range<Int>?)?
    @ObservationIgnored private var pending = false

    /// Segments prepared on each side of those shown, so scrolling finds them ready.
    static let margin = 3

    init(message: ChatMessage) {
        self.message = message
        let cache = PreparedMarkdownDocumentCache.shared
        if !isPlain {
            document =
                cache.document(for: message.id, revision: message.textRevision)
                ?? (message.complete ? nil : cache.latest(for: message.id))
        } else {
            parts = TranscriptPartsCache.shared.parts(for: partsKey, source: message.text)
        }
        // A settled reply within one segment's target is one segment: it prepares when its item appears.
        // Longer or streaming text prepares now, so the transcript knows how many items it takes.
        if !message.complete || isPlain || message.textRevision.utf8Count > MarkdownSegmenter.targetBytes {
            start()
        }
    }

    var isPlain: Bool {
        message.role == .user
            ? message.textRevision.utf8Count > TranscriptTextParts.maximumBytes
            : message.textRevision.utf8Count > ReplyWindow.richLimit
    }

    /// Whether the message still streams, so its entry is kept.
    var isActive: Bool { !message.complete || !shown.isEmpty }

    /// How many items the answer takes.
    var pieceCount: Int {
        if isPlain { return parts?.count ?? 1 }
        return max(1, document?.segments.count ?? 1)
    }

    private var partsKey: String { "\(message.id.uuidString):text" }

    /// An answer item came into view.
    func appeared(_ index: Int) {
        shown[index, default: 0] += 1
        // Parse what came into view at the text already prepared. Taking the newest text here would add
        // items, which appear and prepare again: following a stream would then lay out as fast as text
        // is prepared instead of at the sampling interval.
        if segment(index)?.isParsed != true { prepare(atPreparedText: !message.complete) }
    }

    /// An answer item left the view.
    func disappeared(_ index: Int) {
        guard let count = shown[index] else { return }
        if count <= 1 { shown[index] = nil } else { shown[index] = count - 1 }
    }

    /// The segments to parse: every segment of a settled reply up to `wholeBytes`, else those shown and a
    /// margin around them, or the latest while none is shown.
    private var window: SegmentWindow {
        // Prewarming parses the same, so the two never take turns parsing and releasing its segments.
        if message.complete, message.textRevision.utf8Count <= Self.wholeBytes { return .all }
        guard let lower = shown.keys.min(), let upper = shown.keys.max() else { return .latest }
        return .segments(max(0, lower - Self.margin)..<(upper + Self.margin + 1))
    }

    /// A settled reply this short is parsed whole before it is shown, so its segments appear formatted
    /// together instead of each parsing as it comes into view.
    nonisolated static let wholeBytes = 32 * 1_024

    nonisolated static func window(forUnshown bytes: Int) -> SegmentWindow {
        bytes <= wholeBytes ? .all : .latest
    }

    /// Samples the text while it streams (`StreamSampling`).
    private func start() {
        prepare()
        guard !message.complete else { return }
        sampling = Task { @MainActor [weak self] in
            var sampled = self?.message.textRevision.utf8Count ?? 0
            while let self, !self.message.complete {
                self.prepare()
                let bytes = self.message.textRevision.utf8Count
                let interval = StreamSampling.interval(grewBy: bytes - sampled)
                sampled = bytes
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
            }
            self?.prepare()
        }
    }

    /// Prepares the current text for the current window, once at a time; a request while one runs
    /// runs after it.
    func prepare(atPreparedText: Bool = false) {
        guard preparation == nil else {
            pending = true
            return
        }
        let current = (source: message.text, revision: message.textRevision, isComplete: message.complete)
        let held = document.flatMap { document in
            document.revision.map { (source: document.source, revision: $0, isComplete: document.isComplete) }
        }
        let text = atPreparedText ? held ?? current : current
        let revision = text.revision
        let isComplete = text.isComplete
        if isPlain {
            if let parts, prepared?.revision == revision, prepared?.isComplete == isComplete, !parts.isEmpty { return }
            let source = message.text
            let key = partsKey
            preparation = Task { @MainActor [weak self] in
                let split = await Task.detached(priority: .userInitiated) {
                    try? TranscriptTextParts.split(source)
                }.value
                guard let self else { return }
                defer { self.finishPreparation() }
                guard let split, !Task.isCancelled else { return }
                TranscriptPartsCache.shared.store(split, for: key, source: source)
                self.prepared = (revision, isComplete, nil)
                if self.parts != split { self.parts = split }
                self.message.markRenderChanged()
            }
            return
        }
        let request = window
        let resolved = document.flatMap { request.resolve(count: $0.segments.count, cost: { _ in 0 }) }
        if let document, document.matches(revision, isComplete: isComplete),
            let prepared, prepared.revision == revision, prepared.isComplete == isComplete,
            prepared.window == resolved || (request == .latest && prepared.window == document.window)
        {
            return
        }
        let source = text.source
        let id = message.id
        preparation = Task { @MainActor [weak self] in
            let result = await MarkdownSegmentCache.shared.prepare(
                id: id, source: source, revision: revision, isComplete: isComplete, window: request)
            guard let self else { return }
            defer { self.finishPreparation() }
            guard let result else { return }
            // Kept for the next mount even if this view's request was replaced: a complete document is
            // final, and a streaming one is never older than what the cache holds.
            PreparedMarkdownDocumentCache.shared.store(result, for: id)
            self.prepared = (revision, isComplete, result.window)
            self.document = result
            self.message.markRenderChanged()
        }
    }

    private func finishPreparation() {
        preparation = nil
        if pending {
            pending = false
            prepare()
        }
    }

    /// The segment the item at `index` shows, if prepared.
    func segment(_ index: Int) -> PreparedMarkdownSegment? {
        guard let document, document.segments.indices.contains(index) else { return nil }
        return document.segments[index]
    }
}

/// A message's reasoning, prepared as plain segments (or plain parts above the rich limit). Prepared
/// only while its disclosure is open.
@MainActor @Observable final class ReasoningText {
    @ObservationIgnored let message: ChatMessage
    private(set) var thinking: PreparedThinking? {
        didSet { groups = thinking.map { Self.groups($0.segments) } ?? [] }
    }
    private(set) var parts: [String]?
    /// The thinking segments each reasoning item lays out. Reasoning breaks into a segment at every code
    /// block, so dense reasoning has a segment every few lines: items pack consecutive segments to about
    /// `groupBytes`, keeping the lazy stack's item count proportional to the reasoning's bytes while the
    /// streaming item, laid out again on every update, stays small.
    private(set) var groups: [Range<Int>] = []

    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var sampling: Task<Void, Never>?
    @ObservationIgnored private var pending = false
    @ObservationIgnored private var requested = false

    init(message: ChatMessage) {
        self.message = message
        if !isPlain {
            let cache = PreparedThinkingCache.shared
            thinking =
                cache.thinking(for: message.id, revision: message.thinkingRevision)
                ?? (message.complete ? nil : cache.latest(for: message.id))
            groups = thinking.map { Self.groups($0.segments) } ?? []
        } else {
            parts = TranscriptPartsCache.shared.parts(for: partsKey, source: source)
        }
    }

    var isPlain: Bool { message.thinkingRevision.utf8Count > ReplyWindow.richLimit }
    var isActive: Bool { !message.complete }
    private var partsKey: String { "\(message.id.uuidString):thinking" }
    private var source: String { TranscriptText.removingBoundaryBlankLines(message.thinking) }

    var pieceCount: Int {
        request()
        if isPlain { return parts?.count ?? 1 }
        return max(1, groups.count)
    }

    /// Consecutive segments packed until each group reaches `targetBytes`. Earlier groups depend only on
    /// the segments before them, so they stay the same while the reasoning grows.
    nonisolated static let groupBytes = 2 * 1_024

    nonisolated static func groups(
        _ segments: ChunkedList<ThinkingSegment>, targetBytes: Int = groupBytes
    ) -> [Range<Int>] {
        var groups: [Range<Int>] = []
        var lower = 0
        var bytes = 0
        for index in 0..<segments.count {
            bytes += segments[index].bytes
            if bytes >= targetBytes {
                groups.append(lower..<(index + 1))
                lower = index + 1
                bytes = 0
            }
        }
        if lower < segments.count { groups.append(lower..<segments.count) }
        return groups
    }

    /// Starts preparing, and sampling while the reasoning streams, the first time it is needed.
    func request() {
        guard !requested else { return }
        requested = true
        prepare()
        guard !message.complete else { return }
        sampling = Task { @MainActor [weak self] in
            var sampled = self?.message.thinkingRevision.utf8Count ?? 0
            while let self, !self.message.complete {
                self.prepare()
                let bytes = self.message.thinkingRevision.utf8Count
                let interval = StreamSampling.interval(grewBy: bytes - sampled)
                sampled = bytes
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
            }
            self?.prepare()
        }
    }

    func prepare() {
        guard preparation == nil else {
            pending = true
            return
        }
        let revision = message.thinkingRevision
        if isPlain {
            let source = self.source
            let key = partsKey
            if let parts, !parts.isEmpty, TranscriptPartsCache.shared.parts(for: key, source: source) == parts {
                return
            }
            preparation = Task { @MainActor [weak self] in
                let split = await Task.detached(priority: .userInitiated) {
                    try? TranscriptTextParts.split(source)
                }.value
                guard let self else { return }
                defer { self.finishPreparation() }
                guard let split, !Task.isCancelled else { return }
                TranscriptPartsCache.shared.store(split, for: key, source: source)
                if self.parts != split { self.parts = split }
                self.message.markRenderChanged()
            }
            return
        }
        guard thinking?.revision != revision else { return }
        let source = message.thinking
        let id = message.id
        preparation = Task { @MainActor [weak self] in
            let fresh = try? await ThinkingPreparation.shared.prepare(id: id, source: source, revision: revision)
            guard let self else { return }
            defer { self.finishPreparation() }
            guard let fresh, !Task.isCancelled else { return }
            PreparedThinkingCache.shared.store(fresh, for: id)
            self.thinking = fresh
            self.message.markRenderChanged()
        }
    }

    private func finishPreparation() {
        preparation = nil
        if pending {
            pending = false
            prepare()
        }
    }

    func segment(_ index: Int) -> ThinkingSegment? {
        guard let thinking, thinking.segments.indices.contains(index) else { return nil }
        return thinking.segments[index]
    }
}

/// How often streaming text is prepared and laid out again: every 120 ms, as before, or every 400 ms
/// while output arrives faster than anyone reads (more than 4 KB since the last sample). Following a
/// stream lays out the newest screen of text on each update, so a very fast stream would otherwise lay
/// out screen after screen that is gone before it can be read.
enum StreamSampling {
    static let readableBytes = 4 * 1_024

    static func interval(grewBy bytes: Int) -> Duration {
        bytes > readableBytes ? .milliseconds(400) : .milliseconds(120)
    }
}

/// Fold or full (ADR-0104): folded, reasoning is one "Thought for" line; open, all of it is shown.
/// Streaming reasoning is open; completed reasoning folds unless the reader chose otherwise or folding
/// is off.
@MainActor enum ReasoningDisclosure {
    static var foldsCompleted: () -> Bool = { AppModel.shared.foldsCompletedReasoning }

    static func isOpen(_ message: ChatMessage) -> Bool {
        ReasoningDisclosureStore.shared.choice(for: message.id)?.isOpen ?? (!message.complete || !foldsCompleted())
    }
}
