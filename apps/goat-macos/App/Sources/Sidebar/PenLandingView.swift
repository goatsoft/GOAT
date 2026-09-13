import AppKit
import Bleet
import Caprine
import Herd
import Memory
import Pens
import SwiftUI
import UniformTypeIdentifiers

private struct PenLandingDiskSnapshot: Sendable {
    let memoryFolder: URL
    let memoryNotes: [String]
    let penFolder: URL?
}

private struct PenMemoryLoadKey: Hashable {
    let penID: UUID
    let providerID: MemoryProviderID
    let enabled: Bool
    let configurationReady: Bool
    let connectionIdentity: String
}

private actor PenLandingFileWorker {
    static let shared = PenLandingFileWorker()

    func snapshot(for penID: String) -> PenLandingDiskSnapshot {
        let memoryFolder = memoryFolder(for: penID)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: memoryFolder.path)) ?? []
        let notes = files.filter { $0.hasSuffix(".md") }.sorted()
        return PenLandingDiskSnapshot(
            memoryFolder: memoryFolder,
            memoryNotes: notes,
            penFolder: try? PenStore.folder(for: penID))
    }

    func createMemoryFolder(for penID: String) -> URL? {
        guard !Task.isCancelled else { return nil }
        let folder = memoryFolder(for: penID)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        } catch {
            return nil
        }
    }

    func penFolder(for penID: String) -> URL? {
        guard !Task.isCancelled else { return nil }
        return try? PenStore.folder(for: penID)
    }

    func fileReferences(for urls: [URL]) -> [PenFileRef] {
        var references: [PenFileRef] = []
        references.reserveCapacity(urls.count)
        for url in urls {
            guard !Task.isCancelled else { break }
            references.append(
                PenFileRef(
                    name: url.lastPathComponent,
                    path: url.path,
                    bookmark: try? url.bookmarkData(options: .withSecurityScope)))
        }
        return references
    }

    private func memoryFolder(for penID: String) -> URL {
        guard let folder = try? PenStore.folder(for: penID) else { return Home.memoryDir }
        return folder.appendingPathComponent("memory", isDirectory: true)
    }
}

/// The Pen's landing page - its colour/emoji header, instructions (README) editor, the chats
/// in it, and referenced files (pointers, not copies). Shown in the detail pane when a Pen
/// is selected in the sidebar.
struct PenLandingView: View {
    @Bindable var pen: Pen
    @Environment(AppModel.self) private var model

    @State private var selectedTab = "Workspace"
    @State private var memoryGraphError: String?
    @State private var instructions = ""
    @State private var showingInstructionsEditor = false
    @State private var loadedID: UUID?
    @State private var saveTask: Task<Void, Never>?
    @State private var fileTask: Task<Void, Never>?
    @State private var memoryFolder: URL?
    @State private var memoryNotes: [String] = []
    @State private var memoryEntries: [MemoryBrowserEntry] = []
    @State private var memoryGraph = MemoryGraphSnapshot.empty
    @State private var memoryDocument: MemoryBrowserDocument?
    @State private var memoryError: String?
    @State private var memoryDocumentError: String?
    @State private var memoryMode = MemoryBrowserMode.pages
    @State private var penFolder: URL?
    @State private var gitWorkspaceProbe: GitWorkspaceProbe?
    @State private var workspaceError: String?
    @State private var workspaceTileHovered = false
    @State private var headerFolderHovered = false
    @State private var diskStateLoading = true
    @State private var prompt = ""
    @State private var promptFocused = false
    @State private var launchSession: ChatSession?
    @State private var submittingPrompt = false
    @State private var submissionError: String?
    @State private var pendingAttachments: [PendingAttachment] = []
    @State private var attachmentJobs: [UUID: Task<Void, Never>] = [:]

