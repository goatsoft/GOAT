import AppKit
import Herd
import Inference
import SwiftUI

/// The Engine tab: a managed list of engines (one active at a time), mirroring the MCP Servers
/// screen (ADR-0021). Everything per-engine (URL, key, model management) lives in the Add/Edit
/// popup; the tab itself is just the list.
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
            Spacer()
            Button {
                Task { await model.discover() }
            } label: {
                Label("Auto-Discover", systemImage: "sparkle.magnifyingglass")
            }
            .buttonStyle(SecondaryChipButtonStyle())
            Button {
                showConfigEditor = true
            } label: {
                Label("Edit Config", systemImage: "curlybraces")
            }
            .buttonStyle(SecondaryChipButtonStyle())
            .help(Home.enginesFile.path)
        } rows: {
            if model.engineProfiles.isEmpty {
                VStack(spacing: 8) {
                    GoatieView(pose: .shrug, size: 60)
                    Text("No engines yet").foregroundStyle(.secondary)
                    Text("Add one, or run Auto-Discover.").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 24)
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

    /// Seed shown if engines.json is somehow missing when the editor opens (it's written on first run).
    private static let seedConfig = """
        {
          "active" : "omlx",
          "engines" : [
            { "id" : "omlx", "name" : "oMLX", "presetID" : "omlx", "url" : "http://127.0.0.1:8000" }
          ]
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
                .disabled(model.engineProfiles.count <= 1)
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
                .disabled(model.engineProfiles.count <= 1)
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
    @State private var requestStyle: EngineRequestStyle = .automatic
    @State private var keyDraft = ""
    @State private var removeKey = false
    @State private var testing = false
    @State private var testResult: EngineHealth?
    @State private var copiedCommand = false
    @State private var managerAppAvailable: Bool?
    @State private var isSaving = false

    private var isEditing: Bool { existing != nil }
    private var preset: EnginePreset { EnginePreset.with(id: presetID) }

    init(existing: EngineProfile?) {
        self.existing = existing
        _presetID = State(initialValue: existing?.presetID ?? "custom")
        _name = State(initialValue: existing?.name ?? "")
        _urlText = State(initialValue: existing?.url ?? "")
        _requestStyle = State(initialValue: existing?.requestStyle ?? .automatic)
    }

    var body: some View {
        GOATDialogShell(closeAction: { dismiss() }, closeDisabled: isSaving) {
            VStack(alignment: .leading, spacing: 12) {
                Text(isEditing ? "Edit Engine" : "Add Engine")
                    .font(.title3.weight(.semibold))

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

                Picker("Request protocol", selection: $requestStyle) {
                    Text("Automatic (OpenAI-compatible)").tag(EngineRequestStyle.automatic)
                    Text("Qwen local chat template").tag(EngineRequestStyle.qwenChatTemplate)
                }
                if requestStyle == .qwenChatTemplate {
                    Text(
                        "For a local Qwen server that accepts chat_template_kwargs. GOAT preserves prior reasoning and maps its effort dial to Qwen's low, medium, and xhigh levels."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

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
                    .disabled(!formValid || testing)
                    Button(isEditing ? "Save" : "Add") { Task { await save() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!formValid || isSaving)
                }
            }
            .padding(20)
            .frame(width: 460)
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
            id: existing?.id ?? UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespaces),
            url: urlText.trimmingCharacters(in: .whitespaces),
            presetID: presetID == "custom" ? nil : presetID,
            requestStyle: requestStyle)
    }

    private func runTest() async {
        testing = true
        testResult = nil
        testResult = await model.testEngine(buildProfile(), key: removeKey ? "" : keyDraft)
        testing = false
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let profile = buildProfile()
        await model.addOrUpdateEngine(profile)
        if removeKey {
            await model.setEngineKey("", for: profile.id)
        } else if !keyDraft.isEmpty {
            await model.setEngineKey(keyDraft, for: profile.id)
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
