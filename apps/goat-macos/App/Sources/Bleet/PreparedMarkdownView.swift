import Bleet
import Foundation
import Hoofprint
import MarkdownUI
import SwiftUI

/// MarkdownUI's parsed content is an immutable value but the dependency does not declare it
/// Sendable. This narrow wrapper permits the already-parsed value to cross from the cache actor to
/// MainActor. Views remain the only consumer and never mutate the wrapped content.
struct PreparedMarkdownContent: @unchecked Sendable {
    let value: MarkdownContent
}

enum MarkdownPreparation: Sendable {
    case parsed(PreparedMarkdownContent)
    case plainText
}

/// Synchronous MainActor cache for parsed markdown so already-seen or warm documents render on frame 0.
@MainActor
final class MarkdownContentCache {
    static let shared = MarkdownContentCache()
    private let cache = NSCache<NSUUID, CacheEntry>()

    final class CacheEntry: @unchecked Sendable {
        let source: String
        let content: PreparedMarkdownContent
        init(source: String, content: PreparedMarkdownContent) {
            self.source = source
            self.content = content
        }
    }

    init() {
        cache.countLimit = 128
    }

    func peek(id: UUID, source: String) -> PreparedMarkdownContent? {
        guard let entry = cache.object(forKey: id as NSUUID), entry.source == source else { return nil }
        return entry.content
    }

    func set(id: UUID, source: String, content: PreparedMarkdownContent) {
        cache.setObject(CacheEntry(source: source, content: content), forKey: id as NSUUID)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

/// Bounded LRU cache for completed Markdown. Parsing happens on this actor, never while SwiftUI is
/// evaluating a transcript row. Cost uses source bytes as a stable admission proxy.
actor MarkdownRenderCache {
    struct Snapshot: Sendable, Equatable {
        let entryCount: Int
        let sourceBytes: Int
        let parseCount: Int
    }

    static let shared = MarkdownRenderCache()

    private struct Entry {
        let source: String
        let content: PreparedMarkdownContent
        let sourceBytes: Int
        var access: UInt64
    }

    private let maximumEntries: Int
    private let maximumSourceBytes: Int
    private let maximumEntrySourceBytes: Int
    private var entries: [UUID: Entry] = [:]
    private var sourceBytes = 0
    private var access: UInt64 = 0
    private var parseCount = 0

    init(
        maximumEntries: Int = 32,
        maximumSourceBytes: Int = 8 * 1_024 * 1_024,
        maximumEntrySourceBytes: Int = 2 * 1_024 * 1_024
    ) {
        self.maximumEntries = max(1, maximumEntries)
        self.maximumSourceBytes = max(1, maximumSourceBytes)
        self.maximumEntrySourceBytes = max(1, maximumEntrySourceBytes)
    }

    func prepare(id: UUID, source: String) -> MarkdownPreparation {
        guard !Task.isCancelled else { return .plainText }
        let bytes = source.utf8.count
        guard bytes <= maximumEntrySourceBytes, bytes <= maximumSourceBytes else {
            return .plainText
        }
        access &+= 1
        if var entry = entries[id], entry.source == source {
            entry.access = access
            entries[id] = entry
            return .parsed(entry.content)
        }
        if let replaced = entries.removeValue(forKey: id) {
            sourceBytes -= replaced.sourceBytes
        }

        let content = RenderSignposts.measure("MarkdownParse") {
            PreparedMarkdownContent(value: MarkdownContent(GOATMarkdownSyntax.normalized(source)))
        }
        guard !Task.isCancelled else { return .plainText }

        parseCount &+= 1
        entries[id] = Entry(source: source, content: content, sourceBytes: bytes, access: access)
        sourceBytes += bytes
        evictIfNeeded()
        return .parsed(content)
    }

    func removeAll() async {
        entries.removeAll()
        sourceBytes = 0
        await MainActor.run { MarkdownContentCache.shared.removeAll() }
    }

    func snapshot() -> Snapshot {
        Snapshot(entryCount: entries.count, sourceBytes: sourceBytes, parseCount: parseCount)
    }

    private func evictIfNeeded() {
        while entries.count > maximumEntries || sourceBytes > maximumSourceBytes {
            guard let victim = entries.min(by: { $0.value.access < $1.value.access }) else {
                return
            }
            sourceBytes -= victim.value.sourceBytes
            entries.removeValue(forKey: victim.key)
        }
    }
}

/// Parses completed Markdown once on `MarkdownRenderCache` and reuses that value through hover,
/// theme, scrolling, and LazyVStack reappearance. Very large content remains selectable plain text.
struct PreparedMarkdownView<Rendered: View>: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    let source: String
    let fallbackFontSize: CGFloat
    let onPrepared: () -> Void
    let retainsPreviousContent: Bool
    let render: (MarkdownContent) -> Rendered
    private struct Request: Equatable {
        let id: UUID
        let source: String
    }
    private var request: Request { Request(id: id, source: source) }
    @State private var preparedRequest: Request?
    @State private var preparation: MarkdownPreparation?

    init(
        id: UUID,
        source: String,
        fallbackFontSize: CGFloat,
        onPrepared: @escaping () -> Void = {},
        retainsPreviousContent: Bool = false,
        @ViewBuilder render: @escaping (MarkdownContent) -> Rendered
    ) {
        self.id = id
        self.source = source
        self.fallbackFontSize = fallbackFontSize
        self.onPrepared = onPrepared
        self.retainsPreviousContent = retainsPreviousContent
        self.render = render

        if let cached = MarkdownContentCache.shared.peek(id: id, source: source) {
            _preparedRequest = State(initialValue: Request(id: id, source: source))
            _preparation = State(initialValue: .parsed(cached))
        }
    }

    var body: some View {
        Group {
            if source.utf8.count > TranscriptTextParts.maximumBytes {
                TranscriptTextPartsView(
                    source: source, fontSize: fallbackFontSize, cacheKey: "\(id.uuidString):text",
                    onPrepared: onPrepared)
            } else {
                switch preparedRequest == request || retainsPreviousContent ? preparation : nil {
                case .parsed(let content):
                    render(content.value)
                case .plainText:
                    Text(source)
                        .font(Font(ReadingFonts.nsFont(model.effectiveChatFontID, size: fallbackFontSize, role: .chat)))
                        .textSelection(.enabled)
                case nil:
                    // Never flash raw Markdown while a saved transcript is being prepared. The
                    // cache actor keeps parsing off the UI thread; this short placeholder is less
                    // disruptive than showing fences and then replacing them a moment later.
                    Label("Formatting response…", systemImage: "text.badge.checkmark")
                        .font(Font(ReadingFonts.nsFont(model.effectiveChatFontID, size: fallbackFontSize, role: .chat)))
                        .foregroundStyle(.secondary)
                }
            }
        }
        // Align the document boundary without searching nested lists and code scrollers.
        .alignmentGuide(.leading) { _ in 0 }
        .alignmentGuide(.trailing) { dimensions in dimensions.width }
        .task(id: request) {
            guard source.utf8.count <= TranscriptTextParts.maximumBytes else { return }
            let result = await MarkdownRenderCache.shared.prepare(id: id, source: source)
            guard !Task.isCancelled else { return }
            preparedRequest = request
            preparation = result
            if case .parsed(let content) = result {
                MarkdownContentCache.shared.set(id: id, source: source, content: content)
                onPrepared()
            }
        }
    }
}

/// Unified, stable Markdown view for both streaming and complete states without view-identity swapping.
/// The reply renders as segments (#60 A1, ADR-0091): settled segments are prepared once and keep
/// their views while only the streaming tail is re-prepared. The message's text revision identifies
/// each sample, so refreshes never compare the reply's text. Text above 8 KiB keeps the plain-text
/// parts fallback until segment-level windowing (step 3) bounds what one reply lays out.
struct StreamingMarkdownView: View {
    @Bindable var message: ChatMessage
    @Environment(AppModel.self) private var model
    @State private var snapshot: Snapshot
    @State private var document: PreparedMarkdownDocument?

