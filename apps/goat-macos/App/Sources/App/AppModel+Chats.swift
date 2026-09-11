import Bleet
import Foundation
import GOATed
import Herd
import Inference
import Persistence

extension AppModel {
    // MARK: Chat CRUD

    /// New-chat navigation respects the visible workspace, including a pinned Pen chat.
    static func newChatPenID(
        selectedPenID: UUID?, chatProjectID: UUID?, showingPensHome: Bool, penIDs: Set<UUID>
    ) -> UUID? {
        guard !showingPensHome, let id = selectedPenID ?? chatProjectID, penIDs.contains(id) else { return nil }
        return id
    }

    func beginNewChat() async {
        guard startupPhase.hasLocalState else { return }
        let penID = Self.newChatPenID(
            selectedPenID: selectedPenID, chatProjectID: currentSession?.projectID,
            showingPensHome: showingPensHome, penIDs: Set(pens.map(\.id)))
        if let pen = pens.first(where: { $0.id == penID }) {
            beginNewChat(in: pen)
        } else {
            await newChat()
        }
    }

    /// Pen new-chat actions navigate to the draft composer. Persistence starts on first send.
    func beginNewChat(in pen: Pen) {
        guard pens.contains(where: { $0.id == pen.id }), !deletingPenIDs.contains(pen.id) else { return }
        openPen(pen)
        penComposerFocusID = pen.id
    }

    @discardableResult
    func newChat(in pen: Pen? = nil) async -> UUID? {
        guard startupPhase.hasLocalState, databaseWriter != nil else { return nil }
        if let pen {
            guard pens.contains(where: { $0.id == pen.id }), !deletingPenIDs.contains(pen.id) else {
                return nil
            }
        }
        let chat = ChatSession(effort: defaultEffort, modelID: defaultModelID, projectID: pen?.id)
        chat.messagesLoaded = true
        let revision = nextChatStoreRevision(for: chat.id)
        guard await saveChatRecord(record(for: chat), revision: revision) else { return nil }
        chats.insert(chat, at: 0)
        selectedChatID = chat.id
        return chat.id
    }

    /// Promote the Pen composer draft before submitting. Its UUID owns chat-scoped permissions;
    /// preserving the session also preserves its selected model, effort and tool configuration.
    func startChat(
        in pen: Pen,
        with text: String,
        attachments: [Data] = [],
        documents: [TextAttachment] = [],
        draft: ChatSession
    ) async -> Bool {
        guard startupPhase.hasLocalState, databaseWriter != nil,
            activeTurnSessionID == nil, !engineTransitioning, !modelCapabilitiesLoading, health.isOK,
            !filePermissions.isUpdating,
            pens.contains(where: { $0.id == pen.id }), !deletingPenIDs.contains(pen.id)
        else { return false }
        guard
            let chat = ChatLaunch.sessionForSubmission(
                draft, penID: pen.id, existingChatIDs: Set(chats.map(\.id)))
        else { return false }
        chat.modelID = Self.resolvedModelID(
            requested: chat.modelID, defaultModelID: defaultModelID, availableModels: models)
        let revision = nextChatStoreRevision(for: chat.id)
        return await ChatLaunch.submit(
            text: text, attachments: attachments, hasDocuments: !documents.isEmpty,
            persist: { await self.saveChatRecord(self.record(for: chat), revision: revision) },
            accept: { text, attachments in
                guard self.pens.contains(where: { $0.id == pen.id }),
                    !self.deletingPenIDs.contains(pen.id), !Task.isCancelled
                else { return false }
                self.chats.insert(chat, at: 0)
                return self.send(text, attachments: attachments, documents: documents, in: chat) != nil
            },
            navigate: { self.selectedChatID = chat.id },
            discard: { await self.delete(chat) })
    }

    func delete(_ chat: ChatSession) async {
        guard startupPhase.hasLocalState, let databaseWriter,
            deletingChatIDs.insert(chat.id).inserted
        else { return }
        defer { deletingChatIDs.remove(chat.id) }
        if chat.isStreaming {
            let activeTask = shepherd.streamTask
            stop(sessionID: chat.id)
            await activeTask?.value
        }
        if let penID = chat.projectID {
            guard await filePermissions.reset(penID: penID, chatID: chat.id) else { return }
            commandPermissions.reset(penID: penID, chatID: chat.id)
            await toolRouter.stopCommands(penID: penID, chatID: chat.id)
        }
        let revision = nextChatStoreRevision(for: chat.id)
        do {
            guard
                try await databaseWriter.deleteChat(
                    id: chat.id.uuidString, revision: revision)
            else { return }
            guard chatStoreRevisions[chat.id] == revision else { return }
            chats.removeAll { $0.id == chat.id }
            if selectedChatID == chat.id { selectedChatID = chats.first?.id }
        } catch {
            dbWarning = "Chat was not deleted: \(error.localizedDescription)"
        }
    }

