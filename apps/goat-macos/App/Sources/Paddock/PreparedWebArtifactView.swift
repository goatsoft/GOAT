import AppKit
import Caprine
import Paddock
import SwiftUI

/// Inline previews share a small admission budget, never a website data store. Retiring a slot
/// destroys that artifact's web view; the inspector has its own single explicitly opened preview.
@MainActor @Observable final class InlinePreviewBudget {
    static let shared = InlinePreviewBudget()
    let limit: Int
    private(set) var requested: [UUID] = []

    init(limit: Int = 3) { self.limit = max(1, limit) }

    func admits(_ id: UUID) -> Bool { requested.prefix(limit).contains(id) }

    func update(_ id: UUID, visible: Bool) {
        guard visible || requested.contains(id) else { return }
        if visible {
            if !requested.contains(id) { requested.append(id) }
        } else {
            requested.removeAll { $0 == id }
        }
    }
}

/// A bounded, memory-only fallback for retired inline previews. Images never cross artifact IDs.
@MainActor @Observable final class InlinePreviewSnapshots {
    static let shared = InlinePreviewSnapshots()
    let maximumBytes: Int
    let maximumEntries: Int
    private(set) var bytes = 0
    private var entries: [UUID: (image: NSImage, cost: Int)] = [:]
    private var order: [UUID] = []

    init(maximumBytes: Int = 16 * 1_024 * 1_024, maximumEntries: Int = 8) {
        self.maximumBytes = max(0, maximumBytes)
        self.maximumEntries = max(0, maximumEntries)
    }

    func image(for id: UUID) -> NSImage? { entries[id]?.image }

    func store(_ image: NSImage, for id: UUID) {
        remove(id)
        // WebKit snapshots are at display resolution; charge at least a 2x RGBA bitmap.
        let bitmapBytes = image.representations.compactMap { $0 as? NSBitmapImageRep }
            .reduce(0) { $0 + $1.bytesPerRow * $1.pixelsHigh }
        let estimated = image.size.width * image.size.height * 16
        guard estimated.isFinite, estimated >= 0, estimated <= CGFloat(maximumBytes) else { return }
        let cost = max(bitmapBytes, Int(estimated))
        guard maximumEntries > 0, cost <= maximumBytes else { return }
        while !order.isEmpty && (order.count >= maximumEntries || bytes + cost > maximumBytes) {
            remove(order[0])
        }
        entries[id] = (image, cost)
        order.append(id)
        bytes += cost
    }

    func remove(_ id: UUID) {
        if let entry = entries.removeValue(forKey: id) { bytes -= entry.cost }
        order.removeAll { $0 == id }
    }
}

/// Shared by the Paddock inspector and inline diagrams. No escaping, theme serialization or
/// Mermaid shell construction runs while SwiftUI evaluates a view body.
struct PreparedWebArtifactView: View {
    @Environment(AppModel.self) private var model
    let artifact: PaddockArtifact
    var isActive = true
    var onContentHeight: (@MainActor (CGFloat) -> Void)?
    var onSnapshot: (@MainActor (NSImage) -> Void)?
    @State private var preparedHTML: String?
    @State private var preparedRequest: Request?

    private struct Request: Equatable {
        let artifact: PaddockArtifact
        let theme: ThemeSpec
        let dark: Bool
    }
    private var request: Request {
        Request(
            artifact: artifact, theme: model.theme,
            dark: artifact.kind == .mermaid && model.theme.isDark)
    }

    var body: some View {
        Group {
            if !PaddockDocumentCache.permitsPreview(artifact) {
                ContentUnavailableView(
                    "Preview too large", systemImage: "doc.text",
                    description: Text("Open Source or save the artifact to view its full contents."))
            } else if preparedRequest == request, let preparedHTML {
                WebPreview(
                    html: preparedHTML,
                    offGrid: artifact.kind == .mermaid || model.previewsOffGrid,
                    mode: model.judasMode, bundledScripts: artifact.kind == .mermaid, isActive: isActive,
                    onContentHeight: onContentHeight, onSnapshot: onSnapshot)
            } else {
                VStack {
                    GoatLoadingIndicator()
                    Text("Preparing preview…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: request) {
            let current = request
            let html = await PaddockDocumentCache.shared.prepare(artifact, theme: model.theme, dark: current.dark)
            guard !Task.isCancelled else { return }
            preparedHTML = html
            preparedRequest = current
        }
    }
}
