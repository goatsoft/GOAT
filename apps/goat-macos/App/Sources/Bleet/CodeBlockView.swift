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
    /// The fence's occurrence in its segment, from the tag `CodeBlockTags` adds while preparing.
    let occurrence: Int?

    init(language: String?, filename: String?, occurrence: Int? = nil) {
        self.language = language
        self.filename = filename
        self.occurrence = occurrence
    }

    init(_ info: String?) {
        var words = Self.words(info ?? "")
        var occurrence: Int?
        if let tag = words.lastIndex(where: { $0.hasPrefix(CodeBlockTags.key) }) {
            occurrence = Int(words[tag].dropFirst(CodeBlockTags.key.count))
            words.remove(at: tag)
        }
        self.occurrence = occurrence
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

/// Tags each fence opener in a segment with its occurrence (` goat-block=N`), so identical code blocks
/// keep distinct identities: MarkdownUI gives a code block only its info string and literal. Openers
/// precede their content, so a streaming block keeps its occurrence as it grows. `FenceInfo` strips the
/// tag. The tracker is conservative (quotes and indentation, no HTML blocks); a tagged parse whose code
/// literals contain the tag is discarded for the untagged one.
enum CodeBlockTags {
    static let key = "goat-block="

    /// `source` with every fence opener tagged, or nil when it has no fences or may hold an HTML block.
    static func tagged(_ source: String) -> String? {
        guard source.contains("```") || source.contains("~~~") else { return nil }
        var result = ""
        result.reserveCapacity(source.utf8.count + 64)
        var open: (marker: Character, count: Int)?
        var occurrence = 0
        var first = true
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if !first { result.append("\n") }
            first = false
            var rest = line.drop(while: { $0 == " " || $0 == "\t" })
            if open == nil, rest.first == "<" { return nil }
            while rest.first == ">" {
                rest = rest.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
            }
            guard let marker = rest.first, marker == "`" || marker == "~" else {
                result.append(contentsOf: line)
                continue
            }
            let count = rest.prefix(while: { $0 == marker }).count
            let info = rest.dropFirst(count)
            if let fence = open {
                if marker == fence.marker, count >= fence.count, info.allSatisfy(\.isWhitespace) { open = nil }
                result.append(contentsOf: line)
            } else if count >= 3, marker == "~" || !info.contains("`") {
                open = (marker, count)
                let body = line.hasSuffix("\r") ? line.dropLast() : line
                result.append(contentsOf: body)
                result.append(" \(key)\(occurrence)")
                if line.hasSuffix("\r") { result.append("\r") }
                occurrence += 1
            } else {
                result.append(contentsOf: line)
            }
        }
        return result
    }

    /// Whether a parse of tagged source carried a tag into a code literal (a line mistaken for an
    /// opener), so the untagged parse must be used.
    static func leaked(html: String) -> Bool {
        CodeBlockPositions.codeBlocks(html: html).contains { $0.contains(key) }
    }
}

/// Where a code block is rendered: a segment of a reply. The reader's choices for a block are kept
/// by `CodeBlockIdentity`, which stays the same while the block streams and differs between blocks
/// (#60 A6). Blocks rendered without a scope (user messages, previews) keep their choices only while
/// their view lives.
struct CodeBlockScope: Equatable, Sendable {
    let messageID: UUID
    /// The segment, or for a piece of an oversized fence the fence's first piece, so a choice applies
    /// to the whole fence.
    let segment: Int
    /// The segment's parse, whose code blocks give each block's position.
    let content: PreparedMarkdownContent
    let preparationID: UInt64
    /// A piece of an oversized fence holds exactly one block.
    let isFencePiece: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.messageID == rhs.messageID && lhs.segment == rhs.segment && lhs.preparationID == rhs.preparationID
            && lhs.isFencePiece == rhs.isFencePiece
    }
}

/// A code block's message, segment and position: its fence's occurrence in the segment, or, for a block
/// without an occurrence tag (indented code, or a segment left untagged), `literalBase` plus its
/// position among the segment's code literals. The blocks before a streaming block are settled, so its
/// position does not change as it grows.
struct CodeBlockIdentity: Hashable, Sendable {
    static let literalBase = 1 << 20

