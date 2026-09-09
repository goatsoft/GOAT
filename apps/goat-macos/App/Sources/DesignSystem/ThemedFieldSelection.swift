import AppKit
import SwiftUI

/// AppKit shares a field editor within each window. Restyle it when editing starts so
/// search, Pen names, and other native text fields use the same caret and selection.
struct ThemedFieldSelection: NSViewRepresentable {
    let tint: Color
    let ink: Color

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.beganEditing(_:)),
            name: NSControl.textDidBeginEditingNotification, object: nil)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.tint = NSColor(tint)
        context.coordinator.ink = NSColor(ink)
        if let editor = nsView.window?.firstResponder as? NSTextView, editor.isFieldEditor {
            context.coordinator.apply(to: editor)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var view: NSView?
        var tint = NSColor.controlAccentColor
        var ink = NSColor.labelColor

        @objc func beganEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                let window = view?.window, field.window === window,
                let editor = field.currentEditor() as? NSTextView
            else { return }
            apply(to: editor)
        }

        func apply(to editor: NSTextView) {
            editor.insertionPointColor = tint
            editor.selectedTextAttributes = [
                .backgroundColor: tint.withAlphaComponent(0.32),
                .foregroundColor: ink,
            ]
        }
    }
}
