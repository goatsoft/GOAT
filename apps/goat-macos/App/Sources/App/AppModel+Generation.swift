import Bleet
import Foundation
import GOATed
import Herd
import Inference
import Pens
import Shepherd

extension AppModel {
    // MARK: Generation (delegates to the Shepherd)

    @discardableResult
    func send(
        _ text: String, attachments: [Data] = [], documents: [TextAttachment] = [],
        in targetSession: ChatSession? = nil
    ) -> UUID? {
        guard startupPhase.hasLocalState,
            let session = targetSession ?? currentSession, session.messagesLoaded, activeTurnSessionID == nil,
            !engineTransitioning, !modelCapabilitiesLoading, health.isOK,
            canGenerateWithSelectedModel(for: session)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty || !documents.isEmpty else { return nil }
        guard let turnID = shepherd.reserve(in: session) else { return nil }
        let user = ChatMessage(role: .user)
        user.text = trimmed.isEmpty ? (documents.isEmpty ? "What do you see?" : "Review the attached files.") : trimmed
        user.complete = true
        session.messages.append(user)
        Task {
            // Attachment writes happen off the main actor; generation waits for the paths.
            let attachmentPaths = await Task.detached {
                attachments.compactMap { AttachmentStore.save($0) }
                    + documents.compactMap { document in
                        document.encoded.flatMap { AttachmentStore.save($0, ext: TextAttachment.storedExtension) }
                    }
            }.value
            guard chats.contains(where: { $0.id == session.id }) else {
                await Task.detached { AttachmentStore.delete(attachmentPaths) }.value
                shepherd.stop(sessionID: session.id, turnID: turnID)
                return
            }
            guard shepherd.activeTurnID == turnID, shepherd.activeSessionID == session.id else {
                await Task.detached { AttachmentStore.delete(attachmentPaths) }.value
                // Stop during preparation keeps the submitted text, but attachments which never
                // reached an admitted inference request are discarded rather than orphaned.
                if await persist(user, in: session) {
                    sessionTouched(session)
                } else {
                    session.messages.removeAll { $0.id == user.id }
                }
                return
            }
            guard attachmentPaths.count == attachments.count + documents.count else {
                await Task.detached { AttachmentStore.delete(attachmentPaths) }.value
                user.error =
                    "Attachments could not be saved. Add the files again and retry. Nothing was sent to the engine."
                _ = await persist(user, in: session)
                shepherd.stop(sessionID: session.id, turnID: turnID)
                return
            }
            user.attachmentPaths = attachmentPaths
            guard await persist(user, in: session) else {
                await Task.detached { AttachmentStore.delete(attachmentPaths) }.value
                session.messages.removeAll { $0.id == user.id }
                shepherd.stop(sessionID: session.id, turnID: turnID)
                return
            }
            sessionTouched(session)
            shepherd.startReserved(in: session, turnID: turnID)
        }
        return turnID
    }

    func stop() {
        if let turn = shepherd.activeTurnID { controlTurns[turn]?.cancelled = true }
        shepherd.stop()
    }

    func stop(sessionID: UUID) {
        if shepherd.activeSessionID == sessionID, let turn = shepherd.activeTurnID {
            controlTurns[turn]?.cancelled = true
        }
        shepherd.stop(sessionID: sessionID)
    }

    func regenerate() async {
        guard startupPhase.hasLocalState,
            let session = currentSession, let databaseWriter,
            session.messagesLoaded, activeTurnSessionID == nil,
            !engineTransitioning, !modelCapabilitiesLoading, health.isOK,
            canGenerateWithSelectedModel(for: session)
        else { return }

        let assistant = session.messages.last.flatMap { message in
            message.role == .assistant ? message : nil
        }
        let precedingRole = assistant == nil ? session.messages.last?.role : session.messages.dropLast().last?.role
        guard precedingRole == .user, let turnID = shepherd.reserve(in: session) else { return }

        if let assistant {
            do {
                try await databaseWriter.deleteMessage(id: assistant.id.uuidString)
            } catch {
                shepherd.stop(sessionID: session.id, turnID: turnID)
                dbWarning = "Message was not deleted: \(error.localizedDescription)"
                return
            }
            session.messages.removeAll { $0.id == assistant.id }
        }
        guard shepherd.activeTurnID == turnID, shepherd.activeSessionID == session.id else { return }
        shepherd.startReserved(in: session, turnID: turnID)
    }
}

