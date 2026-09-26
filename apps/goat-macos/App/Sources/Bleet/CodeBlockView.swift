import AppKit
import Caprine
import MarkdownUI
import Paddock
import SwiftUI

/// A fenced code block's info string, read as a language and an optional filename (#60 A6).
///
/// Accepted forms: `swift`, `{.swift}`, `ts:src/app.ts`, `swift title="Foo.swift"` (also
/// `filename=`, `file=`, `name=`, `path=`), and `python app.py` when the second word looks like a path.
struct FenceInfo: Equatable, Sendable {
    let language: String?
    let filename: String?

    init(language: String?, filename: String?) {
        self.language = language
        self.filename = filename
    }

    init(_ info: String?) {
        let words = Self.words(info ?? "")
        var language = words.first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "{}.")) }
        var filename: String?
        if let word = language, let colon = word.firstIndex(of: ":"), colon != word.startIndex {
            let path = String(word[word.index(after: colon)...])
            language = String(word[..<colon])
            filename = path.isEmpty ? nil : path
        }
        for word in words.dropFirst() where filename == nil {
            if let equals = word.firstIndex(of: "=") {
                let key = word[..<equals].lowercased()
                let value = word[word.index(after: equals)...].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if ["title", "filename", "file", "name", "path"].contains(key), !value.isEmpty { filename = value }
            } else if word.contains(".") || word.contains("/") {
                filename = word
            }
        }
        self.language = language.flatMap { $0.isEmpty ? nil : $0 }
        self.filename = filename
    }

    /// Whitespace-separated words, keeping quoted values together.
    private static func words(_ info: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        for character in info.trimmingCharacters(in: .whitespacesAndNewlines) {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}

/// The reader's per-block choices (word wrap, expansion), kept for the session so a block that
/// SwiftUI recreates keeps them (#60 A6). A block is identified by its language and first bytes,
/// which stay the same while it streams. Bounded; the oldest are dropped.
@MainActor final class CodeBlockStateStore {
    static let shared = CodeBlockStateStore()

    struct State: Equatable {
        var wordWrap: Bool?
        var isExpanded = false
    }

    let limit: Int
    private var states: [String: State] = [:]
    private var order: [String] = []

    init(limit: Int = 512) {
        self.limit = max(1, limit)
    }

    static func key(language: String?, code: String) -> String {
        (language ?? "") + "\u{1}" + (String(code.utf8.prefix(256)) ?? String(code.prefix(64)))
    }

    func state(for key: String) -> State { states[key] ?? State() }

    func set(_ state: State, for key: String) {
        if states.updateValue(state, forKey: key) == nil { order.append(key) }
        while order.count > limit { states[order.removeFirst()] = nil }
    }
}

/// A fenced code block or inline artifact (#60 A6). A compact header is always shown: kind, language,
/// filename when the info string names one, line count and copy. Wrap, save and Paddock actions
/// appear over the block on hover or focus without reserving space. Code longer than
/// `Caprine.Code.collapsedLineLimit` lines shows its first lines and an explicit action for the rest,
/// while streaming too, so completion never changes its height.
struct CodeBlockView: View {
    let configuration: CodeBlockConfiguration
    var isStreaming = false
    @Environment(AppModel.self) private var model
    @State private var showingSource = false
    @State private var artifactID = UUID()
    @State private var hovering = false
    @State private var blockState: CodeBlockStateStore.State?
    @FocusState private var keyboardFocused: Bool
    @State private var keyboardNavigation = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    private var controlsVisible: Bool { hovering || keyboardFocused || keyboardNavigation || voiceOverEnabled }

    private var info: FenceInfo { FenceInfo(configuration.language) }
    private var code: String { configuration.content }
    private var kind: PaddockArtifact.Kind { PaddockArtifact.kind(forFenceLanguage: info.language) }
    private var stateKey: String { CodeBlockStateStore.key(language: info.language, code: code) }
    private var state: CodeBlockStateStore.State { blockState ?? CodeBlockStateStore.shared.state(for: stateKey) }
    private var wordWrap: Bool { state.wordWrap ?? model.codeWordWrap }

    private func update(_ change: (inout CodeBlockStateStore.State) -> Void) {
        var next = state
        change(&next)
        blockState = next
        CodeBlockStateStore.shared.set(next, for: stateKey)
    }

    var body: some View {
        let lineCount = HighlightCache.shared.lineCount(for: code)
        let limit = Caprine.Code.collapsedLineLimit
        let collapses = !isInlinePreviewable && lineCount > limit
        let shownCode = collapses && !state.isExpanded ? Self.prefix(of: code, lines: limit) : code
        VStack(alignment: .leading, spacing: 0) {
            header(lineCount: lineCount)

            if isInlinePreviewable && !isStreaming {
                let height = kind == .mermaid ? Caprine.Code.diagramPreviewHeight : Caprine.Code.previewHeight
                ZStack(alignment: .topLeading) {
                    PreparedWebArtifactView(
                        artifact: PaddockArtifact(id: artifactID, kind: kind, content: code),
                        isActive: !showingSource
                    )
                    .frame(height: height)
                    .opacity(showingSource ? 0 : 1)
                    .allowsHitTesting(!showingSource)
                    .accessibilityHidden(showingSource)
                    if showingSource {
                        ScrollView(.vertical, showsIndicators: false) {
                            HighlightedCodeView(
                                code: code, fontSize: model.codeFontSize, showLineNumbers: true,
                                language: kind == .mermaid ? "plaintext" : info.language,
                                wordWrap: wordWrap, externalHover: hovering
                            )
                        }
                        .scrollIndicators(.hidden)
                        .frame(height: height)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Caprine.Activity.radius))
            } else {
                HighlightedCodeView(
                    code: shownCode, fontSize: model.codeFontSize, language: info.language, isStreaming: isStreaming,
                    wordWrap: wordWrap, externalHover: hovering
                )
            }
            if collapses {
                Button(state.isExpanded ? "Show fewer lines" : "Show \(lineCount - limit) more lines") {
                    update { $0.isExpanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(model.theme.tokens.tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if controlsVisible { actions }
        }
        .frame(maxWidth: Caprine.Code.maxWidth, alignment: .leading)
        .background(
            model.theme.tokens.surface.opacity(Caprine.Code.surfaceOpacity),
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

    /// Kind, language, filename, line count and copy, shown at rest.
    private func header(lineCount: Int) -> some View {
        HStack(spacing: 8) {
            ArtifactTypeLabel(kind: kind)
            if case .code = kind, let language = info.language {
                Text(language)
            }
            if let filename = info.filename {
                Text(filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(model.theme.tokens.ink)
            }
            Text(lineCount == 1 ? "1 line" : "\(lineCount) lines")
                .monospacedDigit()
            if isStreaming {
                Text("Receiving…").foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if isInlinePreviewable && !isStreaming {
                ArtifactDisplaySwitch(showingSource: $showingSource, compact: true)
            }
            CopyButton(text: code)
                .accessibilityLabel("Copy source")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("code-block-header")
    }

    /// Secondary actions over the block's corner, visible on hover, focus or with VoiceOver.
    private var actions: some View {
        HStack(spacing: 16) {
            Button {
                update { $0.wordWrap = !wordWrap }
            } label: {
                Image(systemName: "arrow.turn.down.left")
                    .padding(3)
                    .background(
                        wordWrap ? model.theme.tokens.tint.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4)
                    )
            }
            .help(wordWrap ? "Disable word wrap" : "Enable word wrap")
            .accessibilityLabel(wordWrap ? "Disable word wrap" : "Enable word wrap")
            .foregroundStyle(wordWrap ? model.theme.tokens.tint : .secondary)
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
        .padding(.vertical, 6)
        .background(model.theme.tokens.surface, in: RoundedRectangle(cornerRadius: Caprine.Activity.radius))
        .padding(8)
    }

    private var isInlinePreviewable: Bool {
        switch kind {
        case .html, .svg, .mermaid: true
        case .markdown, .code: false
        }
    }

    /// The first `lines` lines of `code`, without the final line break.
    static func prefix(of code: String, lines: Int) -> String {
        var remaining = lines
        var index = code.startIndex
        while index < code.endIndex {
            if code[index] == "\n" {
                remaining -= 1
                if remaining == 0 { return String(code[..<index]) }
            }
            index = code.index(after: index)
        }
        return code
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
