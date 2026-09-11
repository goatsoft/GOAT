import Bleet
import Caprine
import CoreGraphics
import GOATed
import Herd
import Hoofprint
import Inference
import MCPClient
import SwiftUI
import UniformTypeIdentifiers

/// Caps explicit transcript scroll commands. Streaming still lays out at publication cadence, but
/// it does not start a new overlapping scroll animation for every 33 ms text batch.
struct TranscriptFollowThrottle: Sendable, Equatable {
    let minimumInterval: TimeInterval
    private(set) var nextEligibleTime: TimeInterval = 0

    init(maximumUpdatesPerSecond: Double = 15) {
        minimumInterval = 1 / max(1, maximumUpdatesPerSecond)
    }

    func delay(at time: TimeInterval) -> TimeInterval {
        max(0, nextEligibleTime - time)
    }

    mutating func recordFire(at time: TimeInterval) {
        nextEligibleTime = time + minimumInterval
    }

    mutating func reset() {
        nextEligibleTime = 0
    }
}

struct ChatView: View {
    @Bindable var session: ChatSession
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var submittingLead = false
    @State private var leadFailure: String?
    @State private var attachmentFailure: String?
    @State private var pending: [PendingAttachment] = []
    @State private var attachmentJobs: [UUID: Task<Void, Never>] = [:]
    @State private var attachmentImportGeneration = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    private var playfulMotion: Bool {
        model.presentation.isEnabled && model.animationsEnabled && !reduceMotion && scenePhase == .active
    }
    @State private var composerFocused = false

