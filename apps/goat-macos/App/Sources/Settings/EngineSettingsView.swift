import AppKit
import Herd
import Inference
import SwiftUI

/// The Engine tab: a managed list of engines (one active at a time), mirroring the MCP Servers
/// screen (ADR-0021). Everything per-engine (URL, key, model management) lives in the Add/Edit
/// popup; the empty list explains how to connect the first engine.
struct EngineSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: EngineProfile?
    @State private var showAdd = false
    @State private var pendingDelete: EngineProfile?
    @State private var showConfigEditor = false

    var body: some View {
        ManagedListScaffold {
            Button {
                showAdd = true
            } label: {
                Label("Add Engine", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.engineStoreWritable)
            Spacer()
            Button {
                Task { await model.discover() }
            } label: {
                Label("Auto-Discover", systemImage: "sparkle.magnifyingglass")
            }
            .buttonStyle(SecondaryChipButtonStyle())
            .disabled(model.activeEngineProfile == nil || model.shepherd.hasActiveTurn || model.engineTransitioning)
            Button {
                showConfigEditor = true
            } label: {
                Label("Edit Config", systemImage: "curlybraces")
            }
            .buttonStyle(SecondaryChipButtonStyle())
            .help(Home.enginesFile.path)
        } rows: {
            if model.engineProfiles.isEmpty {
                firstEngineGuide
                    .listRowBackground(Color.clear)
            }
            ForEach(model.engineProfiles) { profile in
                EngineRow(
                    profile: profile,
                    active: profile.id == model.activeEngineID,
                    onEdit: { editing = profile },
                    onDelete: { pendingDelete = profile })
            }
        }
        .sheet(isPresented: $showAdd) { EngineEditorSheet(existing: nil) }
        .sheet(item: $editing) { EngineEditorSheet(existing: $0) }
        .sheet(isPresented: $showConfigEditor) {
            JSONEditorSheet(
                title: "Engines",
                fileURL: Home.enginesFile,
                seed: Self.seedConfig,
                onSaved: { Task { await model.reloadEngines() } }
            )
        }
        .confirmationDialog(
            "Remove “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Engine", role: .destructive) {
                if let p = pendingDelete {
                    Task { await model.deleteEngine(id: p.id) }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes it from engines.json and forgets its saved key. Your chats are untouched.")
        }
    }

    private var firstEngineGuide: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Connect your first engine", systemImage: "cpu")
                    .font(.title3.weight(.semibold))
                Text("Your engine runs the model. GOAT connects to it for chat, project tools and memory.")
                    .foregroundStyle(.secondary)
            }
            setupStep(
                "1", title: "Start your engine",
                detail: "Open oMLX or another compatible engine, load a model and start its server.")
            setupStep(
                "2", title: "Add the connection",
                detail:
                    "Choose Add Engine and select its preset. Check the server address and enter an API key if required. Use Custom for other compatible servers."
            )
            setupStep(
                "3", title: "Test, save and chat",
                detail:
                    "Test the connection, then add it. GOAT activates your first engine automatically. Choose a model in chat to get started."
            )
            if let url = URL(string: "https://goatherd.dev/Getting-Started") {
                Link("Read the setup guide", destination: url)
            }
            if !model.engineStoreWritable {
                Text("The saved engine configuration needs repair. Open Edit Config before adding a connection.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func setupStep(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.headline).foregroundStyle(model.theme.tokens.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Seed shown if engines.json is somehow missing when the editor opens (it's written on first run).
    private static let seedConfig = """
        {
          "engines" : []
        }
        """
}

// MARK: - Row

private struct EngineRow: View {
    let profile: EngineProfile
    let active: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(dotColor).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name).fontWeight(.medium)
                    if active {
                        Text("active").font(.caption).foregroundStyle(model.theme.tokens.tint)
                        if !model.models.isEmpty {
                            Text("· \(model.models.count) model\(model.models.count == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text(profile.url)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            // Edit / delete reveal on hover, before the switch (like a Finder row).
            HStack(spacing: 14) {
                Button {
                    onEdit()
                } label: {
                    Image(systemName: "pencil")
                }
                .help("Edit")
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Remove")
                .disabled(profile.id == model.activeEngineID && model.shepherd.hasActiveTurn)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .animation(.easeInOut(duration: 0.12), value: hovering)
            .padding(.trailing, 10)

            Toggle(
                "",
                isOn: Binding(
                    get: { active },
                    set: { if $0 { Task { await model.setActiveEngine(id: profile.id) } } })
            )
            .toggleStyle(.switch).controlSize(.small).labelsHidden()
            .disabled(active)
            .help(active ? "Active engine" : "Make active")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Set Active") {
                Task { await model.setActiveEngine(id: profile.id) }
            }
            .disabled(active)
            Button("Edit…") { onEdit() }
            Divider()
            Button("Remove…", role: .destructive) { onDelete() }
                .disabled(profile.id == model.activeEngineID && model.shepherd.hasActiveTurn)
        }
    }

    private var dotColor: Color {
        guard active else { return .gray.opacity(0.5) }
        switch model.health {
        case .ok: return .green
        case .authRequired: return .orange
        case .offline: return .red
        }
    }
}

// MARK: - Add / Edit popup (everything per-engine lives here)

private struct EngineEditorSheet: View {
    let existing: EngineProfile?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var presetID = "custom"
    @State private var name = ""
    @State private var urlText = ""
    @State private var keyDraft = ""
    @State private var removeKey = false
    @State private var testing = false
    @State private var testResult: EngineHealth?
    @State private var copiedCommand = false
    @State private var managerAppAvailable: Bool?
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var draftID = UUID().uuidString

    private struct ConnectionInput: Equatable {
        let preset: String
        let url: String
        let key: String
        let removeKey: Bool
    }
    private var connectionInput: ConnectionInput {
        ConnectionInput(preset: presetID, url: urlText, key: keyDraft, removeKey: removeKey)
    }

    private var isEditing: Bool { existing != nil }
    private var preset: EnginePreset { EnginePreset.with(id: presetID) }

    init(existing: EngineProfile?) {
        self.existing = existing
        let initialPreset = existing?.preset ?? EnginePreset.recommended
        _presetID = State(initialValue: initialPreset.id)
        _name = State(initialValue: existing?.name ?? initialPreset.name)
        _urlText = State(initialValue: existing?.url ?? initialPreset.url ?? "")
    }

    var body: some View {
        GOATDialogShell(closeAction: { dismiss() }, closeDisabled: isSaving) {
            VStack(alignment: .leading, spacing: 12) {
                Text(isEditing ? "Edit Engine" : "Add Engine")
                    .font(.title3.weight(.semibold))
                if !isEditing {
                    Text("Start the server in your engine first, then match its address below.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                Picker("Preset", selection: $presetID) {
                    ForEach(EnginePreset.all) { p in
                        Text(p.recommended ? "\(p.name) · recommended" : p.name).tag(p.id)
                    }
                }
                .onChange(of: presetID) { _, id in applyPreset(id) }

                TextField("Name", text: $name)
                    .themedField(tint: model.theme.tokens.tint)
                TextField("URL", text: $urlText, prompt: Text("http://127.0.0.1:8000"))
                    .themedField(tint: model.theme.tokens.tint)
                    .autocorrectionDisabled()

                // API key: per engine (only if this engine needs one). A saved key intentionally
                // never comes back from the credential store into this field, even when revealing.
                APIKeyField(
                    text: $keyDraft,
                    prompt: existingHasKey && !removeKey ? "•••••• (saved)" : "Only if this engine needs one",
                    tint: model.theme.tokens.tint
                )
                if existingHasKey && !removeKey {
                    Button("Remove saved key", role: .destructive) {
                        removeKey = true
                        keyDraft = ""
                    }
                    .font(.caption)
                }

                manageModels  // context-aware to THIS engine's preset

                if let testResult {
                    testSummary(testResult)
                }
                if let saveError {
                    Text(saveError).font(.callout).foregroundStyle(.secondary)
                }

                HStack {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(DialogCancelButtonStyle())
                        .keyboardShortcut(.cancelAction)
                        .disabled(isSaving)
                    Spacer()
                    Button {
                        Task { await runTest() }
                    } label: {
                        if testing { GoatLoadingIndicator().controlSize(.small) } else { Text("Test") }
                    }
                    .disabled(!formValid || testing || isSaving)
                    Button(isEditing ? "Save" : "Add") { Task { await save() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!formValid || isSaving || testing)
                }
            }
            .disabled(isSaving)
            .padding(20)
            .frame(width: 460)
        }
        .onChange(of: connectionInput) {
            testResult = nil
            saveError = nil
        }
        .task(id: managerAppPath) {
            guard let path = managerAppPath else {
                managerAppAvailable = nil
                return
            }
            managerAppAvailable = nil
            let available = await model.applicationExists(at: path)
            guard !Task.isCancelled else { return }
            managerAppAvailable = available
        }
    }

    private var existingHasKey: Bool { existing.map { model.engineHasKey($0.id) } ?? false }

    private var formValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
            let url = URL(string: urlText.trimmingCharacters(in: .whitespaces))
        else { return false }
        return EngineConfig(baseURL: url).isValidEndpoint
    }

    private var managerAppPath: String? {
        switch preset.management {
        case .app(let path, _): path
        case .mtplx(let path) where isLoopbackEndpoint: path
        case .command, .none, .mtplx: nil
        }
    }

    private var isLoopbackEndpoint: Bool {
        guard let host = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased()
        else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private var mtplxRemoteHost: String {
        URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? "this host"
    }

    /// Model management for the engine being edited (open its app, or its copyable pull command).
    @ViewBuilder private var manageModels: some View {
        switch preset.management {
        case .app(let path, let label):
            if managerAppAvailable == nil {
                GoatLoadingIndicator().controlSize(.small)
            } else if managerAppAvailable == true {
                Button(label) {
                    NSWorkspace.shared.openApplication(
                        at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration()
                    ) { _, _ in }
                }
                .font(.caption)
            } else {
                Text("\(preset.name) isn't installed in /Applications.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        case .command(let cmd):
            HStack(spacing: 8) {
                Text(cmd)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled).foregroundStyle(.secondary)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cmd, forType: .string)
                    copiedCommand = true
                } label: {
                    Image(systemName: copiedCommand ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless).help("Copy command")
            }
        case .mtplx(let path):
            if isLoopbackEndpoint {
                if managerAppAvailable == nil {
                    GoatLoadingIndicator().controlSize(.small)
                } else if managerAppAvailable == true {
                    Button("Manage Models in MTPLX…") {
                        NSWorkspace.shared.openApplication(
                            at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration()
                        ) { _, _ in }
                    }
                    .font(.caption)
                } else {
                    Text("MTPLX isn't installed in /Applications.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Models are managed on \(mtplxRemoteHost).", systemImage: "network")
                        .font(.caption.weight(.medium))
                    Text(
                        "GOAT discovers the active model over /v1/models. Manage downloads and model changes in MTPLX on that Mac; a browser link cannot safely forward GOAT’s saved API key."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder private func testSummary(_ health: EngineHealth) -> some View {
        switch health {
        case .ok(let models):
            VStack(alignment: .leading, spacing: 3) {
                Label(
                    "Reached it: \(models.count) model\(models.count == 1 ? "" : "s")",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption).foregroundStyle(.green)
                if !models.isEmpty {
                    Text(models.prefix(6).map(\.displayName).joined(separator: ", ") + (models.count > 6 ? "…" : ""))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Text("The server is reachable. Load a model in your engine, then test again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .authRequired:
            Label("Reached it: needs an API key", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        case .offline(let reason):
            Label("No response: \(reason)", systemImage: "xmark.circle.fill")
                .font(.caption).foregroundStyle(.orange).lineLimit(2)
        }
    }

    private func applyPreset(_ id: String) {
        let p = EnginePreset.with(id: id)
        guard p.id != "custom" else { return }
        name = p.name
        if let url = p.url { urlText = url }
    }

    private func buildProfile() -> EngineProfile {
        EngineProfile(
            id: existing?.id ?? draftID,
            name: name.trimmingCharacters(in: .whitespaces),
            url: urlText.trimmingCharacters(in: .whitespaces),
            presetID: presetID == "custom" ? nil : presetID,
            requestStyle: existing?.requestStyle ?? .automatic)
    }

    private func runTest() async {
        testing = true
        testResult = nil
        let input = connectionInput
        let result = await model.testEngine(buildProfile(), key: removeKey ? "" : (keyDraft.isEmpty ? nil : keyDraft))
        if connectionInput == input { testResult = result }
        testing = false
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        let profile = buildProfile()
        guard await model.addOrUpdateEngine(profile, connect: false) else {
            saveError = model.dbWarning ?? "The engine could not be saved. Try again."
            return
        }
        let keySaved: Bool
        if removeKey {
            keySaved = await model.setEngineKey("", for: profile.id, connect: false)
        } else if !keyDraft.isEmpty {
            keySaved = await model.setEngineKey(keyDraft, for: profile.id, connect: false)
        } else {
            keySaved = true
        }
        if profile.id == model.activeEngineID { model.scheduleEngineApply() }
        guard keySaved else {
            saveError = model.dbWarning ?? "The API key could not be saved. Try again."
            return
        }
        dismiss()
    }
}

/// A local draft may be revealed while it is being entered, but never causes a persisted
/// credential to be read back from the store. The visual treatment matches GOAT's other fields.
private struct APIKeyField: View {
    @Binding var text: String
    let prompt: String
    let tint: Color
    @State private var isRevealed = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isRevealed {
                TextField("API Key", text: $text, prompt: Text(prompt))
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .privacySensitive()
            } else {
                SecureField("API Key", text: $text, prompt: Text(prompt))
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .privacySensitive()
            }

            Button {
                isRevealed.toggle()
                focused = true
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isRevealed ? "Hide API key" : "Reveal API key")
            .accessibilityLabel(isRevealed ? "Hide API key" : "Reveal API key")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.4)))
        .overlay {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(
                        focused ? tint.opacity(0.9) : Color.secondary.opacity(0.35),
                        lineWidth: focused ? 1.5 : 1)
                if focused {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(tint, lineWidth: 3)
                        .blur(radius: 4)
                        .opacity(0.75)
                }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onTapGesture { focused = true }
        .animation(.easeOut(duration: 0.14), value: focused)
    }
}
