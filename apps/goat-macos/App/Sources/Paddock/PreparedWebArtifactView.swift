import Caprine
import Paddock
import SwiftUI

/// Shared by the Paddock inspector and inline diagrams. No escaping, theme serialization or
/// Mermaid shell construction runs while SwiftUI evaluates a view body.
struct PreparedWebArtifactView: View {
    @Environment(AppModel.self) private var model
    let artifact: PaddockArtifact
    var isActive = true
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
                    mode: model.judasMode, bundledScripts: artifact.kind == .mermaid, isActive: isActive)
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