    func togglePin(_ chat: ChatSession) async {
        guard startupPhase.hasLocalState, !deletingChatIDs.contains(chat.id) else { return }
        let previous = chat.pinned
        chat.pinned.toggle()
        let revision = nextChatStoreRevision(for: chat.id)
        guard await saveChatRecord(record(for: chat), revision: revision) else {
            if chatStoreRevisions[chat.id] == revision, chat.pinned != previous {
                chat.pinned = previous
            }
            return
        }
    }

    func move(chatID: UUID, to pen: Pen?) async {
        guard startupPhase.hasLocalState else { return }
        guard let chat = chats.first(where: { $0.id == chatID }),
            !deletingChatIDs.contains(chat.id)
        else { return }
        if let pen {
            guard pens.contains(where: { $0.id == pen.id }), !deletingPenIDs.contains(pen.id) else {
                return
            }
        }
        if shepherd.activeSessionID == chat.id {
            let activeTask = shepherd.streamTask
            stop(sessionID: chat.id)
            await activeTask?.value
        }
        // A move changes the scope used by this chat's future turns. Notes already saved in the
        // previous Global or Pen store remain there; GOAT never copies, merges, or relabels them.
        let previous = chat.projectID
        if previous != pen?.id, let previous {
            guard await filePermissions.reset(penID: previous, chatID: chat.id) else { return }
            commandPermissions.reset(penID: previous, chatID: chat.id)
            await toolRouter.stopCommands(penID: previous, chatID: chat.id)
        }
        chat.projectID = pen?.id
        let revision = nextChatStoreRevision(for: chat.id)
        guard await saveChatRecord(record(for: chat), revision: revision) else {
            if chatStoreRevisions[chat.id] == revision, chat.projectID == pen?.id {
                chat.projectID = previous
            }
            return
        }
    }

    func persistMeta(_ chat: ChatSession) {
        guard let databaseWriter, chats.contains(where: { $0.id == chat.id }),
            !deletingChatIDs.contains(chat.id)
        else { return }
        let revision = nextChatStoreRevision(for: chat.id)
        let record = record(for: chat)
        Task {
            do {
                _ = try await databaseWriter.saveChat(record, revision: revision)
            } catch {
                dlog("persistMeta FAILED: \(error)")
                dbWarning = "Save failed: \(error.localizedDescription)"
            }
        }
    }

    func nextChatStoreRevision(for id: UUID) -> UInt64 {
        let revision = (chatStoreRevisions[id] ?? 0) &+ 1
        chatStoreRevisions[id] = revision
        return revision
    }

    func saveChatRecord(_ record: ChatRecord, revision: UInt64) async -> Bool {
        guard let databaseWriter else { return false }
        do {
            guard let id = Self.canonicalUUID(record.id) else {
                dbWarning = "Chat was not saved because its ID is invalid."
                return false
            }
            let saved = try await databaseWriter.saveChat(record, revision: revision)
            return saved && chatStoreRevisions[id] == revision
        } catch {
            dbWarning = "Chat was not saved: \(error.localizedDescription)"
            return false
        }
    }

    func record(for chat: ChatSession) -> ChatRecord {
        let persistedProjectID = chat.projectID.flatMap { projectID in
            deletingPenIDs.contains(projectID) ? nil : projectID.uuidString
        }
        return ChatRecord(
            id: chat.id.uuidString,
            projectId: persistedProjectID,
            title: chat.title,
            pinned: chat.pinned,
            modelId: chat.modelID,
            effort: chat.effort.rawValue,
            createdAt: chat.createdAt,
            updatedAt: chat.updatedAt,
            toolsEnabled: chat.toolsEnabled,
            disabledMCPServers: chat.disabledMCPServers.sorted()
        )
    }

    func record(for msg: ChatMessage, in chat: ChatSession, position: Int) -> MessageRecord {
        MessageRecord(
            id: msg.id.uuidString,
            chatId: chat.id.uuidString,
            role: msg.role.rawValue,
            text: msg.text,
            thinking: msg.thinking,
            error: msg.error,
            statsTtft: msg.stats?.ttft,
            statsTokens: msg.stats?.tokens,
            statsDuration: msg.stats?.duration,
            statsGenerationTokensPerSecond: msg.stats?.generationTokensPerSecond,
            statsTokensAreExact: msg.stats?.tokensAreExact,
            complete: msg.complete,
            position: position,
            createdAt: msg.createdAt,
            attachmentsJson: msg.attachmentPaths.isEmpty
                ? nil
                : (try? JSONEncoder().encode(msg.attachmentPaths)).flatMap { String(data: $0, encoding: .utf8) },
            toolsJson: msg.toolEvents.isEmpty
                ? nil
                : (try? JSONEncoder().encode(msg.toolEvents)).flatMap { String(data: $0, encoding: .utf8) },
            rating: msg.rating,
            generationProvenanceJson: provenanceJSON(for: msg),
            statsFinishReason: msg.stats?.finishReason
        )
    }