    private var tint: Color { Color(pen.color) }
    private var memoryLoadKey: PenMemoryLoadKey {
        PenMemoryLoadKey(
            penID: pen.id,
            providerID: model.memory.providerID(forProjectID: pen.id),
            enabled: model.memory.isEnabled(forProjectID: pen.id),
            configurationReady: model.memory.isConfigurationReady,
            connectionIdentity: model.memory.hindsightConnection(forProjectID: pen.id).map {
                "\($0.apiURL)|\($0.bankID)"
            } ?? "")
    }
    private var instructionsSummary: String {
        guard !instructions.isEmpty else { return "Add a README-style brief for every chat in this Pen." }
        let lines = instructions.split(whereSeparator: { $0.isNewline }).count
        return "\(lines) \(lines == 1 ? "line" : "lines") · included with every chat"
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scroll in
                ScrollView {
                    Group {
                        if geometry.size.width >= 980 {
                            HStack(alignment: .top, spacing: 28) {
                                mainContent
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                PenChatsInspector(pen: pen, isSideInspector: true)
                                    .frame(width: 300, alignment: .top)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            VStack(alignment: .leading, spacing: 22) {
                                mainContent
                                Divider().padding(.vertical, 2)
                                PenChatsInspector(pen: pen, isSideInspector: false)
                            }
                        }
                    }
                    .padding(28)
                }
                .task(id: model.penComposerFocusID) {
                    guard model.penComposerFocusID == pen.id else { return }
                    await Task.yield()
                    guard !Task.isCancelled, model.selectedPenID == pen.id else { return }
                    scroll.scrollTo("pen-composer", anchor: .top)
                    promptFocused = true
                    model.penComposerFocusID = nil
                }
            }
        }
        .background(
            LinearGradient(colors: [tint.opacity(0.10), .clear], startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.beginNewChat(in: pen)
                } label: {
                    ChromeToggleIcon(systemImage: "plus.bubble")
                }
                .buttonStyle(.plain)
                .help("New Chat")
                .accessibilityLabel("New Chat")
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .sheet(isPresented: $showingInstructionsEditor) {
            PenInstructionsEditor(
                penName: pen.name,
                instructions: $instructions,
                tint: tint,
                onSave: {
                    pen.instructions = instructions
                    Task { await persist() }
                })
        }
        .sheet(isPresented: memoryDocumentPresented) {
            if let memoryDocument {
                MemoryDocumentPreview(document: memoryDocument, projectID: pen.id)
            }
        }
        .alert("Couldn’t open memory document", isPresented: memoryDocumentErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(memoryDocumentError ?? "Unknown error")
        }
        .onAppear(perform: loadIfNeeded)
        .onChange(of: pen.id) { _, _ in
            fileTask?.cancel()
            fileTask = nil
            selectedTab = "Workspace"
            loadedID = nil
            memoryFolder = nil
            memoryNotes = []
            memoryEntries = []
            memoryGraph = .empty
            memoryDocument = nil
            memoryError = nil
            memoryDocumentError = nil
            penFolder = nil
            gitWorkspaceProbe = nil
            workspaceError = nil
            diskStateLoading = true
            loadIfNeeded()
        }
        .task(id: memoryLoadKey) {
            let request = memoryLoadKey
            await loadDiskState(for: request)
        }
        .task(id: pen.workspace?.path) { await reloadGitStatus() }
        .onDisappear {
            saveTask?.cancel()
            fileTask?.cancel()
            Task { await persist() }
        }
    }

