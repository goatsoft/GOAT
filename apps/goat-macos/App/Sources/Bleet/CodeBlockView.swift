import AppKit
import Caprine
import MarkdownUI
import Paddock
import SwiftUI

/// A frameless artifact with a compact display switch and secondary actions below the content.
struct CodeBlockView: View {
    let configuration: CodeBlockConfiguration
    var isStreaming = false
    @Environment(AppModel.self) private var model
    @State private var showingSource = false
    @State private var artifactID = UUID()
    @State private var hovering = false
    @FocusState private var keyboardFocused: Bool
    @State private var keyboardNavigation = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    private var controlsVisible: Bool { hovering || keyboardFocused || keyboardNavigation || voiceOverEnabled }

    private var language: String? { configuration.language }
    private var code: String {
        configuration.content
    }
    private var kind: PaddockArtifact.Kind {
        PaddockArtifact.kind(forFenceLanguage: language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ArtifactTypeLabel(kind: kind)
                if isStreaming {
                    Text("Receiving…").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                if isInlinePreviewable && !isStreaming {
                    ArtifactDisplaySwitch(showingSource: $showingSource, compact: true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(controlsVisible)
            .accessibilityHidden(!controlsVisible)

            if isInlinePreviewable && !isStreaming {
                ZStack(alignment: .topLeading) {
                    PreparedWebArtifactView(
                        artifact: PaddockArtifact(id: artifactID, kind: kind, content: code),
                        isActive: !showingSource
                    )
                    .frame(height: kind == .mermaid ? 280 : 340)
                    .opacity(showingSource ? 0 : 1)
                    .allowsHitTesting(!showingSource)
                    .accessibilityHidden(showingSource)
                    if showingSource {
                        ScrollView(.vertical) {
                            HighlightedCodeView(
                                code: code, fontSize: model.codeFontSize, showLineNumbers: true,
                                language: kind == .mermaid ? "plaintext" : language)
                        }
                        .frame(height: kind == .mermaid ? 280 : 340)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Caprine.Activity.radius))
            } else {
                HighlightedCodeView(code: code, fontSize: model.codeFontSize, language: language)
            }
            HStack(spacing: 16) {
                Spacer()
                CopyButton(text: code)
                    .accessibilityLabel("Copy source")
                Button("Save artifact", systemImage: "arrow.down.to.line") {
                    PaddockExporter.save(PaddockArtifact(kind: kind, content: code))
                }
                .help("Save artifact")
                Button("Open in Paddock", systemImage: "sidebar.right") {
                    model.openInPaddock(PaddockArtifact(kind: kind, content: code))
                }
                .help("Open in Paddock")
            }
            .buttonStyle(.plain)
            .labelStyle(.iconOnly)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(controlsVisible)
            .accessibilityHidden(!controlsVisible)
        }
        .frame(maxWidth: 820, alignment: .leading)
        .background(
            model.theme.tokens.surface.opacity(controlsVisible ? 0.22 : 0),
            in: RoundedRectangle(cornerRadius: Caprine.Activity.radius)
        )
        .contentShape(Rectangle())
        .onHover {
            hovering = $0
            if !$0 { keyboardNavigation = false }
        }
        .focusable(interactions: .activate)
        .focused($keyboardFocused)
        .onChange(of: keyboardFocused) {
            if keyboardFocused { keyboardNavigation = true }
        }
        .focusEffectDisabled()
        .accessibilityLabel("\(kind.label) artifact")
    }

    private var isInlinePreviewable: Bool {
        switch kind {
        case .html, .svg, .mermaid: true
        case .markdown, .code: false
        }
    }

}

/// Save-panel export for artifacts (also used by the Paddock pane).
enum PaddockExporter {
    @MainActor
    static func save(_ artifact: PaddockArtifact) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = artifact.suggestedFilename
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try await Task.detached(priority: .utility) {
                        try artifact.content.write(to: url, atomically: true, encoding: .utf8)
                    }.value
                } catch {
                    let alert = NSAlert(error: error)
                    alert.messageText = "Could not save artifact"
                    alert.runModal()
                }
            }
        }
    }
}