    let messageID: UUID
    let segment: Int
    let position: Int
}

extension EnvironmentValues {
    @Entry var codeBlockScope: CodeBlockScope? = nil
    /// The reply whose segments render below, for their code blocks' scope.
    @Entry var codeBlockMessageID: UUID? = nil
}

/// The code blocks of each parsed segment, in order, read once per preparation from the parse's HTML
/// (the same literal MarkdownUI gives a code block). Bounded; cleared when full.
@MainActor final class CodeBlockPositions {
    static let shared = CodeBlockPositions()

    private struct Key: Hashable {
        let messageID: UUID
        let segment: Int
        let preparationID: UInt64
    }

    let limit: Int
    private var blocks: [Key: [String]] = [:]

    init(limit: Int = 256) {
        self.limit = max(1, limit)
    }

    func identity(of code: String, occurrence: Int?, in scope: CodeBlockScope) -> CodeBlockIdentity? {
        if scope.isFencePiece {
            return CodeBlockIdentity(messageID: scope.messageID, segment: scope.segment, position: 0)
        }
        if let occurrence {
            return CodeBlockIdentity(messageID: scope.messageID, segment: scope.segment, position: occurrence)
        }
        let key = Key(messageID: scope.messageID, segment: scope.segment, preparationID: scope.preparationID)
        let list: [String]
        if let cached = blocks[key] {
            list = cached
        } else {
            list = Self.codeBlocks(html: scope.content.value.renderHTML())
            if blocks.count >= limit { blocks.removeAll() }
            blocks[key] = list
        }
        // MarkdownUI may drop the literal's final newline; match either way.
        func trimmed(_ text: String) -> Substring {
            text.dropLast(text.reversed().prefix(while: { $0 == "\n" }).count)
        }
        guard
            let position = list.firstIndex(of: code)
                ?? list.firstIndex(where: { trimmed($0) == trimmed(code) })
        else { return nil }
        return CodeBlockIdentity(
            messageID: scope.messageID, segment: scope.segment, position: CodeBlockIdentity.literalBase + position)
    }

    /// The literal of every `<pre><code>` element, in order. cmark escapes `&`, `<`, `>` and `"`.
    nonisolated static func codeBlocks(html: String) -> [String] {
        var result: [String] = []
        var rest = html[...]
        while let open = rest.range(of: "<pre><code") {
            guard let start = rest[open.upperBound...].firstIndex(of: ">"),
                let close = rest[start...].range(of: "</code></pre>")
            else { break }
            let escaped = rest[rest.index(after: start)..<close.lowerBound]
            result.append(
                escaped.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                    .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&"))
            rest = rest[close.upperBound...]
        }
        return result
    }
}

/// The reader's per-block choices (word wrap, expansion), kept for the session by block identity so a
/// block that SwiftUI recreates keeps them (#60 A6). Bounded; the oldest are dropped.
@MainActor final class CodeBlockStateStore {
    static let shared = CodeBlockStateStore()

    struct State: Equatable {
        var wordWrap: Bool?
        var isExpanded = false
    }

    let limit: Int
    private var states: [CodeBlockIdentity: State] = [:]
    private var order: [CodeBlockIdentity] = []

    init(limit: Int = 512) {
        self.limit = max(1, limit)
    }

    func state(for identity: CodeBlockIdentity) -> State { states[identity] ?? State() }

    func set(_ state: State, for identity: CodeBlockIdentity) {
        if states.updateValue(state, forKey: identity) == nil { order.append(identity) }
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
    @Environment(\.codeBlockScope) private var scope
    private var identity: CodeBlockIdentity? {
        scope.flatMap { CodeBlockPositions.shared.identity(of: code, occurrence: info.occurrence, in: $0) }
    }
    private var state: CodeBlockStateStore.State {
        blockState ?? identity.map(CodeBlockStateStore.shared.state(for:)) ?? CodeBlockStateStore.State()
    }
    private var wordWrap: Bool { state.wordWrap ?? model.codeWordWrap }

    private func update(_ change: (inout CodeBlockStateStore.State) -> Void) {
        var next = state
        change(&next)
        blockState = next
        if let identity { CodeBlockStateStore.shared.set(next, for: identity) }
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
