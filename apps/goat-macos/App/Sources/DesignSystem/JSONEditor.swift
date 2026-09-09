import AppKit
import Caprine
import Herd
import SwiftUI

private actor JSONFileWorker {
    enum LoadResult: Sendable {
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
    @State private var text = ""
    @State private var parseError: String?
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var validationPending = true
    @State private var isSaving = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        GOATDialogShell(closeAction: { dismiss() }, closeDisabled: isSaving, extraOpacity: 0.3) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title).font(.title3.weight(.semibold))
                    Spacer()
                    validity
                }

                JSONEditorView(
                    text: $text,
                    tokens: model.theme.tokens,
                    isEditable: !isLoading && !isSaving && loadError == nil
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
                        .disabled(isSaving)
                    Button("Save") { startSave() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(
                            isLoading || validationPending || isSaving || loadError != nil
                                || parseError != nil)
                }
            }
            .padding(18)
            .frame(width: 680, height: 560)
        }
        .interactiveDismissDisabled(isSaving)
        .task(id: fileURL) { await load() }
        .task(id: text) { await validate() }
        .onDisappear {
            if !isSaving {
                saveTask?.cancel()
                saveTask = nil
            }
        }
    }

    @ViewBuilder private var validity: some View {
        if isLoading || validationPending {
            HStack(spacing: 6) {
                GoatLoadingIndicator().controlSize(.small)
                Text(isLoading ? "Loading" : "Checking")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let error = loadError ?? parseError {
            Label(error, systemImage: "xmark.octagon.fill")
                .font(.caption).foregroundStyle(.orange).lineLimit(1)
        } else {
            Label("Valid JSON", systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.green)
        }
    }

    private func load() async {
        let result = await JSONFileWorker.shared.load(fileURL)
        guard !Task.isCancelled else { return }
        switch result {
        case .missing:
            text = seed
        case .loaded(let loaded):
            text = loaded
        case .failed(let error):
            loadError = error
            validationPending = false
        }
        isLoading = false
    }

    private func validate() async {
        guard loadError == nil else { return }
        validationPending = true
        do {
            try await Task.sleep(for: .milliseconds(120))
        } catch {
            return
        }
        let error = await JSONFileWorker.shared.validationError(for: text)
        guard !Task.isCancelled, loadError == nil else { return }
        parseError = error
        validationPending = false
    }

    private func startSave() {
        guard !isSaving, loadError == nil, parseError == nil else { return }
        saveTask?.cancel()
        isSaving = true
        let data = Data(text.utf8)
        saveTask = Task { @MainActor in
            await save(data)
            saveTask = nil
        }
    }

    private func save(_ data: Data) async {
        let error = await JSONFileWorker.shared.save(data, to: fileURL)
        isSaving = false
        if let error {
            parseError = error
            return
        }
        onSaved()
        dismiss()
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
        scroll.clipsToBounds = true
        scroll.contentView.clipsToBounds = true
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isRichText = false
        tv.isEditable = isEditable
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.allowsUndo = true
        tv.delegate = context.coordinator
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 6, height: 8)
        // Pin content to the top-left and grow downward. Without this the text view can
        // size to its content and sit centered in a taller scroll view.
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        let big = CGFloat.greatestFiniteMagnitude
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: big, height: big)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: big)
        tv.insertionPointColor = NSColor(tokens.tint)
        tv.selectedTextAttributes = [
            .backgroundColor: NSColor(tokens.tint).withAlphaComponent(0.25),
            .foregroundColor: NSColor(tokens.ink),
        ]
        tv.string = text

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let ruler = LineNumberRuler(textView: tv, tokens: tokens)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        context.coordinator.textView = tv
        context.coordinator.ruler = ruler
        context.coordinator.highlight()
        context.coordinator.updateRulerVisibility()
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.boundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView)
        scroll.contentView.postsBoundsChangedNotifications = true
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let previous = context.coordinator.tokens
        let colorsChanged =
            [previous.ink, previous.accent, previous.accent2, previous.glow].map { NSColor($0) }
            != [tokens.ink, tokens.accent, tokens.accent2, tokens.glow].map { NSColor($0) }
        context.coordinator.tokens = tokens
        context.coordinator.ruler?.tokens = tokens
        guard let tv = context.coordinator.textView else { return }
        tv.isEditable = isEditable
        tv.insertionPointColor = NSColor(tokens.tint)
        tv.selectedTextAttributes = [
            .backgroundColor: NSColor(tokens.tint).withAlphaComponent(0.25),
            .foregroundColor: NSColor(tokens.ink),
        ]
        if tv.string != text || colorsChanged {
            tv.string = text
            context.coordinator.cancelPendingHighlight()
            context.coordinator.highlight()
            context.coordinator.updateRulerVisibility()
        }
        // Keep the text view at least as tall as the visible area so short content pins to
        // the top instead of floating in the middle of a taller scroll view.
        let visibleHeight = nsView.contentView.bounds.height
        if visibleHeight > 0, tv.frame.height < visibleHeight {
            tv.minSize = NSSize(width: 0, height: visibleHeight)
            tv.setFrameSize(NSSize(width: tv.frame.width, height: visibleHeight))
        }
        context.coordinator.ruler?.needsDisplay = true
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.cancelPendingHighlight()
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: JSONEditorView
        var textView: NSTextView?
        var ruler: LineNumberRuler?
        var tokens: Caprine
        private var highlightTask: Task<Void, Never>?
        private var braceHighlightRanges: [NSRange] = []

        private static let punctuationRegex = try? NSRegularExpression(pattern: "[\\{\\}\\[\\]]")
        private static let numberRegex = try? NSRegularExpression(pattern: "-?\\b\\d+(\\.\\d+)?\\b")
        private static let literalRegex = try? NSRegularExpression(pattern: "\\b(true|false|null)\\b")
        private static let stringRegex = try? NSRegularExpression(pattern: "\"(\\\\.|[^\"\\\\])*\"(?!\\s*:)")
        private static let keyRegex = try? NSRegularExpression(pattern: "\"(\\\\.|[^\"\\\\])*\"(?=\\s*:)")

        init(_ parent: JSONEditorView) {
            self.parent = parent
            self.tokens = parent.tokens
        }

        // AppKit calls these on the main thread; hop the isolation checker accordingly.
        @objc nonisolated func boundsChanged() {
            MainActor.assumeIsolated { ruler?.needsDisplay = true }
        }

        nonisolated func textDidChange(_ notification: Notification) {
            MainActor.assumeIsolated {
                guard let tv = textView else { return }
                parent.text = tv.string
                scheduleHighlight()
                updateRulerVisibility()
                ruler?.needsDisplay = true
            }
        }

        nonisolated func textViewDidChangeSelection(_ notification: Notification) {
            MainActor.assumeIsolated { highlightMatchingBrace() }
        }

        func scheduleHighlight() {
            highlightTask?.cancel()
            highlightTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(75))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.highlight()
                self?.highlightTask = nil
            }
        }

        func cancelPendingHighlight() {
            highlightTask?.cancel()
            highlightTask = nil
        }

        func updateRulerVisibility() {
            guard let textView, let ruler else { return }
            ruler.scrollView?.rulersVisible =
                (textView.textStorage?.length ?? 0) <= maximumHighlightedCharacters
        }

        func highlight() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let str = tv.string as NSString
            let full = NSRange(location: 0, length: str.length)
            storage.beginEditing()
            storage.setAttributes(
                [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor(tokens.ink),
                ], range: full)
            braceHighlightRanges.removeAll(keepingCapacity: true)
            guard str.length <= maximumHighlightedCharacters else {
                storage.endEditing()
                return
            }
            // Order matters: strings/keys last so digits inside quotes aren't miscolored.
            colorize(Self.punctuationRegex, NSColor(tokens.muted), str, storage)
            colorize(Self.numberRegex, NSColor(tokens.glow), str, storage)
            colorize(Self.literalRegex, NSColor(tokens.accent2), str, storage)
            colorize(
                Self.stringRegex,
                NSColor(tokens.accent2).blended(withFraction: 0.15, of: .white) ?? NSColor(tokens.accent2), str, storage
            )
            colorize(Self.keyRegex, NSColor(tokens.accent), str, storage)
            storage.endEditing()
            highlightMatchingBrace()
        }

        private func colorize(
            _ regex: NSRegularExpression?, _ color: NSColor, _ str: NSString,
            _ storage: NSTextStorage
        ) {
            guard let regex else { return }
            regex.enumerateMatches(in: str as String, range: NSRange(location: 0, length: str.length)) { match, _, _ in
                if let r = match?.range { storage.addAttribute(.foregroundColor, value: color, range: r) }
            }
        }

        private func highlightMatchingBrace() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let str = tv.string as NSString
            for range in braceHighlightRanges where NSMaxRange(range) <= storage.length {
                storage.removeAttribute(.backgroundColor, range: range)
            }
            braceHighlightRanges.removeAll(keepingCapacity: true)
            guard str.length <= maximumHighlightedCharacters else { return }
            let sel = tv.selectedRange()
            guard sel.length == 0, sel.location > 0, sel.location <= str.length else { return }
            let ch = str.substring(with: NSRange(location: sel.location - 1, length: 1))
            let opens = ["{": "}", "[": "]"]
            let closes = ["}": "{", "]": "["]
            let hl = NSColor(tokens.tint).withAlphaComponent(0.35)
            if let close = opens[ch], let match = findForward(str, from: sel.location, open: ch, close: close) {
                addBraceHighlight(at: sel.location - 1, color: hl, storage: storage)
                addBraceHighlight(at: match, color: hl, storage: storage)
            } else if let open = closes[ch],
                let match = findBackward(str, from: sel.location - 1, open: open, close: ch)
            {
                addBraceHighlight(at: sel.location - 1, color: hl, storage: storage)
                addBraceHighlight(at: match, color: hl, storage: storage)
            }
        }

        private func addBraceHighlight(at location: Int, color: NSColor, storage: NSTextStorage) {
            let range = NSRange(location: location, length: 1)
            storage.addAttribute(.backgroundColor, value: color, range: range)
            braceHighlightRanges.append(range)
        }

        private func findForward(_ str: NSString, from: Int, open: String, close: String) -> Int? {
            var depth = 1
            var i = from
            while i < str.length {
                let c = str.substring(with: NSRange(location: i, length: 1))
                if c == open {
                    depth += 1
                } else if c == close {
                    depth -= 1
                    if depth == 0 { return i }
                }
                i += 1
            }
            return nil
        }

        private func findBackward(_ str: NSString, from: Int, open: String, close: String) -> Int? {
            var depth = 1
            var i = from - 1
            while i >= 0 {
                let c = str.substring(with: NSRange(location: i, length: 1))
                if c == close {
                    depth += 1
                } else if c == open {
                    depth -= 1
                    if depth == 0 { return i }
                }
                i -= 1
            }
            return nil
        }
    }
}