    private func persist() async {
        await model.savePen(
            existing: pen, name: pen.name, emoji: pen.emoji,
            instructions: instructions, color: pen.color, files: pen.files)
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            startChatSection.id("pen-composer")
            Picker("Pen details", selection: $selectedTab) {
                Label("Workspace", systemImage: "folder").tag("Workspace")
                Label("Memory", systemImage: "brain").tag("Memory")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .accessibilityIdentifier("pen-detail-tabs")
            if selectedTab == "Workspace" {
                workspaceSection.penPanel(tokens: model.theme.tokens)
                instructionsSection.penPanel(tokens: model.theme.tokens)
                workspaceFilesSection.penPanel(tokens: model.theme.tokens)
                PenSkillsSection(penID: pen.id, penFolder: penFolder, tint: tint)
                    .penPanel(tokens: model.theme.tokens)
                PenFilePermissionControl(pen: pen)
                    .penPanel(tokens: model.theme.tokens)
                PenCommandPermissionControl(pen: pen)
                    .penPanel(tokens: model.theme.tokens)
            } else {
                memorySection.penPanel(tokens: model.theme.tokens)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(pen.emoji)
                .font(.system(size: 48))
                .frame(width: 76, height: 76)
                .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 21))
            VStack(alignment: .leading, spacing: 4) {
                Text(pen.name)
                    .font(.system(size: 28, weight: .bold))
                Text(
                    "\(model.chats(in: pen).count) chats · created \(pen.createdAt.formatted(date: .abbreviated, time: .omitted))"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                if let workspace = pen.workspace {
                    HStack(spacing: 8) {
                        Button {
                            openWorkspace()
                        } label: {
                            Label(workspace.path, systemImage: "folder")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if let gitWorkspaceProbe {
                            GitWorkspaceStatusControl(probe: gitWorkspaceProbe)
                        }
                    }
                } else {
                    Label("No project folder yet", systemImage: "folder.badge.questionmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Button("Edit Pen", systemImage: "pencil") { model.editingPen = pen }
                    .buttonStyle(SecondaryChipButtonStyle())
                Button {
                    if pen.workspace != nil { openWorkspace() } else { openFolder() }
                } label: {
                    Text(pen.workspace != nil ? "Open Project Folder" : "Open GOAT Folder")
                        .font(.caption)
                        .foregroundStyle(headerFolderHovered ? model.theme.tokens.ink : model.theme.tokens.muted)
                        .frame(minHeight: InterfaceMetrics.controlHitArea)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { headerFolderHovered = $0 }
            }
        }
    }

    // MARK: Workspace (Herd)

    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Folder", systemImage: "folder.badge.gearshape")
                Spacer()
                if pen.workspace != nil {
                    Button("Refresh Git", systemImage: "arrow.clockwise") {
                        Task { await reloadGitStatus() }
                    }
                    .buttonStyle(SecondaryChipButtonStyle())
                    .font(.caption)
                    Button("Change…") { chooseWorkspace() }
                        .buttonStyle(SecondaryChipButtonStyle())
                        .font(.caption)
                } else {
                    Button("Use Existing…") { chooseWorkspace() }
                        .buttonStyle(SecondaryChipButtonStyle())
                        .font(.caption)
                    Button("Create Folder") { createWorkspace() }
                        .buttonStyle(SecondaryChipButtonStyle())
                        .font(.caption)
                }
            }

            if let workspace = pen.workspace {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workspace.path)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(
                            workspace.wasCreatedByGOAT
                                ? "Created by GOAT in your Herd location."
                                : "Bound to an existing user-owned folder."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        openWorkspace()
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(workspaceTileHovered ? model.theme.tokens.ink : model.theme.tokens.muted)
                            .frame(width: InterfaceMetrics.controlHitArea, height: InterfaceMetrics.controlHitArea)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open project folder")
                    .accessibilityLabel("Open project folder")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.25)))
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .onHover { workspaceTileHovered = $0 }

                if let gitWorkspaceProbe {
                    GitWorkspaceDetail(probe: gitWorkspaceProbe)
                } else {
                    GoatLoadingIndicator("Reading Git status…")
                        .controlSize(.small)
                        .font(.caption)
                }
            } else {
                Text(
                    "Bind a project folder when this Pen needs a real workspace. It stays yours. GOAT keeps its instructions and memory in a separate sidecar."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let workspaceError {
                Label(workspaceError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

        }
    }

    // MARK: Instructions (README.md)

    private var startChatSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Start in \(pen.name)", systemImage: "bubble.left.and.bubble.right")
            Text(
                "This creates a chat in this Pen using your current model and effort, then sends it straight to the Paddock."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if let launchSession {
                Composer(
                    session: launchSession,
                    draft: $prompt,
                    pending: $pendingAttachments,
                    focused: $promptFocused,
                    canSend: ChatView.permitsSend(
                        localStateReady: model.startupPhase.hasLocalState,
                        engineIsHealthy: model.health.isOK,
                        messagesLoaded: true,
                        modelCanGenerate: model.canGenerateWithSelectedModel(for: launchSession),
                        isBusy: model.activeTurnSessionID != nil || model.engineTransitioning
                            || model.modelCapabilitiesLoading),
                    isStreaming: false,
                    attachmentsLoading: !attachmentJobs.isEmpty || submittingPrompt || model.filePermissions.isUpdating,
                    onSend: submitPrompt,
                    onStop: {},
                    onAttach: addAttachment,
                    onImportFiles: importAttachments
                )
                .padding(.horizontal, -22)
                .padding(.bottom, -16)
                .disabled(submittingPrompt)
            } else {
                GoatLoadingIndicator().controlSize(.small)
            }
            if let submissionError {
                Label(submissionError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16).strokeBorder(tint.opacity(0.35))
        }
    }

    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Instructions", systemImage: "doc.text.fill")
                Spacer()
                Button(instructions.isEmpty ? "Add Instructions…" : "Edit…") {
                    showingInstructionsEditor = true
                }
                .buttonStyle(SecondaryChipButtonStyle())
                .font(.caption)
            }
            Text("A README-style brief is included with every chat in this Pen.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if instructions.isEmpty {
                Text("No instructions yet.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            } else {
                Button {
                    showingInstructionsEditor = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text.fill")
                            .foregroundStyle(tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(instructionsSummary)
                                .font(.system(size: 13, weight: .medium))
                            Text("Click to edit this brief.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.25)))
                }
                .buttonStyle(.plain)
                .help("Edit instructions")
            }
        }
    }

    // MARK: Memory (scoped wiki - M6)

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    sectionTitle("Pen memory", systemImage: "brain")
                    Text("Recent context saved for this Pen’s chats.")
                        .font(.caption).foregroundStyle(model.theme.tokens.muted)
                }
                Spacer()
                Button {
                    Task { await loadDiskState(for: memoryLoadKey) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(SecondaryChipButtonStyle())
                .help("Refresh Pen memory")
                .disabled(diskStateLoading)
            }
            if model.memory.isConfigurationReady { penMemoryControls }
            if let provider = model.memory.provider(forProjectID: pen.id), provider.kind == .hindsight {
                if model.memory.builtInSettings.hindsightEnabled {
                    hindsightMemory(provider)
                } else {
                    Text("Hindsight is disabled in Extensions. Saved Pen memory is preserved.").font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Open Memory Folder", systemImage: "folder") { openMemoryFolder() }
                    .buttonStyle(SecondaryChipButtonStyle()).font(.caption)
            }
            if model.memory.supportsMemoryGraph(forProjectID: pen.id) {
                MemoryBrowserModePicker(
                    selection: $memoryMode,
                    includesInsights: model.memory.usesLLMWiki(forProjectID: pen.id),
                    recordsLabel: model.memory.isUsingHindsight(forProjectID: pen.id)
                )
                .frame(maxWidth: 300)
            }
            if memoryMode == .map && model.memory.isEnabled(forProjectID: pen.id) {
                if let memoryGraphError {
                    Label(memoryGraphError, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(model.theme.tokens.muted)
                } else if diskStateLoading {
                    GoatLoadingIndicator("Loading memory map…")
                } else {
                    MemoryGraphView(
                        graph: memoryGraph, tint: model.theme.tokens.tint,
                        onSelect: { id in Task { await readMemory(id) } }
                    )
                    .frame(height: 360)
                }
            } else if memoryMode == .insights && model.memory.usesLLMWiki(forProjectID: pen.id) {
                MemoryGraphInsightsView(graph: memoryGraph, tint: model.theme.tokens.tint, maximumPages: 10)
            } else {
                memoryList
            }
        }
    }

    private var penMemoryControls: some View {
        HStack(spacing: 12) {
            Toggle(
                "Enable memory for this Pen",
                isOn: Binding(
                    get: { model.memory.penMemoryIsEnabled(forProjectID: pen.id) },
                    set: { enabled in
                        Task {
                            await model.memory.setEnabled(
                                enabled,
                                forProjectID: pen.id,
                                projectName: pen.name)
                        }
                    })
            )
            .toggleStyle(.switch)
            .font(.caption)
            Label(
                model.memory.providerName(forProjectID: pen.id),
                systemImage: "internaldrive"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .disabled(
            !model.memory.isEnabled
                || (!model.memory.builtInSettings.hindsightEnabled
                    && model.memory.provider(forProjectID: pen.id)?.kind == .hindsight)
        )
        .opacity(model.memory.isEnabled ? 1 : 0.5)
    }

    private var memoryList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.memory.isEnabled(forProjectID: pen.id) {
                Text("Enable memory to browse this Pen's store.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else if diskStateLoading {
                GoatLoadingIndicator().controlSize(.small).padding(.vertical, 4)
            } else if let memoryError {
                Label(memoryError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.vertical, 4)
            } else if memoryEntries.isEmpty {
                Text("No notes yet.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                MemoryRecordList(entries: memoryEntries, tint: model.theme.tokens.tint) { id in
                    Task { await readMemory(id) }
                }
                Text("Showing up to \(MemoryModel.recentRecordLimit) recent records.")
                    .font(.caption).foregroundStyle(model.theme.tokens.muted)
            }
        }
    }

    private func hindsightMemory(_ provider: MemoryProviderRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Hindsight", systemImage: "brain.head.profile")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let url = model.memory.hindsightBankURL(forProjectID: pen.id) {
                    Link("Open in Hindsight", destination: url)
                        .judasLinks().font(.caption)
                        .buttonStyle(SecondaryChipButtonStyle())
                }
            }
            if let connection = model.memory.hindsightConnection(forProjectID: pen.id) {
                Text(connection.bankID).font(.caption.monospaced())
                    .foregroundStyle(model.theme.tokens.muted).textSelection(.enabled)
            }
            Text("Explore the full history and graph in Hindsight.")
                .font(.caption).foregroundStyle(model.theme.tokens.muted)
            if model.memory.penMemoryIsEnabled(forProjectID: pen.id),
                let reason = model.memory.unavailableProviderReason(provider.id)
            {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(model.theme.tokens.muted)
            }
        }
        .padding(12)
        .background(model.theme.tokens.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Workspace files (references)

    private var workspaceFilesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Additional files & folders", systemImage: "paperclip")
                Spacer()
                Button("Add Files…", systemImage: "plus") { addFiles() }
                    .buttonStyle(SecondaryChipButtonStyle())
                    .font(.caption)
            }
            Text("References outside this workspace, not copies. They do not enter chat context automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if pen.files.isEmpty {
                Text("No additional files or folders referenced yet.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            } else {
                ForEach(pen.files) { file in
                    HStack(spacing: 10) {
                        Image(systemName: "doc")
                            .foregroundStyle(tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text(file.path).font(.caption2).foregroundStyle(.tertiary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .buttonStyle(SecondaryChipButtonStyle())
                        Button(role: .destructive) {
                            removeFile(file)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(SecondaryChipButtonStyle())
                        .help("Remove file reference")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.25)))
                }
            }
        }
    }

    private func sectionTitle(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(.primary)
    }

    private func submitPrompt() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingAttachments.isEmpty, attachmentJobs.isEmpty, !submittingPrompt,
            let launchSession
        else { return }
        let attachments = pendingAttachments.compactMap(\.imageData)
        let documents = pendingAttachments.compactMap(\.document)
        submittingPrompt = true
        submissionError = nil
        Task {
            defer { submittingPrompt = false }
            let sent = await model.startChat(
                in: pen,
                with: text,
                attachments: attachments,
                documents: documents,
                draft: launchSession)
            if sent {
                self.launchSession = ChatLaunch.nextDraft(after: launchSession)
                prompt = ""
                pendingAttachments = []
            } else {
                submissionError =
                    "Chat was not started. Your draft is still here. Check the engine connection and try again."
            }
        }
    }

