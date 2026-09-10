import AppKit
import Bleet
import Observation
import SwiftUI
import Testing

@testable import GOAT

@MainActor @Observable private final class ComposerFixtureState {
    var draft = ""
    var focused = false
    var pending: [PendingAttachment] = []
    var submissions = 0
    var canLead = false
    var submittingLead = false
}

@MainActor private struct ComposerFixture: View {
    @Bindable var state: ComposerFixtureState
    let session: ChatSession

    var body: some View {
        Composer(
            session: session, draft: $state.draft, pending: $state.pending,
            focused: $state.focused, canSend: false, isStreaming: true,
            attachmentsLoading: false, onSend: { state.submissions += 1 },
            onStop: {}, onAttach: { _ in }, onImportFiles: { _ in },
            canLead: state.canLead, submittingLead: state.submittingLead)
    }
}

@Test @MainActor func composerAcceptsDraftAndUndoWhileGenerationOwnsSend() async throws {
    let state = ComposerFixtureState()
    let session = ChatSession(effort: .trot, modelID: nil)
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 600, height: 300),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: ComposerFixture(state: state, session: session).environment(AppModel.shared))
    window.contentView = host
    defer {
        window.contentView = nil
        window.close()
    }
    try await Task.sleep(for: .milliseconds(300))
    let editor = try #require(findComposerEditor(host))
    #expect(editor.isEditable)
    window.makeFirstResponder(editor)
    let shiftReturn = try #require(
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    editor.keyDown(with: shiftReturn)
    #expect(state.draft == "\n")
    #expect(state.submissions == 0)
    #expect(editor.commandModifiers.isEmpty)
    editor.undoManager?.undo()
    #expect(state.draft.isEmpty)
    for character in "Next request stays editable" {
        editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        await Task.yield()
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(state.draft == "Next request stays editable")
    #expect(editor.string == state.draft)
    editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    #expect(state.submissions == 0)
    #expect(state.draft == "Next request stays editable")
    editor.undoManager?.undo()
    #expect(editor.string != "Next request stays editable")
    #expect(state.draft == editor.string)

    state.draft = String(repeating: "A line that wraps when the window becomes narrow. ", count: 12)
    try await Task.sleep(for: .milliseconds(100))
    window.setContentSize(NSSize(width: 380, height: 300))
    try await Task.sleep(for: .milliseconds(100))
    #expect(editor.string == state.draft)
    #expect(editor.enclosingScrollView?.contentSize.width ?? 0 > 0)
}

@MainActor private func findComposerEditor(_ view: NSView) -> MarkdownComposerEditor.ComposerTextView? {
    if let editor = view as? MarkdownComposerEditor.ComposerTextView { return editor }
    return view.subviews.lazy.compactMap(findComposerEditor).first
}

@MainActor private final class LayoutCountingHost<Content: View>: NSHostingView<Content> {
    var layoutCount = 0
    override func layout() {
        layoutCount += 1
        super.layout()
    }
}

/// A dispatch timer distinguishes main-queue service from a sleeping Swift task's resumption.
@MainActor private final class MainQueueResponsivenessProbe {
    private let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
    private(set) var worstDelay: Duration = .zero
    private var measuring = true

    init() {
        let clock = ContinuousClock()
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { @Sendable [weak self] in
            let queued = clock.now
            DispatchQueue.main.async { [weak self] in
                guard let self, self.measuring else { return }
                self.worstDelay = max(self.worstDelay, queued.duration(to: clock.now))
            }
        }
        timer.resume()
    }

    func stop() {
        measuring = false
        timer.cancel()
    }
}

@Test @MainActor func readySendButtonDoesNotContinuouslyRelayoutTheWindow() async throws {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 200, height: 100),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let model = AppModel.shared
    let host = LayoutCountingHost(
        rootView: SendButton(
            enabled: true, gradient: model.theme.tokens.bubbleGradient,
            glow: model.theme.tokens.tint, animates: true, action: {}
        )
        .environment(model))
    window.contentView = host
    window.orderFront(nil)
    defer {
        window.contentView = nil
        window.close()
    }
    try await Task.sleep(for: .milliseconds(300))
    let initial = host.layoutCount
    try await Task.sleep(for: .milliseconds(600))
    #expect(host.layoutCount - initial <= 2, "An idle send button must not drive a display-rate layout loop")
}

