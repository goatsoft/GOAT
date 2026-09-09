import Caprine
import JUDAS
import MarkdownUI
import Paddock
import SwiftUI

/// The Paddock - where the goat's creations run around. Lives in the inspector slot.
struct PaddockView: View {
    let artifact: PaddockArtifact
    @Environment(AppModel.self) private var model
    @State private var showingSource = false
    @State private var reloadID = UUID()
    @State private var hovering = false
    @FocusState private var keyboardFocused: Bool
    @State private var keyboardNavigation = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    private var controlsVisible: Bool { hovering || keyboardFocused || keyboardNavigation || voiceOverEnabled }
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                ArtifactTypeLabel(kind: artifact.kind)
                Spacer(minLength: 8)
                if mayUseNetwork {
                    Image(systemName: previewsRestricted ? "shield.checkered" : "globe")
                        .help("\(networkStatus). Change preview network access in Settings → JUDAS.")
                        .accessibilityLabel(networkStatus)
                }
                CopyButton(text: artifact.content)
                    .accessibilityLabel("Copy source")
                Button("Reload preview", systemImage: "arrow.clockwise") { reloadID = UUID() }
                    .disabled(showingSource || !artifact.isPreviewable)
                    .help("Reload preview")
                Button("Save artifact", systemImage: "arrow.down.to.line") { PaddockExporter.save(artifact) }
                    .help("Save artifact")
                Button("Close Paddock", systemImage: "xmark") { model.paddockArtifact = nil }
                    .help("Close Paddock")
            }
            .buttonStyle(.plain)
            .labelStyle(.iconOnly)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 2)
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(controlsVisible)
            .accessibilityHidden(!controlsVisible)

            if artifact.isPreviewable {
                ArtifactDisplaySwitch(showingSource: $showingSource)
                    .opacity(controlsVisible ? 1 : 0)
                    .allowsHitTesting(controlsVisible)
                    .accessibilityHidden(!controlsVisible)
            }
            content
                .id(reloadID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Caprine.Activity.radius))
        }
        .padding(12)
        .background(model.theme.tokens.surface.opacity(controlsVisible ? 0.16 : 0))
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
        .accessibilityLabel("Paddock \(artifact.kind.label) artifact")
        .onChange(of: artifact.id) {
            showingSource = false
            reloadID = UUID()
        }
    }

    private var mayUseNetwork: Bool {
        switch artifact.kind {
        case .html, .svg, .markdown: true
        case .mermaid, .code: false
        }
    }

    private var content: some View {
        ZStack {
            previewContent
                .opacity(showingSource ? 0 : 1)
                .allowsHitTesting(!showingSource)
                .accessibilityHidden(showingSource)
            if showingSource { sourceView }
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        switch artifact.kind {
        case .html, .svg, .mermaid:
            PreparedWebArtifactView(artifact: artifact, isActive: !showingSource)
        case .markdown:
            ScrollView { markdownPreview }
        case .code:
            sourceView
        }
    }

    @ViewBuilder
    private var markdownPreview: some View {
        PreparedMarkdownView(
            id: artifact.id,
            source: artifact.content,
            fallbackFontSize: model.chatFontSize
        ) { content in
            let markdown = Markdown(content)
                .goatMarkdownStyle(fontSize: model.chatFontSize)
                .markdownBlockStyle(\.codeBlock) { configuration in
                    CodeBlockView(configuration: configuration)
                }
                .textSelection(.enabled)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            markdown
                .markdownImageProvider(BlockedMarkdownImageProvider())
                .markdownInlineImageProvider(BlockedMarkdownInlineImageProvider())
                .judasLinks(offGrid: model.previewsOffGrid)
        }
    }

    private var sourceView: some View {
        ScrollView(.vertical) {
            HighlightedCodeView(
                code: artifact.content, fontSize: model.codeFontSize, showLineNumbers: true,
                language: sourceLanguage
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sourceLanguage: String? {
        switch artifact.kind {
        case .html: "html"
        case .svg: "xml"
        case .markdown: "markdown"
        case .mermaid: "plaintext"
        case .code(let language): language.isEmpty ? nil : language
        }
    }

    private var previewsRestricted: Bool {
        model.judasMode != .configured || model.previewsOffGrid
    }

    private var networkStatus: String {
        switch model.judasMode {
        case .configured: model.previewsOffGrid ? "Off-grid on" : "Off-grid off · Web allowed"
        case .localNetworksOnly: "Off-grid enforced"
        case .blocked: "Network blocked"
        }
    }
}

/// Shared artifact chrome keeps chat and the inspector visually consistent.
struct ArtifactTypeLabel: View {
    let kind: PaddockArtifact.Kind

    var body: some View {
        Label(kind.label, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }

    private var symbol: String {
        switch kind {
        case .html: "doc.richtext"
        case .svg: "photo"
        case .mermaid: "point.3.connected.trianglepath.dotted"
        case .markdown: "text.document"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// Icon links in chat; a full-width pill switch matching the website in Paddock.
struct ArtifactDisplaySwitch: View {
    @Binding var showingSource: Bool
    var compact = false
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: compact ? 2 : 3) {
            option("Preview", symbol: "eye", source: false)
            option("Source", symbol: "chevron.left.forwardslash.chevron.right", source: true)
        }
        .padding(compact ? 0 : 3)
        .background(model.theme.tokens.muted.opacity(compact ? 0 : 0.06), in: Capsule())
        .overlay {
            if !compact {
                Capsule().strokeBorder(model.theme.tokens.muted.opacity(0.2), lineWidth: 1)
            }
        }
    }

    private func option(_ title: String, symbol: String, source: Bool) -> some View {
        Button {
            showingSource = source
        } label: {
            Group {
                if compact {
                    Image(systemName: symbol)
                        .frame(width: 24, height: 24)
                } else {
                    Label(title, systemImage: symbol)
                        .labelStyle(.titleAndIcon)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
            }
            .font(.caption)
            .foregroundStyle(
                showingSource == source && !compact ? model.theme.tokens.ink : model.theme.tokens.muted
            )
            .contentShape(Capsule())
            .background(
                model.theme.tokens.muted.opacity(!compact && showingSource == source ? 0.20 : 0),
                in: Capsule()
            )
            .shadow(color: .black.opacity(!compact && showingSource == source ? 0.25 : 0), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(showingSource == source ? .isSelected : [])
        .help("Show \(title.lowercased())")
    }
}