    private func addAttachment(_ raw: Data) {
        let jobID = UUID()
        attachmentJobs[jobID] = Task { @MainActor in
            defer { attachmentJobs.removeValue(forKey: jobID) }
            let image = await ImageFileWorker.shared.prepare(raw)
            guard !Task.isCancelled else { return }
            guard let image else {
                submissionError = "The pasted image could not be read. Choose an image no larger than 25 MB."
                return
            }
            submissionError = nil
            pendingAttachments.append(PendingAttachment(data: image.pngData, preview: image.preview))
        }
    }

    private func importAttachments(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let jobID = UUID()
        attachmentJobs[jobID] = Task { @MainActor in
            defer { attachmentJobs.removeValue(forKey: jobID) }
            let result = await ChatAttachmentImporter.shared.importFiles(urls)
            guard !Task.isCancelled else { return }
            pendingAttachments.append(
                contentsOf: result.images.map {
                    PendingAttachment(data: $0.image.pngData, preview: $0.image.preview, name: $0.name)
                })
            pendingAttachments.append(contentsOf: result.documents.map { PendingAttachment(document: $0) })
            submissionError = result.failures.isEmpty ? nil : result.failures.joined(separator: "\n")
        }
    }

    // MARK: Actions

    private func loadIfNeeded() {
        guard loadedID != pen.id else { return }
        loadedID = pen.id
        instructions = pen.instructions
        launchSession = ChatSession(
            effort: model.currentSession?.effort ?? model.defaultEffort,
            modelID: model.resolvedModelID(for: model.currentSession),
            projectID: pen.id)
    }