    private func provenanceJSON(for message: ChatMessage) -> String? {
        if let existing = message.generationProvenance {
            return try? String(data: JSONEncoder().encode(existing), encoding: .utf8)
        }
        guard let context = message.generationContext,
            let parameters = message.generationParameters,
            let lifecycle = message.generationLifecycle,
            let state = GenerationProvenanceRecord.Lifecycle(rawValue: lifecycle)
        else { return nil }
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        let record = GenerationProvenanceRecord(
            engineProfileID: context.engineProfileID,
            engineDisplayName: context.engineName,
            requestedModelID: context.identity.modelID,
            requestStartedAt: message.createdAt,
            appVersion: appVersion,
            appBuild: appBuild,
            resolvedRequestStyle: context.compatibility.effectiveStyle.rawValue,
            resolutionSource: context.compatibility.source.rawValue,
            adapterIdentifier: context.compatibility.adapterIdentifier,
            selectedEffort: message.generationSelectedEffort ?? "Unknown",
            actualTemperature: parameters.temperature,
            effectiveOutputTokenCap: parameters.outputTokenCap,
            nativeReasoningValue: parameters.nativeReasoningEffort,
            reasoningHistoryReplayed: parameters.replayReasoningHistory,
            templateControls: parameters.qwenEnableThinking.map {
                GenerationProvenanceRecord.TemplateControls(
                    enableThinking: $0,
                    preserveThinking: parameters.qwenPreserveThinking ?? false,
                    reasoningEffort: parameters.qwenReasoningEffort)
            },
            effectiveContextLimit: nil,
            contextLimitSource: .unknown,
            capabilities: [:],
            lifecycle: state,
            finishReason: message.stats?.finishReason)
        return try? String(data: JSONEncoder().encode(record), encoding: .utf8)
    }

    func loadMessages(for session: ChatSession) async {
        guard !session.isLoadingMessages else { return }
        guard let db, !session.messagesLoaded else {
            session.messagesLoaded = true
            return
        }
        session.isLoadingMessages = true
        session.messageLoadError = nil
        defer { session.isLoadingMessages = false }
        do {
            let records = try await db.messages(chatId: session.id.uuidString)
            guard !session.messagesLoaded else { return }
            var invalidRecords = 0
            session.messages = records.compactMap { record in
                guard let id = Self.canonicalUUID(record.id),
                    let role = ChatTurn.Role(rawValue: record.role)
                else {
                    invalidRecords += 1
                    return nil
                }
                let msg = ChatMessage(
                    role: role,
                    id: id,
                    createdAt: record.createdAt
                )
                msg.restoreContent(text: record.text, thinking: record.thinking)
                msg.error = record.error
                msg.rating = record.rating
                msg.complete = record.complete
                if let rawText = record.generationProvenanceJson,
                    rawText.utf8.count <= 256 * 1_024,
                    let raw = rawText.data(using: .utf8)
                {
                    do {
                        msg.generationProvenance =
                            try JSONDecoder().decode(GenerationProvenanceRecord.self, from: raw)
                    } catch {
                        msg.generationProvenanceUnavailable = true
                        dbWarning = "Some response provenance is unavailable because it could not be decoded."
                    }
                } else if record.generationProvenanceJson != nil {
                    msg.generationProvenanceUnavailable = true
                    dbWarning = "Some response provenance is unavailable because it exceeded the local limit."
                }
                if let raw = record.attachmentsJson?.data(using: .utf8),
                    let paths = try? JSONDecoder().decode([String].self, from: raw)
                {
                    msg.attachmentPaths = paths
                }
                if let raw = record.toolsJson?.data(using: .utf8),
                    let events = try? JSONDecoder().decode([ToolEventSnapshot].self, from: raw)
                {
                    msg.toolEvents = events
                }
                if let tokens = record.statsTokens, let duration = record.statsDuration {
                    msg.stats = GenStats(
                        ttft: record.statsTtft,
                        tokens: tokens,
                        duration: duration,
                        tokensAreExact: record.statsTokensAreExact ?? false,
                        generationTokensPerSecond: record.statsGenerationTokensPerSecond,
                        finishReason: record.statsFinishReason)
                }
                return msg
            }
            if invalidRecords > 0 {
                let warning =
                    "Ignored \(invalidRecords) message record\(invalidRecords == 1 ? "" : "s") with invalid IDs or roles."
                session.messageLoadError = warning
                dbWarning = warning
            }
            session.messagesLoaded = true
        } catch {
            let message = "Load failed: \(error.localizedDescription)"
            session.messageLoadError = message
            dbWarning = message
        }
    }

    func retryMessageLoad(for session: ChatSession) {
        guard startupPhase.hasLocalState, chats.contains(where: { $0.id == session.id }) else { return }
        Task { await loadMessages(for: session) }
    }

    func resort() {
        chats.sort {
            ($0.updatedAt, $0.createdAt.timeIntervalSince1970) > ($1.updatedAt, $1.createdAt.timeIntervalSince1970)
        }
    }

}
