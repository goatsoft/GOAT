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
        parseCount += 1
        entries[id] = Entry(
            source: source,
            content: content,
            sourceBytes: bytes,
            access: access)
        sourceBytes += bytes
        evictIfNeeded()
        return .parsed(content)
    }

    func removeAll() {
        entries.removeAll()
        sourceBytes = 0
    }

    func snapshot() -> Snapshot {
        Snapshot(
            entryCount: entries.count,
            sourceBytes: sourceBytes,
            parseCount: parseCount)
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
    }

    var body: some View {
        Group {
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
        .task(id: request) {
            let result = await MarkdownRenderCache.shared.prepare(id: id, source: source)
            guard !Task.isCancelled else { return }
            preparedRequest = request
            preparation = result
            if case .parsed = result { onPrepared() }
        }
    }
}

/// Present a bounded Markdown snapshot at most four times a second while streaming. Incomplete
/// artifacts remain source-only, so a new token never reloads a WebKit document.
struct StreamingMarkdownView: View {
    @Bindable var message: ChatMessage
    @Environment(AppModel.self) private var model
    @State private var snapshot = ""

    var body: some View {
        PreparedMarkdownView(
            id: message.id, source: snapshot, fallbackFontSize: model.chatFontSize,
            retainsPreviousContent: true
        ) { content in
            Markdown(content)
                .markdownImageProvider(BlockedMarkdownImageProvider())
                .markdownInlineImageProvider(BlockedMarkdownInlineImageProvider())
                .goatMarkdownStyle(fontSize: model.chatFontSize, isStreaming: true)
                .textSelection(.enabled)
        }
        .task(id: message.id) {
            while !Task.isCancelled {
                snapshot = message.text
                if message.complete { return }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }
}