    private func openFolder() {
        if let dir = penFolder {
            NSWorkspace.shared.open(dir)
            return
        }
        let penID = pen.id.uuidString
        startFileTask {
            let folder = await PenLandingFileWorker.shared.penFolder(for: penID)
            guard !Task.isCancelled else { return }
            penFolder = folder
            if let folder { NSWorkspace.shared.open(folder) }
        }
    }

    private func openWorkspace() {
        guard let workspace = pen.workspace else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: workspace.path, isDirectory: true))
    }

    private func createWorkspace() {
        let name = pen.name
        let rootPath = model.herdRootPath
        startFileTask {
            do {
                let workspace = try await HerdWorkspaceFileWorker.shared.createWorkspace(
                    name: name, rootPath: rootPath)
                guard !Task.isCancelled else { return }
                if await model.setWorkspace(workspace, for: pen) {
                    workspaceError = nil
                    await reloadGitStatus()
                }
            } catch {
                workspaceError = "Couldn’t create the project folder: \(error.localizedDescription)"
            }
        }
    }

    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL =
            pen.workspace.map {
                URL(fileURLWithPath: $0.path, isDirectory: true)
            } ?? URL(fileURLWithPath: model.herdRootPath, isDirectory: true)
        GOATFileSelector.present(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            startFileTask {
                let workspace = await HerdWorkspaceFileWorker.shared.bindWorkspace(at: url)
                guard !Task.isCancelled else { return }
                if await model.setWorkspace(workspace, for: pen) {
                    workspaceError = nil
                    await reloadGitStatus()
                }
            }
        }
    }

    private func reloadGitStatus() async {
        guard let workspace = pen.workspace else {
            gitWorkspaceProbe = nil
            return
        }
        let path = workspace.path
        let probe = await GitWorkspaceWorker.shared.status(at: workspace)
        guard !Task.isCancelled, pen.workspace?.path == path else { return }
        gitWorkspaceProbe = probe
    }

    private func openMemoryFolder() {
        let penID = pen.id.uuidString
        startFileTask {
            let folder = await PenLandingFileWorker.shared.createMemoryFolder(for: penID)
            guard !Task.isCancelled else { return }
            memoryFolder = folder
            if let folder { NSWorkspace.shared.open(folder) }
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        GOATFileSelector.present(panel) { response in
            guard response == .OK else { return }
            let urls = panel.urls
            startFileTask {
                let refs = await PenLandingFileWorker.shared.fileReferences(for: urls)
                guard !Task.isCancelled else { return }
                pen.files.append(contentsOf: refs)
                await model.savePen(
                    existing: pen, name: pen.name, emoji: pen.emoji,
                    instructions: pen.instructions, color: pen.color, files: pen.files)
            }
        }
    }

    private func loadDiskState(for request: PenMemoryLoadKey) async {
        diskStateLoading = true
        memoryEntries = []
        memoryGraph = .empty
        memoryDocument = nil
        memoryGraphError = nil
        let snapshot = await PenLandingFileWorker.shared.snapshot(for: request.penID.uuidString)
        guard ownsMemoryLoad(request) else { return }
        memoryFolder = snapshot.memoryFolder
        memoryNotes = snapshot.memoryNotes
        penFolder = snapshot.penFolder
        guard request.configurationReady, request.enabled else {
            memoryEntries = []
            memoryGraph = .empty
            memoryError = nil
            diskStateLoading = false
            return
        }
        do {
            let entries = try await model.memory.recentBrowserEntries(forProjectID: request.penID)
            guard ownsMemoryLoad(request) else { return }
            memoryEntries = entries
            if model.memory.supportsMemoryGraph(forProjectID: request.penID) {
                do {
                    let graph = try await model.memory.browserGraph(forProjectID: request.penID)
                    guard ownsMemoryLoad(request) else { return }
                    memoryGraph = graph
                } catch {
                    guard ownsMemoryLoad(request) else { return }
                    memoryGraphError = "The memory map is unavailable. Recent records are still available."
                }
            } else {
                memoryMode = .pages
                memoryGraph = .empty
            }
            memoryError = nil
        } catch {
            guard ownsMemoryLoad(request) else { return }
            memoryEntries = []
            memoryGraph = .empty
            memoryError = error.localizedDescription
        }
        diskStateLoading = false
    }

    private func ownsMemoryLoad(_ request: PenMemoryLoadKey) -> Bool {
        !Task.isCancelled && memoryLoadKey == request
    }

    private func readMemory(_ id: MemoryEntryID) async {
        let request = memoryLoadKey
        do {
            let document = try await model.memory.browserDocument(id, projectID: request.penID)
            guard ownsMemoryLoad(request) else { return }
            memoryDocument = document
        } catch {
            guard ownsMemoryLoad(request) else { return }
            memoryDocumentError = error.localizedDescription
        }
    }

    private var memoryDocumentPresented: Binding<Bool> {
        Binding(get: { memoryDocument != nil }, set: { if !$0 { memoryDocument = nil } })
    }

    private var memoryDocumentErrorPresented: Binding<Bool> {
        Binding(get: { memoryDocumentError != nil }, set: { if !$0 { memoryDocumentError = nil } })
    }

    private func startFileTask(_ operation: @escaping @MainActor () async -> Void) {
        fileTask?.cancel()
        fileTask = Task { @MainActor in
            await operation()
            fileTask = nil
        }
    }

    private func removeFile(_ file: PenFileRef) {
        pen.files.removeAll { $0.id == file.id }
        Task {
            await model.savePen(
                existing: pen, name: pen.name, emoji: pen.emoji,
                instructions: pen.instructions, color: pen.color, files: pen.files)
        }
    }
}