    /// The text and completion sampled together, so completion always prepares the final text. The
    /// revision identifies the text, so equality never reads it.
    private struct Snapshot: Equatable {
        let revision: TextRevision
        let isComplete: Bool
        let source: String

        static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs.revision == rhs.revision && lhs.isComplete == rhs.isComplete
        }
    }

    init(message: ChatMessage) {
        self.message = message
        _snapshot = State(
            initialValue: Snapshot(revision: message.textRevision, isComplete: message.complete, source: message.text))
        // Seed only from an already-prepared document. SwiftUI evaluates this initializer on every
        // parent update, so it must stay a lookup. A streaming reply may show its last prepared
        // document until the current text is ready, as the view itself does between refreshes.
        let cache = PreparedMarkdownDocumentCache.shared
        _document = State(
            initialValue: cache.document(for: message.id, revision: message.textRevision)
                ?? (message.complete ? nil : cache.latest(for: message.id)))
    }

    var body: some View {
        Group {
            if snapshot.revision.utf8Count > TranscriptTextParts.maximumBytes {
                TranscriptTextPartsView(
                    source: snapshot.source, fontSize: model.chatFontSize, cacheKey: "\(message.id.uuidString):text",
                    onPrepared: { message.markRenderChanged() })
            } else if let document {
                SegmentedMarkdownView(document: document, fontSize: model.chatFontSize, isStreaming: !message.complete)
            } else {
                // Never flash raw Markdown while a saved reply is being prepared off the main actor.
                Label("Formatting response…", systemImage: "text.badge.checkmark")
                    .font(Font(ReadingFonts.nsFont(model.effectiveChatFontID, size: model.chatFontSize, role: .chat)))
                    .foregroundStyle(.secondary)
            }
        }
        // Align the document boundary without searching nested lists and code scrollers.
        .alignmentGuide(.leading) { _ in 0 }
        .alignmentGuide(.trailing) { dimensions in dimensions.width }
        .task(id: snapshot) {
            let request = snapshot
            guard request.revision.utf8Count <= TranscriptTextParts.maximumBytes else { return }
            if let document, document.matches(request.revision, isComplete: request.isComplete) { return }
            guard
                let prepared = await MarkdownSegmentCache.shared.prepare(
                    id: message.id, source: request.source, revision: request.revision,
                    isComplete: request.isComplete),
                !Task.isCancelled
            else { return }
            document = prepared
            PreparedMarkdownDocumentCache.shared.store(prepared, for: message.id)
            message.markRenderChanged()
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
    }

    private func sample() {
        let revision = message.textRevision
        guard revision != snapshot.revision || message.complete != snapshot.isComplete else { return }
        snapshot = Snapshot(revision: revision, isComplete: message.complete, source: message.text)
    }
}
