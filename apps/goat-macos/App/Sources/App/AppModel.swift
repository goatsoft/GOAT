import AppKit
import Bleet
import Caprine
import Foundation
import GOATed
import Herd
import Hitch
import Hoofprint
import Inference
import JUDAS
import Observation
import Paddock
import Pens
import Persistence
import Shepherd
import SwiftUI

/// Unbuffered debug logging (stderr) - visible when the binary is run from a shell.
/// Compiled out of Release builds; user-facing diagnostics belong in `ActivityLog`.
@inline(__always) func dlog(_ s: String) {
    #if DEBUG
    FileHandle.standardError.write(Data(("[GOAT] " + s + "\n").utf8))
    #endif
}

/// A receipt for an explicit save during this app session, not live provider membership.
enum MessageMemorySaveState: Equatable {
    case saving
    case queued
    case saved
    case failed(String)

    var preventsRepeat: Bool {
        switch self {
        case .saving, .queued, .saved: true
        case .failed: false
        }
    }

    var isAccepted: Bool { self == .queued || self == .saved }

    var help: String {
        switch self {
        case .saving: "Saving to memory…"
        case .queued: "Queued for memory"
        case .saved: "Saved to memory"
        case .failed(let reason): "Could not save to memory: \(reason). Click to retry."
        }
    }
}