    static func permitsSend(
        localStateReady: Bool, engineIsHealthy: Bool, messagesLoaded: Bool,
        modelCanGenerate: Bool = true, isBusy: Bool
    ) -> Bool {
        localStateReady && engineIsHealthy && messagesLoaded && modelCanGenerate && !isBusy
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if model.engineTransitioning {
                EngineConnectingBanner()
            } else if !model.health.isOK {
                EngineBanner()
            }
            ChatTranscriptView(session: session).id(session.id)
            Composer(
                session: session,
                draft: $draft,
                pending: $pending,
                focused: $composerFocused,
                canSend: Self.permitsSend(
                    localStateReady: model.startupPhase.hasLocalState,
                    engineIsHealthy: model.health.isOK,
                    messagesLoaded: session.messagesLoaded,
                    modelCanGenerate: model.canGenerateWithSelectedModel(for: session),
                    isBusy: model.activeTurnSessionID != nil || model.engineTransitioning
                        || model.modelCapabilitiesLoading),
                isStreaming: model.activeTurnSessionID != nil,
                attachmentsLoading: !attachmentJobs.isEmpty,
                attachmentFailure: attachmentFailure,
                onSend: sendDraft,
                onStop: { model.stop() },
                onAttach: addAttachment,
                onImportFiles: importAttachments,
                canLead: model.activeTurnSessionID == session.id && model.shepherd.acceptsLead,
                submittingLead: submittingLead,
                pendingLeadCount: model.activeTurnSessionID == session.id ? model.shepherd.pendingLeadCount : 0
            )
            .overlay(alignment: .top) {
                // Both easter-egg goats strut along the very top edge of the composer card,
                // on the same floor line. 👎 poops, 👍 leaps - same choreography (GoatStrut).
                if playfulMotion, let walkID {
                    GoatWalk { self.walkID = nil }
                        .id(walkID)
                        .frame(height: 62)
                        .frame(maxWidth: .infinity)
                        .offset(y: -58)  // feet rest on the composer's top edge
                        .allowsHitTesting(false)
                }
                if playfulMotion, let cheerID {
                    GoatPronk { self.cheerID = nil }
                        .id(cheerID)
                        .frame(height: 62)
                        .frame(maxWidth: .infinity)
                        .offset(y: -58)
                        .allowsHitTesting(false)
                }
            }
            if let leadFailure {
                Text(leadFailure).font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 22)
            }
            if model.showActivityLog {
                ActivityLogPanel()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay {
            // 🏔️ Summit ("send it") blasts a rocket-goat diagonally across the whole chat, from
            // any effort source (capsule, model menu, ⌘4). Flies over everything, hit-transparent.
            if playfulMotion, let rocketID {
                GoatRocket { self.rocketID = nil }
                    .id(rocketID)
            }
        }
        .onChange(of: model.goatWalkToken) { _, v in if playfulMotion { walkID = v } }
        .onChange(of: model.goatCheerToken) { _, v in if playfulMotion { cheerID = v } }
        .onChange(of: session.effort) { _, effort in
            if playfulMotion && effort == .summit { rocketID = UUID() }
        }
        .onChange(of: playfulMotion) { _, enabled in
            if !enabled {
                walkID = nil
                cheerID = nil
                rocketID = nil
            }
        }
        .onPasteCommand(of: [UTType.image]) { providers in
            loadImages(from: providers)
        }
        .sheet(item: Binding(get: { model.mcp.pendingPermission }, set: { _ in })) { request in
            PermissionSheet(request: request)
                .interactiveDismissDisabled()
        }
        .background(.clear)
        .navigationTitle(session.title)
        .navigationSubtitle(projectName ?? "")
        .toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { model.showActivityLog.toggle() }
                } label: {
                    ChromeToggleIcon(systemImage: "terminal")
                }
                .buttonStyle(.plain)
                .help("Toggle Log (⌃`)")
                .accessibilityLabel(model.showActivityLog ? "Hide Log" : "Show Log")
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showInspector.toggle()
                } label: {
                    ChromeToggleIcon(systemImage: "sidebar.trailing")
                }
                .buttonStyle(.plain)
                .help("Toggle inspector (⌥⌘I)")
                .keyboardShortcut("i", modifiers: [.option, .command])
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .inspector(isPresented: $model.showInspector) {
            if let artifact = model.paddockArtifact {
                PaddockView(artifact: artifact)
                    .inspectorColumnWidth(min: 300, ideal: 480, max: 820)
            } else {
                InspectorView(session: session)
                    .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
            }
        }
        .onAppear { composerFocused = true }
        .onChange(of: session.id) { _, _ in composerFocused = true }
        .onDisappear {
            cancelAttachmentJobs()
            model.mcp.cancelPendingPermission()
        }
        .onChange(of: session.id) {
            cancelAttachmentJobs()
            pending = []
        }
        .onChange(of: session.effort) { _, _ in model.persistMeta(session) }
    }

    @State private var walkID: Int?
    @State private var cheerID: Int?
    @State private var rocketID: UUID?

    private var projectName: String? {
        guard let id = session.projectID else { return nil }
        return model.pens.first(where: { $0.id == id }).map { "\($0.emoji) \($0.name)" }
    }

    private func sendDraft() {
        guard attachmentJobs.isEmpty else { return }
        if model.activeTurnSessionID == session.id {
            guard pending.isEmpty, !submittingLead else { return }
            let text = draft
            submittingLead = true
            leadFailure = nil
            Task { @MainActor in
                let saved = await model.shepherd.lead(text, in: session)
                if saved {
                    if draft == text { draft = "" }
                } else {
                    leadFailure =
                        "Lead could not be sent. Your draft is kept; try again or send it when the agent finishes."
                }
                submittingLead = false
            }
            return
        }
        leadFailure = nil
        attachmentImportGeneration = UUID()
        let text = draft
        let images = pending.compactMap(\.imageData)
        let documents = pending.compactMap(\.document)
        guard model.send(text, attachments: images, documents: documents, in: session) != nil else { return }
        draft = ""
        pending = []
        attachmentFailure = nil
    }

    private func addAttachment(_ raw: Data) {
        let jobID = UUID()
        let job = Task { @MainActor in
            defer { attachmentJobs.removeValue(forKey: jobID) }
            let image = await ImageFileWorker.shared.prepare(raw)
            guard !Task.isCancelled else { return }
            guard let image else {
                attachmentFailure = "The pasted image could not be read. Choose an image no larger than 25 MB."
                return
            }
            attachmentFailure = nil
            pending.append(PendingAttachment(data: image.pngData, preview: image.preview))
        }
        attachmentJobs[jobID] = job
    }

    private func importAttachments(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let jobID = UUID()
        let job = Task { @MainActor in
            defer { attachmentJobs.removeValue(forKey: jobID) }
            let result = await ChatAttachmentImporter.shared.importFiles(urls)
            guard !Task.isCancelled else { return }
            pending.append(
                contentsOf: result.images.map {
                    PendingAttachment(data: $0.image.pngData, preview: $0.image.preview, name: $0.name)
                })
            pending.append(contentsOf: result.documents.map { PendingAttachment(document: $0) })
            attachmentFailure = result.failures.isEmpty ? nil : result.failures.joined(separator: "\n")
        }
        attachmentJobs[jobID] = job
    }

    private func loadImages(from providers: [NSItemProvider]) {
        let generation = attachmentImportGeneration
        for provider in providers {
            _ = provider.loadDataRepresentation(for: UTType.image) { data, _ in
                guard let data else { return }
                Task { @MainActor in
                    guard generation == attachmentImportGeneration else { return }
                    addAttachment(data)
                }
            }
        }
    }

    private func cancelAttachmentJobs() {
        attachmentImportGeneration = UUID()
        for job in attachmentJobs.values { job.cancel() }
        attachmentJobs.removeAll()
    }
}

