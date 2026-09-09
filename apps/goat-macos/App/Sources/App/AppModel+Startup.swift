import Bleet
import Foundation
import GOATed
import Herd
import Inference

extension AppModel {
    // MARK: Lifecycle

    func start() async {
        // Hosted tests must not load the developer's GOAT Home or start configured services.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
            ProcessInfo.processInfo.environment["GOAT_TEST_MODE"] != "1"
        else { return }
        await startupCoordinator.run { [weak self] in
            await self?.performStartup()
        }
    }

    private func performStartup() async {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        startupPhase = .restoringLocalState
        let defaults = UserDefaults.standard
        let legacy = LegacyEngineSettings(
            endpoint: defaults.string(forKey: "engine.endpoint"),
            presetID: defaults.string(forKey: "engine.preset"))
        let storedSelection = defaults.string(forKey: "chat.selected").flatMap(UUID.init(uuidString:))

        let snapshot = await Task.detached(priority: .userInitiated) {
            await StartupDiskLoader.load(legacy: legacy)
        }.value
        applyStartupDiskSnapshot(snapshot, storedSelection: storedSelection)
        await filePermissions.load(database: db)
        guard snapshot.persistenceReady else {
            startupPhase = .failed(snapshot.databaseWarning ?? "Persistence is unavailable.")
            return
        }
        if chats.isEmpty, !(await createInitialChat()) {
            startupPhase = .failed(dbWarning ?? "Could not create the first chat.")
            return
        }
        if selectedChatID == nil { selectedChatID = chats.first?.id }
        startupPhase = .connectingServices
        shouldPresentEngineSetup = needsEngineSetup
        dlog(String(format: "startup: local state %.3fs", Self.elapsedSeconds(since: startedAt)))

        // Publish restored state before optional network/process services begin settling.
        await Task.yield()
        async let engineSeconds = connectEngineForStartup()
        async let mcpSeconds = connectMCPForStartup()
        async let memoryLoad = memory.load()
        let serviceSeconds = await (engineSeconds, mcpSeconds)
        await memoryLoad

        await userExtensions.load()
        startupPhase = .ready
        await setPronkEnabled(UserDefaults.standard.bool(forKey: "goated.pronk"))
        await setControlEnabled(UserDefaults.standard.bool(forKey: "goated.control"))
        dlog(
            String(
                format: "startup: services engine %.3fs, MCP %.3fs; ready %.3fs (%d chats, %d pens, %d MCP servers)",
                serviceSeconds.0, serviceSeconds.1, Self.elapsedSeconds(since: startedAt),
                chats.count, pens.count, mcp.configs.count))
    }

    private func connectEngineForStartup() async -> Double {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        await discover()
        return Self.elapsedSeconds(since: startedAt)
    }

    private func connectMCPForStartup() async -> Double {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        await mcp.load()
        return Self.elapsedSeconds(since: startedAt)
    }

    nonisolated private static func elapsedSeconds(since startedAt: UInt64) -> Double {
        let now = DispatchTime.now().uptimeNanoseconds
        return Double(now &- startedAt) / 1_000_000_000
    }

    nonisolated static func canonicalUUID(_ value: String) -> UUID? {
        guard let id = UUID(uuidString: value), id.uuidString == value else { return nil }
        return id
    }

    func retryStartup() async {
        guard case .failed = startupPhase else { return }
        startupPhase = .launching
        await startupCoordinator.reset()
        await start()
    }

    private func createInitialChat() async -> Bool {
        guard let db else { return false }
        let chat = ChatSession(effort: defaultEffort, modelID: defaultModelID)
        chat.messagesLoaded = true
        do {
            try await db.save(record(for: chat))
        } catch {
            dbWarning = "Could not create a chat: \(error.localizedDescription)"
            return false
        }
        chats.insert(chat, at: 0)
        selectedChatID = chat.id
        return true
    }

    private func applyStartupDiskSnapshot(_ snapshot: StartupDiskSnapshot, storedSelection: UUID?) {
        db = snapshot.persistenceReady ? snapshot.database : nil
        databaseWriter = snapshot.persistenceReady ? snapshot.database.map(AppDatabaseWriter.init) : nil
        mcp.attachDatabase(snapshot.persistenceReady ? snapshot.database : nil)
        dbWarning = snapshot.databaseWarning
        userThemes = snapshot.themes
        engineProfiles = snapshot.engineFile.engines
        engineStoreWritable = snapshot.engineStoreWritable
        engineCredentials = snapshot.engineCredentials
        installedEngineApplicationPaths = snapshot.installedApplicationPaths
        activeEngineID =
            snapshot.engineFile.active.flatMap { active in
                engineProfiles.contains(where: { $0.id == active }) ? active : nil
            } ?? engineProfiles.first?.id ?? ""
        endpoint = activeEngineProfile?.url ?? ""
        pens = snapshot.pens.compactMap { item in
            guard let id = Self.canonicalUUID(item.spec.id) else { return nil }
            return Pen(
                id: id, name: item.spec.name,
                emoji: item.spec.emoji, instructions: item.instructions,
                color: item.spec.color, files: item.spec.files, workspace: item.spec.workspace,
                createdAt: item.spec.createdAt)
        }
        chats = snapshot.chats.compactMap { record in
            guard let id = Self.canonicalUUID(record.id) else { return nil }
            let session = ChatSession(
                id: id,
                effort: Effort(rawValue: record.effort) ?? .trot,
                modelID: record.modelId,
                projectID: record.projectId.flatMap(UUID.init(uuidString:)),
                createdAt: record.createdAt,
                updatedAt: record.updatedAt)
            session.title = record.title
            session.pinned = record.pinned
            session.toolsEnabled = record.toolsEnabled
            session.disabledMCPServers = Set(
                record.disabledMCPServers.prefix(256).filter {
                    !$0.isEmpty && $0.utf8.count <= 64
                })
            return session
        }
        resort()
        if let storedSelection, chats.contains(where: { $0.id == storedSelection }) {
            selectedChatID = storedSelection
        }
    }

}