@Test @MainActor func codeHeavyListsLeaveTheVisibleChatEventLoopResponsive() async throws {
    let clock = ContinuousClock()
    let setupStart = clock.now
    let session = ChatSession(effort: .trot, modelID: nil)
    session.messagesLoaded = true
    let response = (1...12).map { step in
        """
        \(step). **Create project file \(step)**:
           - Preserve the existing project configuration and verify this change.
           - Create `example-\(step).ts`:
             ```typescript
             export const example\(step) = "A long code line that remains horizontally scrollable inside a nested list";
             console.log(example\(step));
             ```

        """
    }.joined(separator: "\n")
    session.messages = (0..<4).map { index in
        let message = ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant)
        message.text = index.isMultiple(of: 2) ? "Create the project files." : response
        message.complete = true
        return message
    }
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 1_000, height: 700),
        styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    let controller = NSHostingController(rootView: ChatView(session: session).environment(AppModel.shared))
    // This AppKit-owned fixture tests chat layout. Window toolbars belong to the app's SwiftUI scene.
    controller.sceneBridgingOptions = [.title]
    let host = controller.view
    window.contentViewController = controller
    window.orderFront(nil)
    defer {
        window.contentViewController = nil
        window.close()
    }
    try await Task.sleep(for: .seconds(1))
    let editor = try #require(findComposerEditor(host))
    window.makeFirstResponder(editor)
    let setupDuration = setupStart.duration(to: clock.now)
    var worstPause: Duration = .zero
    var worstInsertion: Duration = .zero
    var worstResume: Duration = .zero
    var slowestCharacter = 0
    let mainQueueProbe = MainQueueResponsivenessProbe()
    defer { mainQueueProbe.stop() }
    for (index, character) in "A responsive draft alongside rich code lists".enumerated() {
        let start = clock.now
        editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        let inserted = clock.now
        try await Task.sleep(for: .milliseconds(20))
        let resumed = clock.now
        let pause = start.duration(to: resumed)
        if pause > worstPause {
            worstPause = pause
            slowestCharacter = index
        }
        worstInsertion = max(worstInsertion, start.duration(to: inserted))
        worstResume = max(worstResume, inserted.duration(to: resumed))
    }
    print(
        "Chat responsiveness: setup=\(setupDuration), insertion=\(worstInsertion), "
            + "resume=\(worstResume), total=\(worstPause), character=\(slowestCharacter), "
            + "mainQueue=\(mainQueueProbe.worstDelay)")
    #expect(editor.string == "A responsive draft alongside rich code lists")
    #expect(worstPause < .milliseconds(250), "Visible chat event-loop delay: \(worstPause)")
    window.setContentSize(NSSize(width: 720, height: 700))
    try await Task.sleep(for: .milliseconds(300))
    #expect(editor.string == "A responsive draft alongside rich code lists")
}

@Test @MainActor func composerReturnLeadsOnlyTheOwningChatAndDoesNotDoubleSubmit() async throws {
    let state = ComposerFixtureState()
    state.canLead = true
    state.draft = "Use Vue instead"
    let session = ChatSession(effort: .trot, modelID: nil)
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 600, height: 300),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: ComposerFixture(state: state, session: session).environment(AppModel.shared))
    window.contentView = host
    defer {
        window.contentView = nil
        window.close()
    }
    try await Task.sleep(for: .milliseconds(300))
    let editor = try #require(findComposerEditor(host))
    editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    #expect(state.submissions == 1)
    state.submittingLead = true
    try await Task.sleep(for: .milliseconds(100))
    editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    #expect(state.submissions == 1)
    state.submittingLead = false
    state.canLead = false
    try await Task.sleep(for: .milliseconds(100))
    editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    #expect(state.submissions == 1)
}