// MARK: - Tool permission gate

struct PermissionSheet: View {
    let request: MCPModel.PermissionRequest
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Allow tool call?", systemImage: "wrench.and.screwdriver")
                .font(.title3.weight(.semibold))
            Text("\(request.server) wants to run **\(request.tool)**")
            if let penName = request.penName {
                Text(
                    request.tool == "pen_run_command"
                        ? "Command execution in \(penName)" : "File creation and edits in \(penName)"
                )
                .font(.callout.weight(.medium))
                Text(
                    request.tool == "pen_run_command"
                        ? "Allow Once runs this command. The menu can whitelist this executable with any arguments for this chat or Pen, with the displayed network access. Child commands remain confined."
                        : request.allowsPenScopes
                            ? "Allow Once approves this change. The menu can allow future file creation and edits for this chat or all chats in this Pen."
                            : "Allow Once approves this change. Remembered permissions are currently unavailable."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            JSONEditorView(
                text: .constant(request.arguments),
                tokens: model.theme.tokens,
                isEditable: false
            )
            .frame(maxWidth: .infinity)
            .frame(height: 140)
            .clipped()
            .accessibilityLabel("Tool call arguments")
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Deny") {
                    model.mcp.resolvePermission(.deny, requestID: request.id)
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if request.allowsAlways {
                    Button("Always Allow") {
                        model.mcp.resolvePermission(.alwaysAllow, requestID: request.id)
                    }
                }
                if request.allowsPenScopes {
                    Menu {
                        Button("Allow for This Chat") {
                            model.mcp.resolvePermission(.allowChat, requestID: request.id)
                        }
                        Button("Always Allow for This Pen") {
                            model.mcp.resolvePermission(.allowPen, requestID: request.id)
                        }
                    } label: {
                        Text("Allow Once")
                    } primaryAction: {
                        model.mcp.resolvePermission(.allowOnce, requestID: request.id)
                    }
                    .menuStyle(.button)
                    .keyboardShortcut(.defaultAction)
                    .help("Allow this operation, or choose a chat or Pen permission from the menu")
                } else {
                    Button("Allow Once") {
                        model.mcp.resolvePermission(.allowOnce, requestID: request.id)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled()
    }
}

// MARK: - Engine banner (offline / auth)

struct EngineConnectingBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            GoatLoadingIndicator().controlSize(.small)
            Text("Checking engine and model...")
                .font(.callout)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

struct EngineBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 10) {
            if model.activeEngineProfile == nil {
                Image(systemName: "cpu").foregroundStyle(model.theme.tokens.tint)
            } else {
                GoatieView(pose: model.health == .authRequired ? .shrug : .sleeping, size: 34)
            }
            Text(bannerText).font(.callout)
            Spacer()
            if model.activeEngineProfile == nil {
                Button("Set Up Engine", action: showEngineSettings)
            } else {
                if model.health == .authRequired {
                    Button("Add Key…", action: showEngineSettings)
                } else if model.engineAppURL != nil {
                    Button("Wake \(model.enginePreset.name)") { model.openEngineApp() }
                } else {
                    Button("Engine Settings…", action: showEngineSettings)
                }
                Button("Retry") { Task { await model.discover() } }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func showEngineSettings() {
        model.settingsTab = .engine
        openSettings()
    }

    private var bannerText: String {
        if model.activeEngineProfile == nil { return "Connect an engine to start chatting." }
        return switch model.health {
        case .authRequired: "The engine requires an API key."
        case .offline(let reason): "Engine unavailable: \(reason)"
        case .ok: ""
        }
    }
}

// MARK: - Composer (model+effort capsule lives bottom-right, Claude Desktop style)

struct Composer: View {
    @Bindable var session: ChatSession
    @Binding var draft: String
    @Binding var pending: [PendingAttachment]
    var focused: Binding<Bool>
    let canSend: Bool
    let isStreaming: Bool
    let attachmentsLoading: Bool
    var attachmentFailure: String? = nil
    let onSend: () -> Void
    let onStop: () -> Void
    let onAttach: (Data) -> Void
    let onImportFiles: ([URL]) -> Void
    var canLead = false
    var submittingLead = false
    var pendingLeadCount = 0
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var showImporter = false
    @State private var showModelMenu = false
    @State private var skillCatalog = SkillCatalog(skills: [], issues: [])
    @State private var selectedSlashItem = (draft: "", index: 0)
    @State private var dismissedSlashDraft: String?
    @State private var composerEditorHeight: CGFloat = 30

    var body: some View {
        VStack(spacing: 6) {
            inputCard
                .overlay(alignment: .top) {
                    if showsSlashMenu {
                        ComposerSlashMenu(
                            commands: filteredCommandItems,
                            skills: filteredSkillItems,
                            issueCount: skillCatalog.issues.count,
                            selectedIndex: Binding(get: { slashSelection }, set: { slashSelection = $0 }),
                            onSelect: selectSlashItem
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: slashMenuHeight)
                        .offset(y: -slashMenuHeight - 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(20)
                    }
                }
                .zIndex(showsSlashMenu ? 20 : 0)
            HStack(spacing: 12) {
                if pendingLeadCount > 0 {
                    Text("Lead queued • applies after the current action")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ComposerStatus(session: session)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                ModelEffortControl(session: session, showMenu: $showModelMenu)
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 16)
        .padding(.top, 4)
        .fileImporter(
            isPresented: $showImporter, allowedContentTypes: ChatAttachmentTypes.allowedContentTypes,
            allowsMultipleSelection: true
        ) {
            result in
            guard case .success(let urls) = result else { return }
            onImportFiles(urls)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            onImportFiles(urls)
            return true
        }
        .task(id: SkillCatalogContext(chatID: session.id, penID: session.projectID)) {
            skillCatalog = await model.skillCatalog(for: session)
        }
    }

    // A changed draft starts at the first result without another state update during layout.
    private var slashSelection: Int {
        get { selectedSlashItem.draft == draft ? selectedSlashItem.index : 0 }
        nonmutating set { selectedSlashItem = (draft, newValue) }
    }

    private var inputCard: some View {
        VStack(spacing: 8) {
            if !pending.isEmpty {
                attachmentsRow
            }
            if let attachmentFailure {
                Label(attachmentFailure, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            composerContent

            HStack(spacing: 10) {
                Menu {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Add files or photos", systemImage: "photo.on.rectangle")
                    }
                    Divider()
                    Menu {
                        if skillItems.isEmpty {
                            Text("No additional skills available")
                        } else {
                            ForEach(skillItems) { item in
                                Button {
                                    selectSlashItem(item)
                                } label: {
                                    Label(item.title, systemImage: item.symbol)
                                }
                            }
                        }
                    } label: {
                        Label("Skills", systemImage: "shippingbox")
                    }
                    Button {
                        draft = "/"
                        dismissedSlashDraft = nil
                        slashSelection = 0
                        focused.wrappedValue = true
                    } label: {
                        Label("Commands", systemImage: "slash.circle")
                    }
                    Divider()
                    Menu {
                        if activeMCPConfigs.isEmpty {
                            Text("No active servers")
                        } else {
                            ForEach(activeMCPConfigs) { config in
                                Toggle(
                                    config.name,
                                    isOn: Binding(
                                        get: { session.isMCPServerEnabled(config.name) },
                                        set: { enabled in
                                            session.setMCPServer(
                                                config.name,
                                                enabled: enabled,
                                                activeServerNames: activeMCPConfigs.map(\.name))
                                            model.persistMeta(session)
                                        }))
                            }
                        }
                    } label: {
                        Label("MCP servers", systemImage: "wrench.and.screwdriver")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .help("Attach files, choose skills, or toggle MCP servers")
                if let pen = model.pens.first(where: { $0.id == session.projectID }), pen.workspace != nil {
                    PenFilePermissionControl(pen: pen, chatID: session.id, compact: true)
                }
                if attachmentsLoading {
                    GoatLoadingIndicator().controlSize(.small).help("Preparing attachments")
                }
                if pending.contains(where: { $0.imageData != nil }) && !activeModelLooksVision {
                    Label("This model may not support images", systemImage: "eye.trianglebadge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                if isStreaming {
                    if canLead {
                        Button(action: onSend) {
                            Label(submittingLead ? "Saving…" : "Lead", systemImage: "arrow.turn.up.right")
                        }
                        .disabled(
                            submittingLead || attachmentsLoading || !pending.isEmpty
                                || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                        .help(
                            "Queue guidance after the current action finishes. Pending approvals stay open. Use Stop to interrupt. Attachments can be sent after the turn finishes."
                        )
                    }
                    Button(action: onStop) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(model.theme.tokens.accentGradient, in: Circle())
                            .shadow(color: model.theme.tokens.glow.opacity(0.55), radius: 6)
                    }
                    .buttonStyle(.plain)
                    .help("Stop (Esc / ⌘.)")
                    .keyboardShortcut(.escape, modifiers: [])
                } else {
                    let empty =
                        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && pending.isEmpty
                    SendButton(
                        enabled: canSend && !attachmentsLoading && !empty,
                        gradient: model.theme.tokens.accentGradient,
                        glow: model.theme.tokens.glow,
                        animates: model.animationsEnabled && scenePhase == .active,
                        action: onSend
                    )
                }
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .overlay {
            if isStreaming {
                NeonRing(
                    tokens: model.theme.tokens,
                    active: true,
                    cornerRadius: 20,
                    animates: model.animationsEnabled && scenePhase == .active)
            } else if focused.wrappedValue {
                FeatheredRing(tint: model.theme.tokens.tint, cornerRadius: 20, feather: 6)
            } else {
                NeonRing(tokens: model.theme.tokens, active: false, cornerRadius: 20)
            }
        }
        .animation(.easeOut(duration: 0.2), value: focused.wrappedValue)
    }

    private var composerContent: some View {
        ZStack(alignment: .topLeading) {
            if draft.isEmpty {
                Text(canLead ? "Lead the agent…" : "Baa…")
                    .font(Font(model.chatNSFont))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 7)
                    .padding(.top, 7)
                    .allowsHitTesting(false)
            }
            MarkdownComposerEditor(
                fontID: model.effectiveChatFontID,
                codeFontID: model.effectiveCodeFontID,
                codeFontSize: model.codeFontSize,
                text: Binding(
                    get: { draft },
                    set: { value in
                        guard value != draft else { return }
                        draft = value
                        selectedSlashItem = (value, 0)
                        dismissedSlashDraft = nil
                    }),
                height: $composerEditorHeight,
                focused: focused,
                isEditable: true,
                fontSize: model.chatFontSize,
                tint: model.theme.tokens.tint,
                onSubmit: {
                    guard !activateSelectedSlashItem() else { return }
                    if !attachmentsLoading && !submittingLead
                        && (canSend || (canLead && pending.isEmpty))
                    {
                        onSend()
                    }
                },
                onMoveSelection: moveSlashSelection,
                onCancel: {
                    guard showsSlashMenu else { return false }
                    dismissedSlashDraft = draft
                    return true
                },
                onPasteFiles: onImportFiles,
                onPasteImage: onAttach)
        }
        .frame(height: composerEditorHeight)
        .padding(.horizontal, 1)
    }

    private var attachmentsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pending) { attachment in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let preview = attachment.preview {
                                Image(decorative: preview, scale: 1)
                                    .resizable().aspectRatio(contentMode: .fill)
                            } else {
                                VStack(spacing: 3) {
                                    Image(systemName: "doc.text").font(.title3)
                                    Text(attachment.fileExtension.isEmpty ? "TXT" : attachment.fileExtension)
                                        .font(.caption2.weight(.semibold)).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(model.theme.tokens.surface)
                            }
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .help(attachment.name)
                        .accessibilityLabel(attachment.name)
                        Button {
                            pending.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .help("Remove \(attachment.name)")
                        .accessibilityLabel("Remove \(attachment.name)")
                        .padding(2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activeModelLooksVision: Bool {
        let id = model.resolvedModelID(for: session)
        guard let ref = id.flatMap({ id in model.models.first(where: { $0.id == id }) }) else {
            return false
        }
        switch ref.capabilities.vision.support {
        case .supported: return true
        case .unsupported: return false
        case .unknown: return ref.looksVisionCapable
        }
    }

    private var slashQuery: String? {
        SkillCommand.menuQuery(in: draft)
    }

    private var activeMCPConfigs: [MCPServerConfig] {
        model.mcp.configs.filter { !$0.disabled }.sorted { $0.name < $1.name }
    }

    private var commandItems: [ComposerSlashItem] {
        var commands: [ComposerCommand] = [.handoff, .newChat, .model, .effort, .activity]
        if session.messages.contains(where: { $0.role == .assistant && $0.complete }) {
            commands.insert(.regenerate, at: 3)
            if model.memory.isEnabled(forProjectID: session.projectID) {
                commands.insert(.remember, at: 4)
            }
        }
        return commands.map(ComposerSlashItem.command)
    }

    private var skillItems: [ComposerSlashItem] {
        guard activeModelCanLoadSkills else { return [] }
        return skillCatalog.skills
            .filter {
                $0.invocation.userInvocable && $0.name != ComposerCommand.handoff.slashName
            }
            .map(ComposerSlashItem.skill)
    }

    private var filteredCommandItems: [ComposerSlashItem] {
        guard let query = slashQuery else { return [] }
        return commandItems.filter { $0.matches(query) }
    }

    private var filteredSkillItems: [ComposerSlashItem] {
        guard let query = slashQuery else { return [] }
        return skillItems.filter { $0.matches(query) }
    }

    private var filteredSlashItems: [ComposerSlashItem] {
        filteredCommandItems + filteredSkillItems
    }

    private var showsSlashMenu: Bool {
        slashQuery != nil && dismissedSlashDraft != draft
            && !filteredSlashItems.isEmpty
    }

    private var slashMenuHeight: CGFloat {
        let rows = filteredSlashItems.count
        let sections = (filteredCommandItems.isEmpty ? 0 : 1) + (filteredSkillItems.isEmpty ? 0 : 1)
        let divider = !filteredCommandItems.isEmpty && !filteredSkillItems.isEmpty ? 12 : 0
        let issues = skillCatalog.issues.isEmpty ? 0 : 38
        let estimated = CGFloat(rows * 38 + sections * 27 + divider + issues + 16)
        return min(390, max(72, estimated))
    }

    private var activeModelCanLoadSkills: Bool {
        let id = model.resolvedModelID(for: session)
        return id.flatMap { selected in model.models.first(where: { $0.id == selected }) }
            .map { $0.capabilities.tools.support != .unsupported } ?? true
    }

    @discardableResult
    private func moveSlashSelection(by offset: Int) -> Bool {
        let items = filteredSlashItems
        guard showsSlashMenu, !items.isEmpty else { return false }
        guard
            let next = ComposerSlashSelection.moved(
                from: slashSelection, by: offset, itemCount: items.count)
        else { return false }
        slashSelection = next
        return true
    }

    @discardableResult
    private func activateSelectedSlashItem() -> Bool {
        let items = filteredSlashItems
        guard showsSlashMenu, items.indices.contains(slashSelection) else { return false }
        selectSlashItem(items[slashSelection])
        return true
    }

    private func selectSlashItem(_ item: ComposerSlashItem) {
        switch item.action {
        case .skill(let name):
            draft = "/\(name) "
            focused.wrappedValue = true
        case .command(let command):
            execute(command)
        }
    }

    private func execute(_ command: ComposerCommand) {
        dismissedSlashDraft = draft
        switch command {
        case .handoff:
            guard canSend, !attachmentsLoading else { return }
            draft = "/handoff"
            onSend()
        case .newChat:
            draft = ""
            Task { await model.beginNewChat() }
        case .regenerate:
            draft = ""
            Task { await model.regenerate() }
        case .remember:
            if let message = session.messages.last(where: {
                $0.role == .assistant && $0.complete && !$0.text.isEmpty
            }) {
                model.remember(message)
            }
            draft = ""
        case .model, .effort:
            draft = ""
            showModelMenu = true
        case .activity:
            withAnimation(.easeOut(duration: 0.18)) { model.showActivityLog.toggle() }
            draft = ""
        }
    }
}

private struct SkillCatalogContext: Hashable {
    let chatID: UUID
    let penID: UUID?
}

// MARK: - The capsule: "Qwen3-8B-4bit · Trot ⌄"

struct ModelEffortControl: View {
    @Bindable var session: ChatSession
    @Binding var showMenu: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            showMenu.toggle()
        } label: {
            HStack(spacing: 6) {
                if model.modelCapabilitiesLoading,
                    model.capabilityProbeModelID == activeModelID
                {
                    GoatLoadingIndicator()
                        .controlSize(.mini)
                }
                Text(activeModelName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(session.effort.label)
                    .foregroundStyle(session.effort.presentationColor(in: model.theme))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 12))
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Model + effort - \(session.effort.blurb) (⌘1-4)")
        .popover(isPresented: $showMenu, arrowEdge: .bottom) {
            menuContent.frame(width: 290)
        }
    }

    private var menuContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Model")
            if model.models.isEmpty {
                plainRow(model.activeEngineProfile == nil ? "Set Up Engine…" : "No models - refresh connection") {
                    showMenu = false
                    if model.activeEngineProfile == nil {
                        model.settingsTab = .engine
                        openSettings()
                    } else {
                        Task { await model.discover() }
                    }
                }
            }
            ForEach(model.models) { ref in
                twoLineRow(
                    title: ref.displayName,
                    subtitle: subtitle(for: ref),
                    icon: nil,
                    selected: ref.id == activeModelID
                ) {
                    model.selectModel(ref.id, in: session)
                    showMenu = false
                }
            }

            Divider().padding(.vertical, 4)
            sectionLabel("Effort")
            ForEach(Effort.allCases) { effort in
                EffortRow(effort: effort, selected: session.effort == effort) {
                    session.effort = effort
                    model.persistMeta(session)
                    showMenu = false
                }
            }

            Divider().padding(.vertical, 4)
            if model.engineAppURL != nil {
                plainRow(model.enginePreset.appLabel ?? "Manage Models…") {
                    showMenu = false
                    model.openEngineApp()
                }
            }
            if model.activeEngineProfile != nil {
                plainRow("Refresh Models") {
                    showMenu = false
                    Task { await model.refreshHealth() }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
    }

    private func twoLineRow(
        title: String, subtitle: String, icon: Goatie?, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if model.presentation.isEnabled, let icon {
                    GoatieView(pose: icon, size: 30)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(model.theme.tokens.tint)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func plainRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func subtitle(for ref: ModelRef) -> String {
        let org = ref.id.contains("/") ? String(ref.id.split(separator: "/")[0]) : "local"
        var traits: [String] = []
        if ref.isCoderFocused { traits.append("Coder") }
        let vision =
            switch ref.capabilities.vision.support {
            case .supported: true
            case .unsupported: false
            case .unknown: ref.looksVisionCapable
            }
        if vision { traits.append("Vision") }
        traits.append(org)
        return traits.joined(separator: " · ")
    }

    private var activeModelID: String? { model.resolvedModelID(for: session) }

    private var activeModelName: String {
        activeModelID.flatMap { id in model.models.first(where: { $0.id == id })?.displayName }
            ?? activeModelID.map { ModelRef(id: $0).displayName }
            ?? "No model"
    }
}
