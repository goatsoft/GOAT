import MCPClient
import SwiftUI

struct MCPSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: MCPServerConfig?
    @State private var showAddSheet = false
    @State private var importResult: String?
    @State private var pendingDelete: MCPServerConfig?
    @State private var showConfigEditor = false
    @State private var pendingImport: MCPModel.ImportSource?

    var body: some View {
        ManagedListScaffold {
            Button {
                showAddSheet = true
            } label: {
                Label("Add Server", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            Menu {
                ForEach(MCPModel.ImportSource.allCases) { source in
                    Button("From \(source.label)…") { pendingImport = source }
                }
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .menuStyle(.button)
            .buttonStyle(SecondaryChipButtonStyle())
            .fixedSize()
            if let importResult {
                Text(importResult).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showConfigEditor = true
            } label: {
                Label("Edit Config", systemImage: "curlybraces")
            }
            .buttonStyle(SecondaryChipButtonStyle())
            .help(model.mcp.configFileURL.path)
        } rows: {
            if let error = model.mcp.configError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .listRowBackground(Color.clear)
            }
            if model.mcp.configs.isEmpty {
                VStack(spacing: 8) {
                    GoatieView(pose: .shrug, size: 60)
                    Text("No servers yet")
                        .foregroundStyle(.secondary)
                    Text("Add one, or import your Claude Desktop config.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .listRowBackground(Color.clear)
            }
            ForEach(model.mcp.configs) { config in
                ServerRow(config: config, onEdit: { editing = config }, onDelete: { pendingDelete = config })
            }
        }
        .sheet(isPresented: $showAddSheet) {
            ServerEditorSheet(existing: nil)
        }
        .sheet(item: $editing) { config in
            ServerEditorSheet(existing: config)
        }
        .sheet(isPresented: $showConfigEditor) {
            JSONEditorSheet(
                title: "MCP Servers",
                fileURL: model.mcp.configFileURL,
                seed: "{\n  \"mcpServers\": {}\n}",
                onSaved: { Task { await model.mcp.load() } }
            )
        }
        .confirmationDialog(
            "Remove “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Server", role: .destructive) {
                if let config = pendingDelete {
                    Task { await model.mcp.delete(config.name) }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes it from mcp-servers.json and forgets its tool permissions. Your data is untouched.")
        }
        .confirmationDialog(
            "Import MCP servers from \(pendingImport?.label ?? "")?",
            isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }),
            titleVisibility: .visible
        ) {
            Button("Import (leave them off)") {
                if let source = pendingImport {
                    Task {
                        let n = await model.mcp.runImport(from: source)
                        importResult =
                            n > 0
                            ? "Imported \(n) server\(n == 1 ? "" : "s") - review, then enable"
                            : "Nothing new to import"
                    }
                }
                pendingImport = nil
            }
            Button("Cancel", role: .cancel) { pendingImport = nil }
        } message: {
            Text(
                "Imported servers run commands on your Mac with your permissions, and each one's tool descriptions are added to every request - a large or chatty server can eat a big share of a local model's limited context. They arrive turned off; enable only the ones you trust."
            )
        }
        .task { await model.mcp.refreshStates() }
    }
}

// MARK: - Row

private struct ServerRow: View {
    let config: MCPServerConfig
    let onEdit: () -> Void
    let onDelete: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(dotColor).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(config.name).fontWeight(.medium)
                    if let state, state.status == .connected {
                        Text("\(state.tools.count) tool\(state.tools.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(state?.status == .failed ? .orange : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if state?.status == .failed {
                Button("Retry") { Task { await model.mcp.reconnect(config.name) } }
                    .controlSize(.small)
            }
            Toggle(
                "",
                isOn: Binding(
                    get: { !config.disabled },
                    set: { enabled in
                        Task { await model.mcp.setEnabled(config.name, enabled: enabled) }
                    }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .help(config.disabled ? "Connect" : "Disconnect")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Edit…") { onEdit() }
            Button("Reconnect") { Task { await model.mcp.reconnect(config.name) } }
            Divider()
            Button("Remove…", role: .destructive) { onDelete() }
        }
    }

    private var state: MCPServerManager.State? { model.mcp.states[config.name] }

    private var dotColor: Color {
        guard !config.disabled else { return .gray }
        switch state?.status {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        default: return .gray
        }
    }

    private var statusLine: String {
        if config.disabled { return "disconnected · \(config.summary)" }
        switch state?.status {
        case .connected: return config.summary
        case .connecting: return "connecting…"
        case .failed: return state?.error ?? "failed"
        default: return config.summary
        }
    }
}

// MARK: - Editor sheet (Test before Add)

struct ServerEditorSheet: View {
    let existing: MCPServerConfig?
    var draft: MCPServerConfig? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var kind = 0  // 0 stdio · 1 http
    @State private var command = ""
    @State private var args = "[]"
    @State private var envText = "{}"
    @State private var urlText = ""
    @State private var headersText = "{}"
    @State private var testing = false
    @State private var saving = false
    @State private var testResult: Result<[MCPToolInfo], MCPError>?
    @State private var testedFingerprint: String?
    @State private var testTask: Task<Void, Never>?

    private var isEditing: Bool { existing != nil }

    var body: some View {
        GOATDialogShell(
            closeAction: {
                testTask?.cancel()
                dismiss()
            },
            closeDisabled: saving
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text(isEditing ? "Edit Server" : "Add Server")
                    .font(.title3.weight(.semibold))

                if let error = model.mcp.configError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                }

                TextField("Name", text: $name)
                    .themedField(tint: model.theme.tokens.tint)

                Picker("Transport", selection: $kind) {
                    Text("stdio (command)").tag(0)
                    Text("HTTP").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if kind == 0 {
                    TextField("Command (e.g. npx)", text: $command)
                        .themedField(tint: model.theme.tokens.tint)
                    TextField("Arguments JSON array", text: $args, axis: .vertical)
                        .themedField(tint: model.theme.tokens.tint)
                        .lineLimit(2...5)
                        .help(#"Example: ["--root", "/A Folder"]"#)
                    TextField("Environment JSON object", text: $envText, axis: .vertical)
                        .themedField(tint: model.theme.tokens.tint)
                        .lineLimit(2...5)
                } else {
                    TextField("URL (e.g. http://127.0.0.1:8888/mcp)", text: $urlText)
                        .themedField(tint: model.theme.tokens.tint)
                    TextField("Headers JSON object", text: $headersText, axis: .vertical)
                        .themedField(tint: model.theme.tokens.tint)
                        .lineLimit(2...5)
                }

                switch testResult {
                case .success(let tools):
                    Label(
                        "\(tools.count) tools: \(tools.prefix(4).map(\.name).joined(separator: ", "))\(tools.count > 4 ? "…" : "")",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.green)
                    .lineLimit(2)
                case .failure(let error):
                    Label(error.localizedDescription, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                case nil:
                    EmptyView()
                }

                HStack {
                    Button("Cancel") {
                        testTask?.cancel()
                        dismiss()
                    }
                    .buttonStyle(DialogCancelButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                    Spacer()
                    if case .failure = testResult, !isEditing {
                        Button("Add Anyway") { Task { await save() } }
                            .disabled(saving)
                    }
                    Button {
                        startTest()
                    } label: {
                        if testing { GoatLoadingIndicator().controlSize(.small) } else { Text("Test") }
                    }
                    .disabled(saving || !formValid || testing)

                    Button(isEditing ? "Save" : "Add") { Task { await save() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(saving || !formValid || (!isEditing && !testPassed))
                        .help(
                            isEditing || testPassed
                                ? "" : "Run a successful Test first (or Add Anyway after a failed one)")
                }
            }
            .padding(20)
            .frame(width: 460)
        }
        .onAppear(perform: populate)
        .onChange(of: editorRevision) { _, _ in invalidateTest() }
        .onDisappear {
            testTask?.cancel()
            testTask = nil
        }
        .disabled(saving)
        .interactiveDismissDisabled(saving)
    }

    private var testPassed: Bool {
        if case .success = testResult, testedFingerprint == currentFingerprint { return true }
        return false
    }

    private var formValid: Bool {
        currentFingerprint != nil
    }

    private var currentFingerprint: String? {
        guard let config = buildConfig(), (try? config.validate()) != nil else { return nil }
        return config.permissionFingerprint
    }

    private var editorRevision: String {
        [name, String(kind), command, args, envText, urlText, headersText]
            .joined(separator: "\u{0}")
    }

    private func populate() {
        guard let existing = existing ?? draft else { return }
        name = existing.name
        switch existing.transport {
        case .stdio(let c, let a, let e):
            kind = 0
            command = c
            args = jsonText(a)
            envText = jsonText(e)
        case .http(let u, let h):
            kind = 1
            urlText = u.absoluteString
            headersText = jsonText(h)
        }
    }

    private func buildConfig() -> MCPServerConfig? {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if kind == 0 {
            guard
                let parsedArguments = decodeJSON([String].self, from: args),
                let environment = decodeJSON([String: String].self, from: envText)
            else { return nil }
            return MCPServerConfig(
                name: trimmedName,
                transport: .stdio(
                    command: command.trimmingCharacters(in: .whitespaces),
                    args: parsedArguments,
                    env: environment
                ),
                disabled: existing?.disabled ?? false
            )
        }
        guard
            let url = URL(string: urlText),
            let headers = decodeJSON([String: String].self, from: headersText)
        else { return nil }
        return MCPServerConfig(
            name: trimmedName, transport: .http(url: url, headers: headers),
            disabled: existing?.disabled ?? false
        )
    }

    private func decodeJSON<Value: Decodable>(_ type: Value.Type, from text: String) -> Value? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func jsonText<Value: Encodable>(_ value: Value) -> String {
        guard
            let data = try? JSONEncoder().encode(value),
            let object = try? JSONSerialization.jsonObject(with: data),
            let pretty = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return "" }
        return String(decoding: pretty, as: UTF8.self)
    }

    private func startTest() {
        guard let config = buildConfig() else { return }
        let fingerprint = config.permissionFingerprint
        testTask?.cancel()
        testing = true
        testResult = nil
        testedFingerprint = nil
        testTask = Task { @MainActor in
            let result = await model.mcp.test(config)
            guard
                !Task.isCancelled,
                buildConfig()?.permissionFingerprint == fingerprint
            else { return }
            testResult = result
            testedFingerprint = fingerprint
            testing = false
            testTask = nil
        }
    }

    private func invalidateTest() {
        guard testResult != nil || testing else { return }
        testTask?.cancel()
        testTask = nil
        testResult = nil
        testedFingerprint = nil
        testing = false
    }

    private func save() async {
        guard let config = buildConfig() else { return }
        guard isEditing || !model.mcp.configs.contains(where: { $0.name == config.name }) else {
            model.mcp.configError = "A server with this name already exists. Choose a different name."
            return
        }
        testTask?.cancel()
        saving = true
        let didSave = await model.mcp.addOrUpdate(config, renamedFrom: existing?.name)
        saving = false
        if didSave { dismiss() }
    }
}