// MARK: - The Shepherd's view of the app

extension AppModel: ShepherdEnvironment {
    /// The catalog with per-model context-window overrides applied (ADR-0085). An override
    /// fills a missing window or lowers a reported one; capabilities are untouched.
    var availableModels: [ModelRef] {
        guard let profile = activeEngineProfile else { return models }
        return models.map { model in
            let identity = ModelIdentity(engineProfileID: profile.id, modelID: model.id)
            guard let preference = modelPreferences.first(where: { $0.identity == identity }),
                preference.contextWindowOverride != nil
            else { return model }
            return ModelRef(
                id: model.id,
                contextLength: preference.effectiveContextLength(reported: model.contextLength),
                capabilities: model.capabilities)
        }
    }
    var fallbackModelID: String? { defaultModelID }

    func generationContext(for modelID: String) -> GenerationContext? {
        guard let profile = activeEngineProfile,
            let model = models.first(where: { $0.id == modelID })
        else { return nil }
        let identity = ModelIdentity(engineProfileID: profile.id, modelID: modelID)
        let override =
            modelPreferences.first(where: { $0.identity == identity })?.compatibilityOverride
            ?? .automatic
        let compatibility = ModelCompatibilityResolver.resolve(
            identity: identity, override: override,
            familyProfile: ModelFamilyRegistry.profile(for: modelID), now: .now)
        return GenerationContext(
            engineProfileID: profile.id,
            engineName: profile.name,
            engineConfigurationRevision: engineIntentRevision,
            identity: identity,
            compatibility: compatibility)
    }

    func canGenerateWithSelectedModel(for session: ChatSession? = nil) -> Bool {
        guard let modelID = session?.modelID ?? defaultModelID else { return false }
        return generationContext(for: modelID) != nil
    }

    func projectContext(forProject id: UUID) async -> ShepherdProjectContext? {
        // The Pen's app-managed brief and agent guide are distinct from workspace files.
        // Always supply both: the guide may refer to the brief, but must not replace it.
        guard let pen = pens.first(where: { $0.id == id }) else { return nil }
        let penID = pen.id.uuidString
        let name = pen.name
        let fallback = pen.instructions
        let workspacePath = pen.workspace?.path
        let guidance = await Task.detached(priority: .userInitiated) {
            (
                brief: (try? PenStore.instructions(id: penID)) ?? fallback,
                agents: (try? PenStore.agents(id: penID)) ?? ""
            )
        }.value
        return ShepherdProjectContext(
            name: name, instructions: guidance.brief,
            workspacePath: workspacePath, agentInstructions: guidance.agents)
    }

    @discardableResult
    func persist(_ message: ChatMessage, in session: ChatSession) async -> Bool {
        guard chats.contains(where: { $0.id == session.id }), let databaseWriter else { return false }
        let position = session.messages.firstIndex(where: { $0.id == message.id }) ?? session.messages.count
        let record = record(for: message, in: session, position: position)
        do {
            try await databaseWriter.saveMessage(record)
            return true
        } catch {
            dbWarning = "Message was not saved: \(error.localizedDescription)"
            return false
        }
    }

    func checkpoint(messageID: String, text: String, thinking: String) async {
        do {
            try await databaseWriter?.checkpointMessage(
                id: messageID, text: text, thinking: thinking)
        } catch {
            dbWarning = "Message checkpoint failed: \(error.localizedDescription)"
        }
    }

    func sessionTouched(_ session: ChatSession) {
        guard chats.contains(where: { $0.id == session.id }) else { return }
        session.updatedAt = .now
        persistMeta(session)
        resort()
    }

    func sessionMetaChanged(_ session: ChatSession) {
        guard chats.contains(where: { $0.id == session.id }) else { return }
        persistMeta(session)
    }

    func turnOwnershipChanged(activeSessionID: UUID?) {
        if activeSessionID == nil {
            for (turn, record) in controlTurns where record.finalSnapshot == nil {
                if let chat = chats.first(where: { $0.id == record.chatID }) {
                    controlTurns[turn]?.finalSnapshot = controlSnapshot(
                        turn: turn, record: record, chat: chat, running: false)
                }
            }
        }
        self.activeTurnSessionID = activeSessionID
    }
}
