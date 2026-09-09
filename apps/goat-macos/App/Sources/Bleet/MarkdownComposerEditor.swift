import AppKit
import SwiftUI

enum MarkdownComposerLayout {
    static func clampedHeight(for contentHeight: CGFloat, fontSize: CGFloat) -> CGFloat {
        let lineHeight = max(18, fontSize * 1.35)
        return min(lineHeight * 8 + 12, max(lineHeight + 12, contentHeight))
    }
}

enum MarkdownComposerSyntax {
    static let maximumHighlightedCharacters = 512 * 1_024

    static func fencedRanges(in value: String) -> [NSRange] {
        let source = value as NSString
        var ranges: [NSRange] = []
        var activeFence: (character: Character, length: Int, location: Int)?
        var location = 0

        while location < source.length {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let line = source.substring(with: lineRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let fence = activeFence {
                if isFenceLine(line, character: fence.character, minimumLength: fence.length) {
                    ranges.append(
                        NSRange(
                            location: fence.location,
                            length: NSMaxRange(lineRange) - fence.location))
                    activeFence = nil
                }
            } else if let opening = openingFence(in: line) {
                activeFence = (opening.character, opening.length, lineRange.location)
            }
            location = NSMaxRange(lineRange)
        }
        if let activeFence {
            ranges.append(
                NSRange(location: activeFence.location, length: source.length - activeFence.location))
        }
        return ranges
    }

    private static func openingFence(in line: String) -> (character: Character, length: Int)? {
        guard let character = line.first, character == "`" || character == "~" else { return nil }
        let length = line.prefix { $0 == character }.count
        return length >= 3 ? (character, length) : nil
    }

    private static func isFenceLine(
        _ line: String, character: Character, minimumLength: Int
    ) -> Bool {
        let length = line.prefix { $0 == character }.count
        guard length >= minimumLength else { return false }
        let suffixStart = line.index(line.startIndex, offsetBy: length)
        return line[suffixStart...].trimmingCharacters(in: .whitespaces).isEmpty
    }
}

struct MarkdownComposerEditor: NSViewRepresentable {
    var fontID = "system"
    var codeFontID = "monospaced"
    var codeFontSize: Double = 13
    private var textFont: NSFont { ReadingFonts.nsFont(fontID, size: fontSize, role: .chat) }
    private var codeFont: NSFont { ReadingFonts.nsFont(codeFontID, size: codeFontSize, role: .code) }
    @Binding var text: String
    @Binding var height: CGFloat
    var focused: Binding<Bool>
    let isEditable: Bool
    let fontSize: CGFloat
    let tint: Color
    let onSubmit: () -> Void
    let onMoveSelection: (Int) -> Bool
    let onCancel: () -> Bool
    var onPasteFiles: (([URL]) -> Void)? = nil
    var onPasteImage: ((Data) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ComposerScrollView()
        scrollView.widthChanged = { [weak coordinator = context.coordinator] in
            coordinator?.updateHeight()
        }
        let textView = ComposerTextView(frame: .zero)
        textView.focusChanged = { [weak coordinator = context.coordinator] focused in
            coordinator?.parent.focused.wrappedValue = focused
        }
        textView.pasteAttachments = { [weak coordinator = context.coordinator] pasteboard in
            guard let coordinator, coordinator.parent.isEditable else { return false }
            let urls = ComposerPasteboard.fileURLs(from: pasteboard)
            if !urls.isEmpty, let receive = coordinator.parent.onPasteFiles {
                receive(urls)
                return true
            }
            if let receive = coordinator.parent.onPasteImage,
                let image = ComposerPasteboard.imageData(from: pasteboard)
            {
                receive(image)
                return true
            }
            return false
        }
        textView.canPasteAttachments = { [weak coordinator = context.coordinator] in
            guard let parent = coordinator?.parent, parent.isEditable else { return false }
            return
                (parent.onPasteFiles != nil
                && NSPasteboard.general.canReadObject(
                    forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]))
                || (parent.onPasteImage != nil && ComposerPasteboard.hasImage(NSPasteboard.general))
        }
        scrollView.documentView = textView
        configure(textView, coordinator: context.coordinator)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        context.coordinator.textView = textView
        context.coordinator.highlight()
        context.coordinator.updateHeight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let fontsChanged =
            context.coordinator.appliedTextFont != textFont || context.coordinator.appliedCodeFont != codeFont
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.isEditable != isEditable { textView.isEditable = isEditable }
        let color = NSColor(tint)
        let tintChanged = context.coordinator.appliedTint != color
        if tintChanged {
            textView.insertionPointColor = color
            textView.selectedTextAttributes = [
                .backgroundColor: color.withAlphaComponent(0.25),
                .foregroundColor: NSColor.labelColor,
            ]
        }
        if textView.string != text {
            textView.string = text
            context.coordinator.highlight()
            context.coordinator.updateHeight()
        } else if fontsChanged || tintChanged {
            context.coordinator.highlight()
            if fontsChanged { context.coordinator.updateHeight() }
        }
        context.coordinator.requestFocus()
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.highlightTask?.cancel()
        coordinator.heightTask?.cancel()
    }

