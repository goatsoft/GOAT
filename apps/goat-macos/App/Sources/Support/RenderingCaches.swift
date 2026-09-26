import Foundation
import Paddock

/// Process-lifetime pressure notifications release disposable render work. Live view state and
/// durable SQLite/file records are untouched; caches can rebuild after eviction (ADR-0056).
@MainActor
enum RenderingCaches {
    private static let pressureSource: DispatchSourceMemoryPressure = {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler {
            Task { await clear() }
        }
        source.activate()
        return source
    }()

    static func startMemoryPressureMonitoring() { _ = pressureSource }

    nonisolated static func clear() async {
        await MarkdownRenderCache.shared.removeAll()
        await MarkdownSegmentCache.shared.removeAll()
        await ImageFileWorker.shared.clearCache()
        await PaddockDocumentCache.shared.removeAll()
        ToolEventPresentationCache.shared.removeAll()
        await MainActor.run {
            HighlightCache.shared.removeAll()
            TranscriptPartsCache.shared.removeAll()
            PreparedMarkdownDocumentCache.shared.removeAll()
            JSONValueCache.shared.removeAll()
        }
    }
}
