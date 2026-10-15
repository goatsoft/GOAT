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
    /// Prepared with the parse, never by a code-block view on MainActor.
    let codeLiterals: [String]?
    let codeLiteralBytes: Int

    init(value: MarkdownContent, renderedHTML: String? = nil, preparesCodeIdentity: Bool = true) {
        self.value = value
        codeLiterals =
            preparesCodeIdentity ? CodeBlockPositions.codeBlocks(html: renderedHTML ?? value.renderHTML()) : nil
        codeLiteralBytes =
            codeLiterals.map { literals in
                literals.reduce(0) { $0 + $1.utf8.count }
                    + literals.capacity * MemoryLayout<String>.stride + literals.count * 32
            } ?? 0
    }
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

    func contains(id: UUID) -> Bool {
        cache.object(forKey: id as NSUUID) != nil
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
            // Whole-document views do not install a CodeBlockScope. Only segmented replies need literals.
            PreparedMarkdownContent(
                value: MarkdownContent(GOATMarkdownSyntax.normalized(source)), preparesCodeIdentity: false)
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
    /// Text above the parts threshold, as bounded plain parts (the transcript splits such text into
    /// items of its own, ADR-0104; elsewhere each part is one bounded text view).
    @State private var parts: [String]?

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
                // Plain, selectable, in parts: one text view of the whole source would lay out every
                // byte on the main thread at once.
                if let parts {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(parts.indices, id: \.self) { index in
                            TranscriptPlainPart(text: parts[index], fontSize: fallbackFontSize)
                        }
                    }
                } else {
                    Label("Formatting response…", systemImage: "text.badge.checkmark")
                        .font(Font(ReadingFonts.nsFont(model.effectiveChatFontID, size: fallbackFontSize, role: .chat)))
                        .foregroundStyle(.secondary)
                }
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
            guard source.utf8.count <= TranscriptTextParts.maximumBytes else {
                let key = "\(id.uuidString):plain"
                if let cached = TranscriptPartsCache.shared.parts(for: key, source: source) {
                    parts = cached
                    return
                }
                let source = source
                let split = await Task.detached(priority: .userInitiated) { try? TranscriptTextParts.split(source) }
                    .value
                guard !Task.isCancelled, let split else { return }
                TranscriptPartsCache.shared.store(split, for: key, source: source)
                parts = split
                return
            }
            let result = await MarkdownRenderCache.shared.prepare(id: id, source: source)
            // Kept when the row left before it finished, so its next mount renders formatted, but never
            // in place of a newer text's preparation.
            if case .parsed(let content) = result,
                !Task.isCancelled || !MarkdownContentCache.shared.contains(id: id)
            {
                MarkdownContentCache.shared.set(id: id, source: source, content: content)
            }
            guard !Task.isCancelled else { return }
            preparedRequest = request
            preparation = result
            if case .parsed = result { onPrepared() }
        }
    }
}
