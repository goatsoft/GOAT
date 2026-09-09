import AppKit
import SwiftUI

/// A one-shot inline rename field for a sidebar row: appears already focused with its whole
/// text selected, commits on Return or focus loss, and cancels on Escape. Backed by AppKit
/// so the select-all-on-appear is reliable (SwiftUI's TextField won't do it on its own).
struct InlineRenameField: NSViewRepresentable {
    @Environment(AppModel.self) private var model
    @Binding var text: String
    var font: NSFont = .systemFont(ofSize: 13)
    var onCommit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = NSColor(model.theme.tokens.ink)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        // Focus and select-all on the next runloop tick, once the field is in a window.
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            if let editor = field.currentEditor() as? NSTextView {
                editor.insertionPointColor = NSColor(model.theme.tokens.tint)
                editor.selectedTextAttributes = [
                    .backgroundColor: NSColor(model.theme.tokens.tint).withAlphaComponent(0.25),
                    .foregroundColor: NSColor(model.theme.tokens.ink),
                ]
                editor.selectAll(nil)
            }
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        nsView.textColor = NSColor(model.theme.tokens.ink)
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineRenameField
        private var finished = false

        init(_ parent: InlineRenameField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                finish(parent.onCommit)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                finish(parent.onCancel)
                return true
            default:
                return false
            }
        }

        // Fires on Return and on focus loss - commit whatever's there.
        func controlTextDidEndEditing(_ obj: Notification) {
            finish(parent.onCommit)
        }

        private func finish(_ action: () -> Void) {
            guard !finished else { return }
            finished = true
            action()
        }
    }
}
