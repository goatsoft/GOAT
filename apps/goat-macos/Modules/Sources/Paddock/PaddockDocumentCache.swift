import Caprine
import Foundation

/// Only immutable HTML shells are cached. No WKWebView, JavaScript state, network response or
/// permission is retained. Limits account for source and generated UTF-8 bytes (ADR-0056).
public actor PaddockDocumentCache {
    public static let shared = PaddockDocumentCache()
    public static let maximumPreviewBytes = 2 * 1_024 * 1_024
    public static let maximumDiagramBytes = 100_000

    public struct Snapshot: Sendable {
        public let entries: Int
        public let bytes: Int
        public let preparations: Int
    }
    private struct Entry {
        let artifact: PaddockArtifact
        let theme: ThemeSpec
        let dark: Bool
        let html: String
        let bytes: Int
        var access: UInt64
    }
    private var entries: [UUID: Entry] = [:]
    private var bytes = 0
    private var access: UInt64 = 0
    private var preparations = 0
    private let maximumEntries: Int
    private let maximumBytes: Int

    public init(maximumEntries: Int = 4, maximumBytes: Int = 8 * 1_024 * 1_024) {
        self.maximumEntries = max(1, maximumEntries)
        self.maximumBytes = max(1, maximumBytes)
    }

    public nonisolated static func permitsPreview(_ artifact: PaddockArtifact) -> Bool {
        let limit = artifact.kind == .mermaid ? maximumDiagramBytes : maximumPreviewBytes
        return artifact.content.utf8.count <= limit
    }

    public func prepare(_ artifact: PaddockArtifact, theme: ThemeSpec, dark: Bool) -> String? {
        guard !Task.isCancelled, Self.permitsPreview(artifact) else { return nil }
        access &+= 1
        if var entry = entries[artifact.id], entry.artifact == artifact, entry.theme == theme,
            entry.dark == (artifact.kind == .mermaid && dark)
        {
            entry.access = access
            entries[artifact.id] = entry
            return entry.html
        }
        let document: String
        switch artifact.kind {
        case .html: document = artifact.content
        case .svg: document = PaddockHTML.svgShell(artifact.content)
        case .mermaid: document = PaddockHTML.mermaidShell(artifact.content, dark: dark, theme: theme)
        case .markdown, .code: return nil
        }
        let html = document + "\n" + PaddockHTML.scrollbarStyle(theme: theme)
        guard !Task.isCancelled else { return nil }
        preparations += 1
        let cost = artifact.content.utf8.count + html.utf8.count
        if let old = entries.removeValue(forKey: artifact.id) { bytes -= old.bytes }
        if cost <= maximumBytes {
            entries[artifact.id] = Entry(
                artifact: artifact, theme: theme, dark: artifact.kind == .mermaid && dark, html: html,
                bytes: cost, access: access)
            bytes += cost
            while entries.count > maximumEntries || bytes > maximumBytes {
                guard let victim = entries.min(by: { $0.value.access < $1.value.access }) else { break }
                bytes -= victim.value.bytes
                entries.removeValue(forKey: victim.key)
            }
        }
        return html
    }

    public func removeAll() {
        entries.removeAll()
        bytes = 0
    }

    public func snapshot() -> Snapshot {
        Snapshot(entries: entries.count, bytes: bytes, preparations: preparations)
    }
}