private struct GitWorkspaceStatusControl: View {
    let probe: GitWorkspaceProbe
    @State private var showingDetails = false

    var body: some View {
        Button {
            showingDetails = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(title)
                    .lineLimit(1)
                if let summary {
                    Text(summary)
                        .monospacedDigit()
                }
            }
        }
        .buttonStyle(.plain)
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .help("Git status")
        .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
            GitWorkspaceDetail(probe: probe)
                .padding(14)
                .frame(width: 310, alignment: .leading)
        }
    }

    private var icon: String {
        switch probe {
        case .repository(let status):
            status.conflictedCount > 0 ? "exclamationmark.triangle.fill" : "arrow.triangle.branch"
        case .notRepository: "arrow.triangle.branch"
        case .unavailable, .failed: "exclamationmark.triangle.fill"
        }
    }

    private var title: String {
        switch probe {
        case .repository(let status):
            status.isDetached ? "Detached HEAD" : status.branch ?? "Git"
        case .notRepository: "Not a Git repository"
        case .unavailable: "Git unavailable"
        case .failed: "Git needs attention"
        }
    }

    private var summary: String? {
        guard case .repository(let status) = probe else { return nil }
        return GitWorkspacePresentation.changeSummary(for: status)
    }

    private var color: Color {
        switch probe {
        case .repository(let status): GitWorkspacePresentation.color(for: status)
        case .notRepository: .secondary
        case .unavailable, .failed: .orange
        }
    }
}

