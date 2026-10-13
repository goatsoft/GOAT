import Bleet
import Foundation
import GOATed
import Herd
import Inference
import Persistence

@MainActor enum CompactionDeletion {
    static func canRestore(_ message: ChatMessage, in messages: [ChatMessage]) -> Bool {
        message.kind == .compaction
            && messages.last(where: { $0.kind == .compaction })?.id == message.id
    }

    static func removing(_ message: ChatMessage, from messages: [ChatMessage]) -> [ChatMessage] {
        guard canRestore(message, in: messages) else { return messages }
        return messages.filter { $0.id != message.id }
    }
}

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

    /// Deleting the latest compaction row restores the prompt boundary to the preceding
    /// compaction, or to the original transcript when none remains. Covered source messages stay
    /// stored and visible, so this operation removes only the generated summary row.
    func deleteCompaction(_ message: ChatMessage, in chat: ChatSession) async {
        guard startupPhase.hasLocalState, let databaseWriter,
            !chat.isStreaming, chats.contains(where: { $0.id == chat.id }),
            CompactionDeletion.canRestore(message, in: chat.messages)
        else { return }
        guard await hydrateHistory(for: chat), !chat.isStreaming,
            CompactionDeletion.canRestore(message, in: chat.messages)
        else { return }
        do {
            try await databaseWriter.deleteMessage(id: message.id.uuidString)
            chat.messages = CompactionDeletion.removing(message, from: chat.messages)
        } catch {
            dbWarning = "Compaction was not deleted: \(error.localizedDescription)"
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
            statsCachedPromptTokens: msg.stats?.cachedPromptTokens,
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
            statsFinishReason: msg.stats?.finishReason,
            kind: msg.kind.rawValue,
            compactionJson: msg.compaction.flatMap { info in
                (try? JSONEncoder().encode(info)).flatMap { String(data: $0, encoding: .utf8) }
            }
        )
    }

    /// The context window a turn planned against and where the figure came from, mirroring the
    /// budgeter's precedence (ADR-0085): a user override, else the engine- or family-reported
    /// window, else the estimated fallback. Recorded in provenance so a slow prefill or an
    /// overflow can be attributed to the window that was actually in force.
    func effectiveContextWindow(forModelID id: String)
        -> (limit: Int?, source: GenerationProvenanceRecord.ContextLimitSource)
    {
        let identity = ModelIdentity(engineProfileID: activeEngineProfile?.id ?? "", modelID: id)
        let preference = modelPreferences.first { $0.identity == identity }
        let reported = models.first { $0.id == id }?.contextLength
        if preference?.contextWindowOverride != nil {
            return (preference?.effectiveContextLength(reported: reported), .userOverride)
        }
        if let reported {
            return (reported, .reported)
        }
        if let family = ModelFamilyRegistry.profile(for: id)?.contextLength {
            return (family, .modelFamily)
        }
        return (PromptBudgeter.fallbackWindowTokens, .fallback)
    }

    /// Flatten resolved model capabilities into the provenance record's claim map, dropping
    /// unknowns so the log shows only what was actually established.
    static func provenanceCapabilities(_ capabilities: ModelCapabilities)
        -> [String: GenerationProvenanceRecord.CapabilityClaim]
    {
        var result: [String: GenerationProvenanceRecord.CapabilityClaim] = [:]
        func record(_ name: String, _ claim: CapabilityClaim) {
            guard claim.support != .unknown else { return }
            result[name] = GenerationProvenanceRecord.CapabilityClaim(
                support: claim.support.rawValue,
                evidence: claim.evidence.map(\.rawValue))
        }
        record("vision", capabilities.vision)
        record("tools", capabilities.tools)
        record("reasoning", capabilities.reasoning)
        record("reasoningHistory", capabilities.reasoningHistory)
        return result
    }

    private func provenanceJSON(for message: ChatMessage) -> String? {
        guard let context = message.generationContext,
            let parameters = message.generationParameters,
            let lifecycle = message.generationLifecycle,
            let state = GenerationProvenanceRecord.Lifecycle(rawValue: lifecycle)
        else {
            if let source = message.storedGenerationProvenance { return source }
            guard let existing = message.generationProvenance else { return nil }
            return try? String(data: JSONEncoder().encode(existing), encoding: .utf8)
        }
        let contextWindow = effectiveContextWindow(forModelID: context.identity.modelID)
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
            samplingValues: parameters.sampling.fields,
            samplingSource: parameters.samplingSource.rawValue,
            familyRuleID: parameters.familyRuleID,
            reasoningInstruction: parameters.reasoningInstruction,
            omittedSamplingParameters: parameters.omittedSamplingParameters,
            effectiveOutputTokenCap: parameters.outputTokenCap,
            nativeReasoningValue: parameters.nativeReasoningEffort,
            reasoningHistoryReplayed: parameters.replayReasoningHistory,
            templateControls: parameters.qwenEnableThinking.map {
                GenerationProvenanceRecord.TemplateControls(
                    enableThinking: $0,
                    preserveThinking: parameters.qwenPreserveThinking ?? false,
                    reasoningEffort: parameters.qwenReasoningEffort)
            },
            effectiveContextLimit: contextWindow.limit,
            contextLimitSource: contextWindow.source,
            capabilities: Self.provenanceCapabilities(context.compatibility.capabilities),
            lifecycle: state,
            finishReason: message.stats?.finishReason,
            failureCategory: message.generationFailureCategory.flatMap {
                GenerationProvenanceRecord.FailureCategory(rawValue: $0)
            })
        // Refresh the live inspection model as the lifecycle advances. A loaded historical
        // record is the fallback above, never a reason to freeze an active response at prepared.
        message.generationProvenance = record
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
            let page = try await db.messagePage(chatId: session.id.uuidString)
            let records = page.messages
            guard !session.messagesLoaded else { return }
            installHistory(
                decodeMessages(records), records: records, in: session,
                hasEarlier: page.hasEarlier, hasLater: page.hasLater, precedingDate: page.precedingVisibleDate)
            session.messagesLoaded = true
        } catch {
            let message = "Load failed: \(error.localizedDescription)"
            session.messageLoadError = message
            dbWarning = message
        }
    }

    private func decodeMessages(_ records: [MessageRecord], reusing existing: [UUID: ChatMessage] = [:])
        -> [ChatMessage]
    {
        var invalidRecords = 0
        let messages: [ChatMessage] = records.compactMap { record in
            guard let id = Self.canonicalUUID(record.id),
                let role = ChatTurn.Role(rawValue: record.role)
            else {
                invalidRecords += 1
                return nil
            }
            if let existing = existing[id] { return existing }
            let msg = ChatMessage(
                role: role,
                id: id,
                createdAt: record.createdAt
            )
            msg.restoreContent(text: record.text, thinking: record.thinking)
            msg.error = record.error
            msg.rating = record.rating
            msg.complete = record.complete
            msg.kind = ChatMessageKind(rawValue: record.kind) ?? .regular
            if let raw = record.compactionJson?.data(using: .utf8),
                let info = try? JSONDecoder().decode(CompactionInfo.self, from: raw)
            {
                msg.compaction = info
            }
            msg.storedGenerationProvenance = record.generationProvenanceJson
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
                    finishReason: record.statsFinishReason,
                    cachedPromptTokens: record.statsCachedPromptTokens)
            }
            return msg
        }
        if invalidRecords > 0 { dbWarning = "Some message records have invalid IDs or roles." }
        return messages
    }

    private func installHistory(
        _ messages: [ChatMessage], records: [MessageRecord], in session: ChatSession,
        hasEarlier: Bool, hasLater: Bool, precedingDate: Date? = nil
    ) {
        session.historyCursors = Dictionary(
            uniqueKeysWithValues: records.compactMap { record in
                Self.canonicalUUID(record.id).map {
                    ($0, ChatDatabase.MessageCursor(position: record.position, id: record.id))
                }
            })
        session.historyPrecedingDate = precedingDate
        session.historyHasEarlier = hasEarlier
        session.historyHasLater = hasLater
        session.messages = messages
        if !hasLater {
            session.recentPersistedStats = Array(
                messages.compactMap { message in
                    message.stats.map { (id: message.id, stats: $0) }
                }.suffix(12))
            session.latestPersistedStats = session.recentPersistedStats.last?.stats
        }
        session.historyRevision &+= 1
    }

    /// Complete context is loaded only for generation or an explicit whole-history operation.
    /// Existing objects and any newly submitted unsaved user row retain their identity.
    func hydrateHistory(for session: ChatSession) async -> Bool {
        guard !session.hasCompleteHistory else { return true }
        guard let db else { return false }
        session.isHydratingHistory = true
        defer { session.isHydratingHistory = false }
        do {
            let records = try await db.messages(chatId: session.id.uuidString)
            guard chats.contains(where: { $0.id == session.id }) else { return false }
            let existing = Dictionary(uniqueKeysWithValues: session.messages.map { ($0.id, $0) })
            let pending = session.messages.filter { session.historyCursors[$0.id] == nil }
            let stored = decodeMessages(records, reusing: existing)
            let storedIDs = Set(stored.map(\.id))
            installHistory(
                stored + pending.filter { !storedIDs.contains($0.id) }, records: records,
                in: session, hasEarlier: false, hasLater: false)
            return true
        } catch {
            dbWarning = "History could not be loaded: \(error.localizedDescription)"
            return false
        }
    }

    /// Bound idle reader storage while keeping the message the reader owns. Active turns retain
    /// complete context until Shepherd has finished persistence and captured its final receipt.
    func trimHistory(for session: ChatSession) {
        guard !session.isStreaming, !session.isHydratingHistory, session.messages.count > 120,
            session.messages.allSatisfy({ session.historyCursors[$0.id] != nil })
        else { return }
        let anchor = session.historyAnchorID.flatMap { id in session.messages.firstIndex { $0.id == id } }
        let start = min(max(0, (anchor ?? session.messages.count) - 40), session.messages.count - 120)
        let end = start + 120
        session.historyHasEarlier = session.historyHasEarlier || start > 0
        session.historyHasLater = session.historyHasLater || end < session.messages.count
        if let prior = session.messages[..<start].last(where: { $0.role != .tool && !TranscriptActivity.isEmpty($0) }) {
            session.historyPrecedingDate = prior.createdAt
        }
        session.messages = Array(session.messages[start..<end])
        let retained = Set(session.messages.map(\.id))
        session.historyCursors = session.historyCursors.filter { retained.contains($0.key) }
        session.historyRevision &+= 1
    }

    /// A stale page never replaces a changed history or a newly reserved turn.
    @discardableResult
    func pageHistory(for session: ChatSession, earlier: Bool) async -> Bool {
        guard let db, !session.isPagingHistory, !session.isStreaming,
            earlier ? session.historyHasEarlier : session.historyHasLater,
            let boundary = earlier ? session.messages.first : session.messages.last,
            let cursor = session.historyCursors[boundary.id]
        else { return false }
        session.isPagingHistory = true
        session.historyPageError = nil
        let revision = session.historyRevision
        let selected = selectedChatID
        defer { session.isPagingHistory = false }
        do {
            let page = try await db.messagePage(
                chatId: session.id.uuidString,
                before: earlier ? cursor : nil, after: earlier ? nil : cursor)
            guard !Task.isCancelled, selectedChatID == selected, session.historyRevision == revision,
                !session.isStreaming, chats.contains(where: { $0.id == session.id })
            else { return false }
            let incoming = decodeMessages(page.messages)
            let existingIDs = Set(session.messages.map(\.id))
            let fresh = incoming.filter { !existingIDs.contains($0.id) }
            session.messages = earlier ? fresh + session.messages : session.messages + fresh
            for record in page.messages {
                if let id = Self.canonicalUUID(record.id) {
                    session.historyCursors[id] = .init(position: record.position, id: record.id)
                }
            }
            if earlier {
                session.historyPrecedingDate = page.precedingVisibleDate
                session.historyHasEarlier = page.hasEarlier
            } else {
                session.historyHasLater = page.hasLater
            }
            // Keep the newly fetched side plus overlap. At least the previous 40-row display
            // window survives; the navigation owner restores its stable message/segment anchor.
            if session.messages.count > 120 {
                let removed =
                    earlier
                    ? Array(session.messages.suffix(session.messages.count - 120))
                    : Array(session.messages.prefix(session.messages.count - 120))
                session.messages = earlier ? Array(session.messages.prefix(120)) : Array(session.messages.suffix(120))
                if !earlier, let prior = removed.last(where: { $0.role != .tool && !TranscriptActivity.isEmpty($0) }) {
                    session.historyPrecedingDate = prior.createdAt
                }
                for message in removed { session.historyCursors[message.id] = nil }
                if earlier { session.historyHasLater = true } else { session.historyHasEarlier = true }
            }
            session.historyRevision &+= 1
            return true
        } catch {
            session.historyPageError = "History could not be loaded: \(error.localizedDescription)"
            return false
        }
    }

    func loadLatestHistory(for session: ChatSession) async -> Bool {
        guard session.historyHasLater, let db, !session.isStreaming else { return !session.historyHasLater }
        let revision = session.historyRevision
        do {
            let page = try await db.messagePage(chatId: session.id.uuidString)
            guard !Task.isCancelled, revision == session.historyRevision, !session.isStreaming else { return false }
            installHistory(
                decodeMessages(page.messages), records: page.messages, in: session,
                hasEarlier: page.hasEarlier, hasLater: false, precedingDate: page.precedingVisibleDate)
            return true
        } catch {
            session.historyPageError = "History could not be loaded: \(error.localizedDescription)"
            return false
        }
    }

    /// Search one storage page at a time. Result and transient page counts stay bounded even
    /// when a query spans an entire chat; cancellation stops before requesting another page.
    func findInHistory(_ query: String, for session: ChatSession) async throws -> [TranscriptText.SearchMatch] {
        func search(_ entries: [TranscriptText.SearchEntry], limit: Int) async throws -> [TranscriptText.SearchMatch] {
            let worker = Task.detached(priority: .userInitiated) {
                try TranscriptText.find(query, in: entries, limit: limit)
            }
            return try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
        }
        guard !query.isEmpty else { return [] }
        guard !session.hasCompleteHistory, let db else {
            let entries = session.messages.filter { $0.role == .user || $0.role == .assistant }
                .map { TranscriptText.SearchEntry(id: $0.id, source: $0.text) }
            return try await search(entries, limit: 200)
        }
        var cursor: ChatDatabase.MessageCursor?
        var matches: [TranscriptText.SearchMatch] = []
        repeat {
            try Task.checkCancellation()
            let page = try await db.messagePage(chatId: session.id.uuidString, before: cursor)
            let entries = page.messages.reversed().compactMap { record -> TranscriptText.SearchEntry? in
                guard record.role == "user" || record.role == "assistant", let id = Self.canonicalUUID(record.id) else {
                    return nil
                }
                return .init(id: id, source: record.text)
            }
            matches += try await search(entries, limit: 200 - matches.count)
            guard page.hasEarlier, let next = page.earlierCursor, next != cursor else { break }
            cursor = next
        } while matches.count < 200
        return matches
    }

    func inspectHistory(for session: ChatSession) async throws -> [ChatMessage] {
        guard !session.hasCompleteHistory, let db else { return session.messages }
        let records = try await db.messages(chatId: session.id.uuidString)
        return decodeMessages(records, reusing: Dictionary(uniqueKeysWithValues: session.messages.map { ($0.id, $0) }))
    }

    func loadHistory(around id: UUID, for session: ChatSession) async -> Bool {
        if session.messages.contains(where: { $0.id == id }) { return true }
        guard let db, !session.isStreaming else { return false }
        let revision = session.historyRevision
        do {
            guard let record = try await db.message(chatId: session.id.uuidString, id: id.uuidString) else {
                return false
            }
            let cursor = ChatDatabase.MessageCursor(position: record.position, id: record.id)
            let before = try await db.messagePage(chatId: session.id.uuidString, before: cursor, limit: 20)
            let after = try await db.messagePage(chatId: session.id.uuidString, after: cursor, limit: 20)
            guard !Task.isCancelled, revision == session.historyRevision, !session.isStreaming else { return false }
            let records = before.messages + [record] + after.messages
            installHistory(
                decodeMessages(records), records: records, in: session,
                hasEarlier: before.hasEarlier, hasLater: after.hasLater, precedingDate: before.precedingVisibleDate)
            return true
        } catch {
            session.historyPageError = "History could not be loaded: \(error.localizedDescription)"
            return false
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
