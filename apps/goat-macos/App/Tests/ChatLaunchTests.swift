import Bleet
import Foundation
import Testing

@testable import GOAT

@Test @MainActor func openingChatAcceptsFirstMessageBeforeSelectionCanBlockSending() async {
    var capabilityCheckRunning = false
    var acceptedText: String?
    var navigated = false
    let sent = await ChatLaunch.submit(
        text: "  First message  ", attachments: [],
        persist: { true },
        accept: { text, _ in
            guard !capabilityCheckRunning else { return false }
            acceptedText = text
            return true
        },
        navigate: {
            capabilityCheckRunning = true
            navigated = true
        },
        discard: { Issue.record("An accepted chat must not be discarded") })
    #expect(sent)
    #expect(navigated)
    #expect(acceptedText == "First message")
}

@Test @MainActor func openingChatDoesNotNavigateIfEngineBecomesUnavailableDuringSave() async {
    var engineReady = true
    var savedChatExists = false
    let sent = await ChatLaunch.submit(
        text: "Keep my draft", attachments: [],
        persist: {
            await Task.yield()
            savedChatExists = true
            engineReady = false
            return true
        },
        accept: { _, _ in engineReady },
        navigate: { Issue.record("A rejected send must keep the composer visible") },
        discard: { savedChatExists = false })
    #expect(!sent)
    #expect(!savedChatExists)
}

@Test @MainActor func openingChatNeverSendsOrNavigatesAfterPersistenceFailure() async {
    let sent = await ChatLaunch.submit(
        text: "Keep my draft", attachments: [],
        persist: { false },
        accept: { _, _ in
            Issue.record("Sending requires a saved chat")
            return true
        },
        navigate: { Issue.record("A failed save must keep the composer visible") },
        discard: { Issue.record("There is no saved chat to discard") })
    #expect(!sent)
}

@Test @MainActor func openingChatAcceptsAnImageWithoutTypedText() async {
    let image = Data([1, 2, 3])
    var acceptedImages: [Data] = []
    let sent = await ChatLaunch.submit(
        text: " \n ", attachments: [image],
        persist: { true },
        accept: { text, attachments in
            #expect(text.isEmpty)
            acceptedImages = attachments
            return true
        },
        navigate: {}, discard: { Issue.record("An image-only message is valid") })
    #expect(sent)
    #expect(acceptedImages == [image])
}

@Test @MainActor func emptyOpeningComposerDoesNotCreateAChat() async {
    let sent = await ChatLaunch.submit(
        text: " \n ", attachments: [],
        persist: {
            Issue.record("An empty submission must not create a chat")
            return true
        },
        accept: { _, _ in
            Issue.record("An empty submission must not send")
            return true
        },
        navigate: { Issue.record("An empty submission must not navigate") },
        discard: { Issue.record("There is no saved chat to discard") })
    #expect(!sent)
}

@Test @MainActor func penNewChatNavigatesAndFocusesWithoutCreatingAnEmptyChat() {
    let model = AppModel.shared
    let originalPens = model.pens
    let originalChats = model.chats
    let originalChatID = model.selectedChatID
    let originalPenID = model.selectedPenID
    let originalFocusID = model.penComposerFocusID
    let originalHome = model.showingPensHome
    let originalArtifact = model.paddockArtifact
    defer {
        model.pens = originalPens
        model.chats = originalChats
        model.selectedChatID = originalChatID
        model.selectedPenID = originalPenID
        model.penComposerFocusID = originalFocusID
        model.showingPensHome = originalHome
        model.paddockArtifact = originalArtifact
    }
    let pen = Pen(name: "Target", emoji: "🐐", instructions: "")
    let other = Pen(name: "Other", emoji: "🐐", instructions: "")
    let existing = ChatSession(effort: .trot, modelID: "test-model", projectID: other.id)
    existing.messagesLoaded = true
    model.pens = [pen, other]
    model.chats = [existing]
    model.selectedChatID = existing.id
    model.beginNewChat(in: pen)
    #expect(model.selectedPenID == pen.id)
    #expect(model.penComposerFocusID == pen.id)
    #expect(!model.showingPensHome)
    #expect(model.chats.map(\.id) == [existing.id])

    // Repeated clicks, including from the overview, must keep using the draft composer.
    model.penComposerFocusID = nil
    model.openPensHome()
    model.beginNewChat(in: pen)
    #expect(model.selectedPenID == pen.id)
    #expect(model.penComposerFocusID == pen.id)
    #expect(!model.showingPensHome)
    #expect(model.chats.map(\.id) == [existing.id])

    let removedPen = Pen(name: "Removed", emoji: "🐐", instructions: "")
    model.beginNewChat(in: removedPen)
    #expect(model.selectedPenID == pen.id)
    #expect(model.chats.map(\.id) == [existing.id])
}

@Test @MainActor func penLaunchPreservesComposerSettingsAndRejectsAnExistingOrForeignChat() throws {
    let pen = UUID()
    let draft = ChatSession(effort: .trot, modelID: "chosen-model", projectID: pen)
    draft.toolsEnabled = false
    draft.disabledMCPServers = ["external-files"]
    let submitted = try #require(ChatLaunch.sessionForSubmission(draft, penID: pen, existingChatIDs: []))
    #expect(submitted === draft)
    #expect(submitted.messagesLoaded)
    #expect(submitted.modelID == "chosen-model" && submitted.effort == .trot)
    #expect(!submitted.toolsEnabled && submitted.disabledMCPServers == ["external-files"])
    #expect(ChatLaunch.sessionForSubmission(draft, penID: UUID(), existingChatIDs: []) == nil)
    #expect(ChatLaunch.sessionForSubmission(draft, penID: pen, existingChatIDs: [draft.id]) == nil)
    let next = ChatLaunch.nextDraft(after: submitted)
    #expect(next.id != submitted.id && next.projectID == pen)
    #expect(next.modelID == submitted.modelID && next.effort == submitted.effort)
    #expect(!next.toolsEnabled && next.disabledMCPServers == submitted.disabledMCPServers)
    #expect(next.messages.isEmpty)
    draft.messages.append(ChatMessage(role: .user))
    #expect(ChatLaunch.sessionForSubmission(draft, penID: pen, existingChatIDs: []) == nil)
}