private struct GitWorkspaceDetail: View {
    let probe: GitWorkspaceProbe

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            switch probe {
            case .repository(let status):
                HStack(spacing: 7) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(GitWorkspacePresentation.color(for: status))
                    Text(status.isDetached ? "Detached HEAD" : status.branch ?? "Git repository")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(status.isClean ? "Clean" : "Changes")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(GitWorkspacePresentation.color(for: status))
                }
                Text(status.rootPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let summary = GitWorkspacePresentation.changeSummary(for: status) {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if status.aheadCount > 0 || status.behindCount > 0 {
                    Text(
                        "\(status.aheadCount) ahead · \(status.behindCount) behind (from local remote-tracking data)"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            case .notRepository:
                Label("This project folder is not a Git repository.", systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .unavailable(let detail):
                Label(detail, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .failed(let detail):
                Label(detail, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

private enum GitWorkspacePresentation {
    static func changeSummary(for status: GitWorkspaceStatus) -> String? {
        var parts: [String] = []
        if status.conflictedCount > 0 { parts.append("\(status.conflictedCount) conflict") }
        if status.stagedCount > 0 { parts.append("\(status.stagedCount) staged") }
        if status.modifiedCount > 0 { parts.append("\(status.modifiedCount) modified") }
        if status.untrackedCount > 0 { parts.append("\(status.untrackedCount) untracked") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func color(for status: GitWorkspaceStatus) -> Color {
        if status.conflictedCount > 0 { return .red }
        if status.isClean { return .green }
        return .orange
    }
}

private struct PenChatsInspector: View {
    @Bindable var pen: Pen
    let isSideInspector: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        if isSideInspector {
            content
                .padding(16)
                .background(.ultraThinMaterial.opacity(0.35))
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Recent chats", systemImage: "bubble.left.and.bubble.right")
                .font(.headline)
            if model.chats(in: pen).isEmpty {
                Label("No chats yet", systemImage: "bubble.left")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(model.chats(in: pen)) { chat in
                            PenChatCard(chat: chat)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

private struct PenChatCard: View {
    let chat: ChatSession
    @Environment(AppModel.self) private var model
    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var renameDraft = ""

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Group {
                if isRenaming {
                    VStack(alignment: .leading, spacing: 4) {
                        InlineRenameField(
                            text: $renameDraft,
                            font: .systemFont(ofSize: 14),
                            onCommit: commitRename,
                            onCancel: { isRenaming = false }
                        )
                        .frame(height: 20)
                        Text(relativeDate(for: chat.updatedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Button {
                        model.selectedChatID = chat.id
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(chat.title).lineLimit(2)
                            Text(relativeDate(for: chat.updatedAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !isRenaming {
                Menu {
                    ChatContextActions(chat: chat, onRename: beginRename)
                } label: {
                    Text("⋮")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .opacity(isHovering ? 1 : 0)
                .accessibilityLabel("Chat actions")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 11))
        .background {
            RoundedRectangle(cornerRadius: 11)
                .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(.white.opacity(0.09))
        }
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .onHover { isHovering = $0 }
        .contextMenu {
            ChatContextActions(chat: chat, onRename: beginRename)
        }
    }

    private func beginRename() {
        renameDraft = chat.title
        isRenaming = true
    }

    private func commitRename() {
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            isRenaming = false
            return
        }
        Task {
            await model.rename(chat, to: name)
            isRenaming = false
        }
    }
}

private struct PenInstructionsEditor: View {
    let penName: String
    let initialInstructions: String
    let tint: Color
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String

    init(penName: String, instructions: Binding<String>, tint: Color, onSave: @escaping () -> Void) {
        self.penName = penName
        self.initialInstructions = instructions.wrappedValue
        self.tint = tint
        self.onSave = { value in
            instructions.wrappedValue = value
            onSave()
        }
        _draft = State(initialValue: instructions.wrappedValue)
    }

    var body: some View {
        GOATDialogShell(closeAction: { dismiss() }) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "doc.text.fill")
                        .font(.title2)
                        .foregroundStyle(tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Instructions")
                            .font(.title3.weight(.semibold))
                        Text("A README-style brief included with every chat in \(penName). Markdown is supported.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                TextEditor(text: $draft)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 280)
                    .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.25)))
                HStack {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(DialogCancelButtonStyle())
                    Spacer()
                    Button("Save Instructions") {
                        onSave(draft)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
                }
            }
            .padding(24)
            .frame(width: 620)
        }
    }
}

private func relativeDate(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
    let elapsed = max(0, now.timeIntervalSince(date))
    if elapsed < 60 { return "Just now" }
    if elapsed < 3_600 {
        let minutes = Int(elapsed / 60)
        return "\(minutes) \(minutes == 1 ? "min" : "mins") ago"
    }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    if elapsed < 86_400 {
        let hours = Int(elapsed / 3_600)
        return "\(hours) \(hours == 1 ? "hour" : "hours") ago"
    }
    if elapsed < 7 * 86_400 {
        let days = Int(elapsed / 86_400)
        return "\(days) \(days == 1 ? "day" : "days") ago"
    }
    if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
    return date.formatted(.dateTime.month(.abbreviated).day().year())
}