// MARK: - Line number ruler

final class LineNumberRuler: NSRulerView {
    weak var tv: NSTextView?
    var tokens: Caprine

    init(textView: NSTextView, tokens: Caprine) {
        self.tokens = tokens
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        self.tv = textView
        self.clientView = textView
        self.ruleThickness = 40
        self.clipsToBounds = true
    }

    @available(*, unavailable, message: "Use init(textView:tokens:) to configure the ruler.")
    required init(coder: NSCoder) {
        fatalError("LineNumberRuler requires a text view and theme tokens.")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv, let lm = tv.layoutManager, let container = tv.textContainer else { return }
        let str = tv.string as NSString
        let inset = tv.textContainerInset.height
        let visible = tv.visibleRect
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor(tokens.muted),
        ]

        var line = 1
        str.enumerateSubstrings(
            in: NSRange(location: 0, length: str.length),
            options: [.byLines, .substringNotRequired]
        ) { _, lineRange, _, _ in
            let glyphRange = lm.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let r = lm.boundingRect(forGlyphRange: glyphRange, in: container)
            let y = r.minY + inset - visible.minY
            if y > -14, y < self.bounds.height + 14 {
                let s = "\(line)" as NSString
                let size = s.size(withAttributes: attrs)
                s.draw(at: NSPoint(x: self.ruleThickness - size.width - 5, y: y), withAttributes: attrs)
            }
            line += 1
        }
    }
}