    private func configure(_ textView: NSTextView, coordinator: Coordinator) {
        textView.string = text
        textView.delegate = coordinator
        textView.isRichText = false
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.registerForDraggedTypes([.fileURL, .png, .tiff])
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = textFont
        textView.textColor = .labelColor
        textView.insertionPointColor = NSColor(tint)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(tint).withAlphaComponent(0.25),
            .foregroundColor: NSColor.labelColor,
        ]
        textView.textContainerInset = NSSize(width: 5, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude)
    }

    final class ComposerTextView: NSTextView {
        var focusChanged: ((Bool) -> Void)?
        var pasteAttachments: ((NSPasteboard) -> Bool)?
        var canPasteAttachments: (() -> Bool)?
        private(set) var commandModifiers: NSEvent.ModifierFlags = []

        override func keyDown(with event: NSEvent) {
            let previous = commandModifiers
            commandModifiers = event.modifierFlags
            defer { commandModifiers = previous }
            super.keyDown(with: event)
        }

        override func paste(_ sender: Any?) {
            guard isEditable else { return }
            if pasteAttachments?(NSPasteboard.general) == true { return }
            super.paste(sender)
        }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            if acceptsAttachmentDrop(sender) { return .copy }
            return super.draggingEntered(sender)
        }

        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            if acceptsAttachmentDrop(sender) { return .copy }
            return super.draggingUpdated(sender)
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            if isEditable, pasteAttachments?(sender.draggingPasteboard) == true { return true }
            return super.performDragOperation(sender)
        }

        private func acceptsAttachmentDrop(_ sender: any NSDraggingInfo) -> Bool {
            guard isEditable, pasteAttachments != nil else { return false }
            return sender.draggingPasteboard.canReadObject(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
                || ComposerPasteboard.hasImage(sender.draggingPasteboard)
        }

        override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
            if item.action == #selector(paste(_:)), canPasteAttachments?() == true { return true }
            return super.validateUserInterfaceItem(item)
        }

        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { focusChanged?(true) }
            return accepted
        }

        override func resignFirstResponder() -> Bool {
            let accepted = super.resignFirstResponder()
            if accepted { focusChanged?(false) }
            return accepted
        }
    }

    final class ComposerScrollView: NSScrollView {
        var widthChanged: (() -> Void)?

        override func setFrameSize(_ newSize: NSSize) {
            let changed = abs(newSize.width - frame.width) > 0.5
            super.setFrameSize(newSize)
            if changed { widthChanged?() }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private var focusScheduled = false

        /// SwiftUI may update the editor before it is attached to a window.
        /// Defer once, then consult the latest binding so a user focus change wins.
        func requestFocus() {
            guard parent.focused.wrappedValue, !focusScheduled else { return }
            focusScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.focusScheduled = false
                guard self.parent.focused.wrappedValue, let textView = self.textView,
                    let window = textView.window, window.firstResponder !== textView
                else { return }
                window.makeFirstResponder(textView)
            }
        }

        var parent: MarkdownComposerEditor
        weak var textView: NSTextView?
        var highlightTask: Task<Void, Never>?
        var heightTask: Task<Void, Never>?

        private static let heading = try? NSRegularExpression(pattern: #"(?m)^[ \t]{0,3}#{1,6}[ \t]+.*$"#)
        private static let marker = try? NSRegularExpression(
            pattern: #"(?m)^[ \t]{0,3}(?:#{1,6}|>|[-+*]|\d+\.)[ \t]+"#)
        private static let strong = try? NSRegularExpression(pattern: #"(?:\*\*|__)(?=\S).+?(?<=\S)(?:\*\*|__)"#)
        private static let inlineCode = try? NSRegularExpression(pattern: #"`[^`\n]+`"#)
        private static let link = try? NSRegularExpression(pattern: #"\[[^\]\n]+\]\([^\)\n]+\)"#)
        private static let fenceMarker = try? NSRegularExpression(pattern: #"(?m)^[ \t]*(?:`{3,}|~{3,}).*$"#)

        init(_ parent: MarkdownComposerEditor) {
            self.parent = parent
        }

        nonisolated func textDidChange(_ notification: Notification) {
            MainActor.assumeIsolated {
                guard let textView else { return }
                parent.text = textView.string
                scheduleHighlight()
                updateHeight()
            }
        }

        nonisolated func textView(
            _ textView: NSTextView, doCommandBy commandSelector: Selector
        ) -> Bool {
            MainActor.assumeIsolated {
                switch commandSelector {
                case #selector(NSResponder.insertNewline(_:)):
                    if (textView as? ComposerTextView)?.commandModifiers.contains(.shift) == true { return false }
                    parent.onSubmit()
                    return true
                case #selector(NSResponder.moveDown(_:)):
                    return parent.onMoveSelection(1)
                case #selector(NSResponder.moveUp(_:)):
                    return parent.onMoveSelection(-1)
                case #selector(NSResponder.cancelOperation(_:)):
                    return parent.onCancel()
                default:
                    return false
                }
            }
        }

        func scheduleHighlight() {
            highlightTask?.cancel()
            highlightTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(45))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.highlight()
                self?.highlightTask = nil
            }
        }

        func updateHeight() {
            // Coalesce text and width changes; unrelated SwiftUI updates need no measurement.
            guard heightTask == nil else { return }
            heightTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                defer { heightTask = nil }
                guard !Task.isCancelled, let textView,
                    let layoutManager = textView.layoutManager,
                    let textContainer = textView.textContainer
                else { return }
                layoutManager.ensureLayout(for: textContainer)
                let usedHeight =
                    layoutManager.usedRect(for: textContainer).height
                    + textView.textContainerInset.height * 2
                let nextHeight = MarkdownComposerLayout.clampedHeight(
                    for: ceil(usedHeight), fontSize: parent.fontSize)
                if abs(nextHeight - parent.height) > 0.5 {
                    parent.height = nextHeight
                }
            }
        }

        var appliedTextFont: NSFont?
        var appliedCodeFont: NSFont?
        var appliedTint: NSColor?

        func highlight() {
            guard let textView, !textView.hasMarkedText(), let storage = textView.textStorage else { return }
            let source = textView.string as NSString
            let fullRange = NSRange(location: 0, length: source.length)
            let baseFont = parent.textFont
            appliedTextFont = baseFont
            appliedCodeFont = parent.codeFont
            textView.font = baseFont
            let accent = NSColor(parent.tint)
            appliedTint = accent
            storage.beginEditing()
            storage.setAttributes(
                [.font: baseFont, .foregroundColor: NSColor.labelColor],
                range: fullRange)
            textView.typingAttributes = [.font: baseFont, .foregroundColor: NSColor.labelColor]
            if source.length <= MarkdownComposerSyntax.maximumHighlightedCharacters {
                add(
                    Self.heading,
                    attributes: [.font: NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)], to: storage
                )
                add(Self.marker, attributes: [.foregroundColor: accent], to: storage)
                add(
                    Self.strong,
                    attributes: [.font: NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)], to: storage
                )
                add(
                    Self.inlineCode,
                    attributes: [
                        .font: parent.codeFont,
                        .backgroundColor: NSColor.quaternaryLabelColor,
                    ],
                    to: storage)
                add(Self.link, attributes: [.foregroundColor: NSColor.linkColor], to: storage)
                for range in MarkdownComposerSyntax.fencedRanges(in: textView.string) {
                    storage.addAttributes(
                        [
                            .font: parent.codeFont,
                            .backgroundColor: NSColor.quaternaryLabelColor,
                        ],
                        range: range)
                }
                add(Self.fenceMarker, attributes: [.foregroundColor: accent], to: storage)
            }
            storage.endEditing()
        }

        private func add(
            _ expression: NSRegularExpression?, attributes: [NSAttributedString.Key: Any],
            to storage: NSTextStorage
        ) {
            guard let expression else { return }
            let range = NSRange(location: 0, length: storage.length)
            expression.enumerateMatches(in: storage.string, range: range) { match, _, _ in
                guard let match else { return }
                storage.addAttributes(attributes, range: match.range)
            }
        }
    }
}

/// Finder copies carry file URLs; screenshot/image copies carry raster data. Plain text stays text.
@MainActor
enum ComposerPasteboard {
    static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, .init("public.jpeg")]

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter(\.isFileURL)
    }

    static func hasImage(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: imageTypes) != nil
    }

    static func imageData(from pasteboard: NSPasteboard) -> Data? {
        guard let type = pasteboard.availableType(from: imageTypes) else { return nil }
        return pasteboard.data(forType: type)
    }
}
