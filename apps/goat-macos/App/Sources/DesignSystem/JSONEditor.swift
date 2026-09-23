import AppKit
import Caprine
import Herd
import SwiftUI

protocol JSONDocumentWorker: Sendable {
    func load(_ url: URL) async -> JSONFileWorker.LoadResult
    func validationError(for text: String) async -> String?
    func save(_ data: Data, to url: URL) async -> String?
}

actor JSONFileWorker: JSONDocumentWorker {
    enum LoadResult: Sendable, Equatable {
        case missing
        case loaded(String)
        case failed(String)
    }

    static let shared = JSONFileWorker()
    private static let maximumBytes = 5 * 1_024 * 1_024

    func load(_ url: URL) -> LoadResult {
        guard !Task.isCancelled else { return .failed("Load cancelled") }
        do {
            guard
                let data = try LocalFileStore.boundedDataIfPresent(
                    at: url, maximumBytes: Self.maximumBytes)
            else { return .missing }
            guard let text = String(data: data, encoding: .utf8) else {
                return .failed("File is not valid UTF-8")
            }
            guard !Task.isCancelled else { return .failed("Load cancelled") }
            return .loaded(text)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func validationError(for text: String) -> String? {
        guard !Task.isCancelled else { return nil }
        guard let data = text.data(using: .utf8) else { return "Not UTF-8" }
        do {
            _ = try JSONSerialization.jsonObject(with: data)
            return nil
        } catch {
            let message =
                (error as NSError).userInfo["NSDebugDescription"] as? String
                ?? error.localizedDescription
            return String(message.prefix(90))
        }
    }

    func save(_ data: Data, to url: URL) -> String? {
        guard !Task.isCancelled else { return "Save cancelled" }
        guard data.count <= Self.maximumBytes else { return "Save failed: file exceeds 5 MiB" }
        do {
            try LocalFileStore.writeOwnerOnly(
                data, to: url, maximumBytes: Self.maximumBytes)
            return nil
        } catch {
            return "Save failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Editor state

@Observable @MainActor final class JSONEditorState {
    enum Phase: Equatable, Sendable {
        case loading
        case loadFailed(String)
        case validating
        case invalid(String)
        case valid
        case saving

        var isEditable: Bool {
            switch self {
            case .validating, .invalid, .valid: true
            case .loading, .loadFailed, .saving: false
            }
        }

        var isSaving: Bool {
            self == .saving
        }

        var canSave: Bool {
            self == .valid
        }
    }

    var text: String = ""
    var phase: Phase = .loading
    private(set) var isDocumentReady: Bool = false
    private(set) var documentGeneration: Int = 0
    private var saveTask: Task<Void, Never>?

    func load(from fileURL: URL, seed: String = "[]", worker: any JSONDocumentWorker = JSONFileWorker.shared) async {
        phase = .loading
        isDocumentReady = false
        documentGeneration += 1
        let currentGen = documentGeneration
        let result = await worker.load(fileURL)
        guard !Task.isCancelled, currentGen == documentGeneration else { return }
        switch result {
        case .missing:
            text = seed
            isDocumentReady = true
            await validateContent(seed, generation: currentGen, worker: worker)
        case .loaded(let loaded):
            text = loaded
            isDocumentReady = true
            await validateContent(loaded, generation: currentGen, worker: worker)
        case .failed(let error):
            phase = .loadFailed(error)
            isDocumentReady = false
        }
    }

    func validate(worker: any JSONDocumentWorker = JSONFileWorker.shared) async {
        guard isDocumentReady, !phase.isSaving else { return }
        documentGeneration += 1
        let currentGen = documentGeneration
        await validateContent(text, generation: currentGen, worker: worker)
    }

    private func validateContent(_ content: String, generation: Int, worker: any JSONDocumentWorker) async {
        phase = .validating
        do {
            try await Task.sleep(for: .milliseconds(120))
        } catch {
            return
        }
        guard !Task.isCancelled, generation == documentGeneration, isDocumentReady else { return }
        let error = await worker.validationError(for: content)
        guard !Task.isCancelled, generation == documentGeneration, isDocumentReady else { return }
        if let error {
            phase = .invalid(error)
        } else {
            phase = .valid
        }
    }

    func startSave(
        to fileURL: URL,
        onSaved: @escaping () -> Void,
        dismiss: @escaping () -> Void,
        worker: any JSONDocumentWorker = JSONFileWorker.shared
    ) {
        guard phase.canSave, isDocumentReady else { return }
        saveTask?.cancel()
        phase = .saving
        let data = Data(text.utf8)
        let currentGen = documentGeneration
        saveTask = Task { @MainActor in
            let error = await worker.save(data, to: fileURL)
            guard !Task.isCancelled, currentGen == documentGeneration else { return }
            if let error {
                phase = .invalid(error)
            } else {
                phase = .valid
                onSaved()
                dismiss()
            }
            saveTask = nil
        }
    }

    func cancelPendingSave() {
        if !phase.isSaving {
            saveTask?.cancel()
            saveTask = nil
        }
    }
}

// MARK: - Editor sheet

/// A lightweight in-app JSON editor - themed syntax highlighting, line numbers, brace match,
/// live validation. No Xcode required. "Open in Default App" stays for the user's own tool.
struct JSONEditorSheet: View {
    let title: String
    let fileURL: URL
    var seed: String = "[]"
    var onSaved: () -> Void = {}

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var state = JSONEditorState()

    var body: some View {
        GOATDialogShell(closeAction: { dismiss() }, closeDisabled: state.phase.isSaving, extraOpacity: 0.3) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title).font(.title3.weight(.semibold))
                    Spacer()
                    validity
                }

                JSONEditorView(
                    text: $state.text,
                    tokens: model.theme.tokens,
                    isEditable: state.phase.isEditable
                )
                // Fill the available space so short documents remain aligned at the top.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.18)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8).strokeBorder(model.theme.tokens.tint.opacity(0.35), lineWidth: 1))

                HStack {
                    Button("Open in Default App") { NSWorkspace.shared.open(fileURL) }
                        .buttonStyle(SecondaryChipButtonStyle())
                    Text(fileURL.path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .buttonStyle(DialogCancelButtonStyle())
                        .keyboardShortcut(.cancelAction)
                        .disabled(state.phase.isSaving)
                    Button("Save") {
                        state.startSave(to: fileURL, onSaved: onSaved, dismiss: { dismiss() })
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!state.phase.canSave)
                }
            }
            .padding(18)
            .frame(width: 680, height: 560)
        }
        .interactiveDismissDisabled(state.phase.isSaving)
        .task(id: fileURL) { await state.load(from: fileURL, seed: seed) }
        .task(id: state.text) { await state.validate() }
        .onDisappear {
            state.cancelPendingSave()
        }
    }

    @ViewBuilder private var validity: some View {
        switch state.phase {
        case .loading:
            HStack(spacing: 6) {
                GoatLoadingIndicator().controlSize(.small)
                Text("Loading")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .validating:
            HStack(spacing: 6) {
                GoatLoadingIndicator().controlSize(.small)
                Text("Checking")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .loadFailed(let error), .invalid(let error):
            Label(error, systemImage: "xmark.octagon.fill")
                .font(.caption).foregroundStyle(.orange).lineLimit(1)
        case .valid, .saving:
            Label("Valid JSON", systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.green)
        }
    }
}

// MARK: - NSTextView-backed editor

struct JSONEditorView: NSViewRepresentable {
    /// Rich regex highlighting and line-number enumeration are intentionally bounded. The editor
    /// still supports the full 5 MiB file limit as selectable, editable monospaced text.
    static let maximumHighlightedCharacters = 512 * 1_024

    @Binding var text: String
    let tokens: Caprine
    let isEditable: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        // AppKit's ruler separator can draw outside its hosted view on macOS 26. Keep native
        // drawing inside the editor so compact hosts, including permission sheets, stay intact.
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true

        let textView = scroll.documentView as! NSTextView
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor(tokens.ink)
        textView.insertionPointColor = NSColor(tokens.tint)
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.delegate = context.coordinator

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        textView.string = text
        context.coordinator.highlight(textView: textView)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }
        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
            context.coordinator.highlight(textView: textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: JSONEditorView
        private var isHighlighting = false

        init(_ parent: JSONEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            highlight(textView: textView)
        }

        func highlight(textView: NSTextView) {
            guard !isHighlighting else { return }
            isHighlighting = true
            defer { isHighlighting = false }
            JSONStyler.apply(to: textView, tokens: parent.tokens)
        }
    }
}

// MARK: - Syntax highlighter

enum JSONStyler {
    static func apply(to textView: NSTextView, tokens: Caprine) {
        guard let storage = textView.textStorage else { return }
        let string = storage.string
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        guard fullRange.length <= JSONEditorView.maximumHighlightedCharacters else {
            storage.addAttributes(
                [
                    .foregroundColor: NSColor(tokens.ink),
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                ], range: fullRange)
            return
        }

        storage.beginEditing()
        storage.addAttributes(
            [
                .foregroundColor: NSColor(tokens.ink),
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            ], range: fullRange)

        let patterns: [(pattern: String, color: NSColor)] = [
            ("\"(?:\\\\.|[^\"\\\\])*\"(?=\\s*:)", NSColor(tokens.tint)),
            (":\\s*(\"(?:\\\\.|[^\"\\\\])*\")", NSColor(Caprine.Semantic.success)),
            ("\\b(-?\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?)\\b", NSColor(tokens.accent)),
            ("\\b(true|false|null)\\b", NSColor(Caprine.Semantic.warning)),
            ("[\\[\\]{}]", NSColor(tokens.muted)),
        ]

        for (pattern, color) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            regex.enumerateMatches(in: string, range: fullRange) { match, _, _ in
                guard let match else { return }
                let range =
                    match.numberOfRanges > 1 ? match.range(at: 1) : match.range
                if range.location != NSNotFound {
                    storage.addAttribute(.foregroundColor, value: color, range: range)
                }
            }
        }
        storage.endEditing()
    }
}