/// The composition root: app-wide state (chats, projects, selection, appearance,
/// engine health) plus ownership of the feature models - `ShepherdModel` runs
/// generation, `MCPModel` owns tools. Views reach features through this object.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    // MARK: State

    var chats: [ChatSession] = []
    var pens: [Pen] = []
    var selectedChatID: UUID? {
        didSet {
            if oldValue != selectedChatID { paddockArtifact = nil }
            if selectedChatID != nil {
                selectedPenID = nil
                showingPensHome = false
            }
            UserDefaults.standard.set(selectedChatID?.uuidString, forKey: "chat.selected")
            if let session = currentSession, !session.messagesLoaded {
                Task { await loadMessages(for: session) }
            }
            let previousModelID =
                oldValue
                .flatMap { oldID in chats.first(where: { $0.id == oldID }) }
                .flatMap(\.modelID) ?? defaultModelID
            if !engineTransitioning, health.isOK,
                let modelID = currentSession?.modelID ?? defaultModelID,
                Self.selectionNeedsCapabilityProbe(
                    previousModelID: previousModelID, currentModelID: modelID)
            {
                scheduleModelCapabilityProbe(modelID: modelID)
            }
        }
    }
    var currentSession: ChatSession? { chats.first { $0.id == selectedChatID } }

    /// When set, the detail pane shows that Pen's landing page instead of a chat.
    var selectedPenID: UUID?
    var selectedPen: Pen? { pens.first { $0.id == selectedPenID } }
    var penComposerFocusID: UUID?
    var showingPensHome = false
    func openPensHome() {
        selectedPenID = nil
        selectedChatID = nil
        showingPensHome = true
    }
    func openPen(_ pen: Pen) {
        showingPensHome = false
        selectedPenID = pen.id
    }
    var showInspector = false
    var showNewPenSheet = false
    var editingPen: Pen?
    var dbWarning: String?
    var paddockArtifact: PaddockArtifact?
    var renamingChat: ChatSession?
    var renameDraft = ""
    let activity = ActivityLog()
    var judasMode: JudasMode = .configured {
        didSet {
            Judas.shared.setMode(judasMode)
            UserDefaults.standard.set(judasMode.rawValue, forKey: "judas.mode")
            activity.drainJudas()
        }
    }
    var showActivityLog = false
    var activeTurnSessionID: UUID?
    var startupPhase: StartupPhase = .launching
    let startupCoordinator = StartupCoordinator()
    let fileWorker = AppFileWorker.shared

    // MARK: Feature models

    let mcp: MCPModel
    let memory: MemoryModel
    var controlEnabled = false
    var pronkEnabled = false
    var extensionsChanging = false
    var extensionError: String?
    var controlSession: AppControlSession?
    struct ControlTurn {
        let chatID: UUID
        let firstMessageIndex: Int
        var cancelled = false
        var finalSnapshot: [String: String]?
    }
    var controlTurns: [UUID: ControlTurn] = [:]
    let toolRouter: AppToolRouter
    var commandPermissions: PenCommandPermissionModel { toolRouter.commandPermissions }
    var filePermissions: PenFilePermissionModel { toolRouter.filePermissions }
    let shepherd: ShepherdModel
    let userExtensions: UserExtensionManager

    func rename(_ chat: ChatSession, to title: String) async {
        guard startupPhase.hasLocalState, !deletingChatIDs.contains(chat.id) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let previous = chat.title
        chat.title = trimmed
        let revision = nextChatStoreRevision(for: chat.id)
        guard await saveChatRecord(record(for: chat), revision: revision) else {
            if chatStoreRevisions[chat.id] == revision, chat.title == trimmed {
                chat.title = previous
            }
            return
        }
    }

    func openInPaddock(_ artifact: PaddockArtifact) {
        paddockArtifact = artifact
        showInspector = true
    }

    // Sidebar groupings (pinned chats live only in Pinned)
    var pinnedChats: [ChatSession] { chats.filter(\.pinned) }
    var looseChats: [ChatSession] {
        let visiblePenIDs = Set(pens.map(\.id))
        return chats.filter { chat in
            guard !chat.pinned else { return false }
            guard let projectID = chat.projectID else { return true }
            return !visiblePenIDs.contains(projectID)
        }
    }
    func chats(in pen: Pen) -> [ChatSession] {
        chats.filter { !$0.pinned && $0.projectID == pen.id }
    }

    // MARK: Engine

    let engine: OpenAICompatEngine
    let engineLifecycle = EngineLifecycleController()
    let engineRecovery = EngineRecoveryController()
    let modelCapabilityOwnership = ModelCapabilityProbeOwnership()
    var engineIntentRevision: UInt64 = 0
    var modelCapabilityIntentRevision: UInt64 = 0
    var modelCapabilityTask: Task<Void, Never>?
    var engineCredentials: [String: String] = [:]
    var installedEngineApplicationPaths: Set<String> = []
    var engineStoreRevision: UInt64 = 0
    var engineStoreWritable = true
    var credentialRevisions: [String: UInt64] = [:]
    var themeStoreRevision: UInt64 = 0
    var penStoreRevisions: [UUID: UInt64] = [:]
    var deletingPenIDs: Set<UUID> = []
    var herdRootPath: String {
        didSet { UserDefaults.standard.set(herdRootPath, forKey: "herd.defaultRoot") }
    }
    var health: EngineHealth = .offline("Starting…")
    var engineTransitioning = false
    var modelCapabilitiesLoading = false
    var capabilityProbeModelID: String?
    /// Dedicated coder variants lead the UI and first-run default, without changing their wire format.
    var models: [ModelRef] { health.models }
    var endpoint: String {
        didSet { UserDefaults.standard.set(endpoint, forKey: "engine.endpoint") }
    }
    var defaultModelID: String? {
        didSet { UserDefaults.standard.set(defaultModelID, forKey: "engine.defaultModel") }
    }
    /// The managed list of engines (one active at a time) persisted in engines.json (ADR-0021).
    var engineProfiles: [EngineProfile] = []
    var activeEngineID = ""
    var activeEngineProfile: EngineProfile? { engineProfiles.first { $0.id == activeEngineID } }
    /// The preset backing the active engine: drives its blurb + model-management affordance.
    var enginePreset: EnginePreset { activeEngineProfile?.preset ?? .custom }

    // MARK: Appearance

    let presentation: PresentationPreferences
    var systemIsDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    var themeID: String {
        didSet {
            let selected = presentation.selectTheme(themeID)
            if selected != themeID { themeID = selected }
            UserDefaults.standard.set(themeID, forKey: "appearance.theme")
            if oldValue == "leet", selected != "leet" {
                AppIconManager.apply(.system, unlocked: presentation.isUnlocked, playful: false, dark: theme.isDark)
            }
        }
    }

    func unlockPresentation() -> Bool {
        guard presentation.unlock() else { return false }
        themeID = "leet"
        return true
    }

    func setPlayfulPresentation(_ enabled: Bool) {
        presentation.setEnabled(enabled)
        if presentation.isEnabled {
            themeID = "leet"
        } else {
            themeID = "system"
        }
    }
    /// User themes (folders under ~/.goat/config/themes, ADR-0022); built-ins live in code.
    var userThemes: [ThemeSpec] = []
    /// The resolved theme spec (built-in or a user theme).
    var theme: ThemeSpec {
        if themeID == "system" { return systemIsDark ? ThemeCatalog.midnight : ThemeCatalog.light }
        return ThemeCatalog.spec(id: presentation.permitsTheme(themeID) ? themeID : "system", userThemes: userThemes)
    }
    var preferredColorScheme: SwiftUI.ColorScheme? {
        themeID == "system" ? nil : theme.colorScheme
    }
    var availableThemes: [ThemeSpec] {
        ThemeCatalog.all(userThemes: userThemes).filter { presentation.permitsTheme($0.id) }
    }
    var chatFontSize: Double {
        didSet {
            let normalized = ReadingFontRole.chat.normalizedSize(chatFontSize)
            if chatFontSize != normalized {
                chatFontSize = normalized
                return
            }
            UserDefaults.standard.set(chatFontSize, forKey: "appearance.fontSize")
        }
    }
    var chatFontID: String {
        didSet { UserDefaults.standard.set(chatFontID, forKey: "appearance.chatFont") }
    }
    var codeFontID: String {
        didSet { UserDefaults.standard.set(codeFontID, forKey: "appearance.codeFont") }
    }
    var codeFontSize: Double {
        didSet {
            let normalized = ReadingFontRole.code.normalizedSize(codeFontSize)
            if codeFontSize != normalized {
                codeFontSize = normalized
                return
            }
            UserDefaults.standard.set(codeFontSize, forKey: "appearance.codeFontSize")
        }
    }
    var effectiveChatFontID: String { readingFontID(chatFontID, role: .chat) }
    var effectiveCodeFontID: String { readingFontID(codeFontID, role: .code) }
    var chatNSFont: NSFont { ReadingFonts.nsFont(effectiveChatFontID, size: chatFontSize, role: .chat) }
    var codeNSFont: NSFont { ReadingFonts.nsFont(effectiveCodeFontID, size: codeFontSize, role: .code) }

    func readingFontID(_ selection: String, role: ReadingFontRole) -> String {
        ReadingFonts.requestedID(
            selection: selection, themeFont: role == .chat ? theme.fonts?.chat : theme.fonts?.code, role: role)
    }

    func readingFontName(_ selection: String, role: ReadingFontRole) -> String {
        let id = readingFontID(selection, role: role)
        let name =
            ReadingFonts.isAvailable(id, for: role)
            ? ReadingFonts.name(id, for: role) : (role == .chat ? "System" : "System Mono")
        return selection == "theme" ? "Theme · \(name)" : name
    }

    func readingFontNotice(_ selection: String, role: ReadingFontRole) -> String? {
        let id = readingFontID(selection, role: role)
        guard !ReadingFonts.isAvailable(id, for: role) else { return nil }
        let requested = id.hasPrefix("font:") ? String(id.dropFirst(5)) : id
        return
            "\(requested) is unavailable\(role == .code ? " or not monospaced" : ""). Install it in Font Book to use it. Using \(role == .chat ? "System" : "System Mono")."
    }
    /// 0 = opaque, 1 = maximum see-through; the default strength is 40%.
    var windowTransparency: Double {
        didSet { UserDefaults.standard.set(windowTransparency, forKey: "appearance.transparency") }
    }
    var automaticChatTitles: Bool {
        didSet { UserDefaults.standard.set(automaticChatTitles, forKey: "chat.automaticTitles") }
    }
    var defaultEffort: Effort {
        didSet { UserDefaults.standard.set(defaultEffort.rawValue, forKey: "chat.defaultEffort") }
    }
    /// Optional interface motion. Reduce Motion is additionally respected by rendering views.
    var animationsEnabled: Bool {
        didSet { UserDefaults.standard.set(animationsEnabled, forKey: "appearance.animations") }
    }
    /// When on, Paddock previews are restricted to local content (ADR-0015).
    var previewsOffGrid: Bool {
        didSet { UserDefaults.standard.set(previewsOffGrid, forKey: "paddock.offGrid") }
    }
    /// Settings is a utility panel by default, but its window level is always user-controlled.
    var settingsAlwaysOnTop: Bool {
        didSet { UserDefaults.standard.set(settingsAlwaysOnTop, forKey: "settings.alwaysOnTop") }
    }

    // Easter-egg triggers - bump to fire.
    var goatWalkToken = 0
    var goatCheerToken = 0

    var messageMemorySaves: [UUID: MessageMemorySaveState] = [:]

    func skillCatalog(for session: ChatSession) async -> SkillCatalog {
        await toolRouter.skillCatalog(forChatID: session.id, projectID: session.projectID)
    }

    var db: ChatDatabase?
    var databaseWriter: AppDatabaseWriter?
    var chatStoreRevisions: [UUID: UInt64] = [:]
    var messageRatingRevisions: [UUID: UInt64] = [:]
    var deletingChatIDs: Set<UUID> = []

    /// Discovery probes both common local-engine ports, so this is only a seed value.
    static let fallbackEndpoint: URL = {
        guard let url = URL(string: "http://127.0.0.1:8000") else {
            preconditionFailure("The built-in engine endpoint must be a valid URL.")
        }
        return url
    }()

    private init() {
        RenderingCaches.startMemoryPressureMonitoring()
        let d = UserDefaults.standard
        let isTest =
            ProcessInfo.processInfo.environment["GOAT_TEST_MODE"] == "1"
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let startupJudasMode: JudasMode =
            isTest ? .configured : JudasMode.restored(from: d.string(forKey: "judas.mode"))
        judasMode = startupJudasMode
        Judas.shared.setMode(startupJudasMode)
        Judas.shared.announcePolicy()
        let preferences = PresentationPreferences(defaults: d)
        presentation = preferences
        defaultModelID = d.string(forKey: "engine.defaultModel")
        let storedTheme = d.string(forKey: "appearance.theme") ?? "system"
        themeID = preferences.selectTheme(storedTheme)
        let savedChatSize = ReadingFontRole.chat.normalizedSize(
            (d.object(forKey: "appearance.fontSize") as? NSNumber)?.doubleValue ?? 14)
        chatFontSize = savedChatSize
        chatFontID = d.string(forKey: "appearance.chatFont") ?? "theme"
        codeFontID = d.string(forKey: "appearance.codeFont") ?? "theme"
        codeFontSize = ReadingFontRole.code.normalizedSize(
            (d.object(forKey: "appearance.codeFontSize") as? NSNumber)?.doubleValue ?? savedChatSize * 0.92)
        windowTransparency =
            d.object(forKey: "appearance.transparency") as? Double ?? CaprineBackground.defaultTransparency
        automaticChatTitles = d.object(forKey: "chat.automaticTitles") as? Bool ?? true
        defaultEffort = Effort(rawValue: d.string(forKey: "chat.defaultEffort") ?? "") ?? .trot
        animationsEnabled = d.object(forKey: "appearance.animations") as? Bool ?? true
        previewsOffGrid = d.object(forKey: "paddock.offGrid") as? Bool ?? false
        settingsAlwaysOnTop = d.object(forKey: "settings.alwaysOnTop") as? Bool ?? true
        herdRootPath = d.string(forKey: "herd.defaultRoot") ?? HerdWorkspace.suggestedRoot.path
        // File stores, credentials, and SQLite open during progressive startup, never here.
        let seedURL = d.string(forKey: "engine.endpoint") ?? Self.fallbackEndpoint.absoluteString
        endpoint = seedURL
        engine = OpenAICompatEngine(
            config: EngineConfig(
                baseURL: URL(string: seedURL) ?? Self.fallbackEndpoint,
                apiKey: nil,
                metadataDialect: .generic
            ))
        db = nil
        mcp = MCPModel(db: nil, activity: activity)
        memory = MemoryModel(activity: activity)
        toolRouter = AppToolRouter(mcp: mcp, memory: memory, activity: activity)
        userExtensions = UserExtensionManager(runtime: toolRouter.extensions, activity: activity)
        shepherd = ShepherdModel(engine: engine, tools: toolRouter, activity: activity)
        shepherd.env = self
        toolRouter.workspaceForProject = { [weak self] id in
            self?.pens.first(where: { $0.id == id })?.workspace.map { URL(fileURLWithPath: $0.path) }
        }
        toolRouter.nameForProject = { [weak self] id in
            self?.pens.first(where: { $0.id == id })?.name ?? "this Pen"
        }
    }
}
