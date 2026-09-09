import AppKit
import GOATed
import MCPClient
import SwiftUI
import UniformTypeIdentifiers

struct UserExtensionsView: View {
    @Environment(AppModel.self) private var model
    @State private var review: PackageReview?
    @State private var pendingRemoval: InstalledExtension?
    @State private var mcpDraft: MCPServerConfig?
    @State private var error: String?
    @State private var importing = false

    private struct PackageReview: Identifiable {
        let id = UUID()
        let package: ExtensionPackage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Text("User extensions").font(.headline)
                Spacer(minLength: 12)
                if importing || model.userExtensions.busy { GoatLoadingIndicator().controlSize(.small) }
                Button("Add Extension…", systemImage: "plus", action: choosePackage)
                    .buttonStyle(SecondaryChipButtonStyle())
                    .fixedSize()
            }
            Text("Skills and prompts from local GOATed packages.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.userExtensions.items.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.title2)
                        .foregroundStyle(model.theme.tokens.tint)
                        .frame(width: 32, height: 32)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("No extensions yet").font(.body.weight(.medium))
                        Text("Add a .goated file, review its contents, then enable it for all chats or one Pen.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            }
            ForEach(model.userExtensions.items) { item in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        PackageDetails(package: item.package, showName: false)
                        if let issue = item.issue {
                            Text(issue).font(.caption).foregroundStyle(model.theme.tokens.tint)
                        }
                        Toggle(
                            "Enable extension",
                            isOn: Binding(
                                get: { item.enabled },
                                set: { value in perform { try await model.userExtensions.setEnabled(item.id, value) } })
                        )
                        if !item.package.manifest.mcp.isEmpty {
                            Text("MCP connections are app-wide and managed separately in MCP settings.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(item.package.manifest.mcp) { connection in
                            Button("Set Up \(connection.name)…") { prepareMCP(connection) }
                        }
                        HStack {
                            Button("Export Extension…") { export(item.package) }
                            Spacer()
                            Button("Remove…", role: .destructive) { pendingRemoval = item }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "puzzlepiece.extension").foregroundStyle(model.theme.tokens.tint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.package.manifest.name).font(.body.weight(.semibold))
                            Text("\(scopeName(item.penID)) · v\(item.package.manifest.version)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text(item.issue != nil ? "Needs attention" : (item.enabled ? "On" : "Off"))
                            .font(.caption.weight(.medium)).foregroundStyle(
                                item.enabled || item.issue != nil ? model.theme.tokens.tint : .secondary
                            )
                            .fixedSize()
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            }
            if !model.userExtensions.items.isEmpty {
                Text("Changes apply to future turns.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.userExtensions.issues.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Needs attention", systemImage: "exclamationmark.circle")
                        .font(.callout.weight(.medium))
                    ForEach(model.userExtensions.issues, id: \.self) { issue in
                        Text(issue).font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .foregroundStyle(model.theme.tokens.tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disclosureGroupStyle(ExtensionDisclosureStyle())
        .disabled(importing || model.userExtensions.busy)
        .task { await model.userExtensions.load() }
        .sheet(item: $review) { value in
            PackageReviewSheet(package: value.package)
        }
        .sheet(item: $mcpDraft) { draft in
            ServerEditorSheet(existing: nil, draft: draft)
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.package.manifest.name ?? "extension")?",
            isPresented: Binding(
                get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible
        ) {
            Button("Remove Extension", role: .destructive) {
                guard let id = pendingRemoval?.id else { return }
                pendingRemoval = nil
                perform { try await model.userExtensions.remove(id) }
            }
        } message: {
            Text(
                "Removes this package and revokes its skills and prompts. Separately added MCP connections stay in MCP settings."
            )
        }
        .alert("Extensions", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func scopeName(_ id: UUID?) -> String {
        guard let id else { return "Global (all chats)" }
        return model.pens.first(where: { $0.id == id })?.name ?? "Unavailable Pen"
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }

    private func choosePackage() {
        let panel = NSOpenPanel()
        panel.title = "Add GOATed Extension"
        panel.allowedContentTypes = [UTType(filenameExtension: "goated") ?? .zip]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        GOATFileSelector.present(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            importing = true
            Task {
                defer { importing = false }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do { review = PackageReview(package: try await model.userExtensions.store.inspect(url)) } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func export(_ package: ExtensionPackage) {
        savePackageForReview(package, model: model) { error = $0 }
    }

    private func prepareMCP(_ connection: PackageMCPConnection) {
        // A draft opens the existing explicit Test/Add flow. No transport starts here.
        if let raw = connection.url, let url = URL(string: raw) {
            mcpDraft = MCPServerConfig(name: connection.name, transport: .http(url: url, headers: [:]))
        } else if let command = connection.command {
            mcpDraft = MCPServerConfig(
                name: connection.name, transport: .stdio(command: command, args: connection.arguments ?? [], env: [:]))
        }
    }
}

private struct PackageReviewSheet: View {
    let package: ExtensionPackage
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var penID: UUID?
    @State private var error: String?
    @State private var installing = false

    var body: some View {
        GOATDialogShell(closeAction: { dismiss() }, closeDisabled: installing) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Review Extension").font(.title3.weight(.semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        PackageDetails(package: package)
                        Picker("Scope", selection: $penID) {
                            Text("Global (all chats)").tag(UUID?.none)
                            ForEach(model.pens) { pen in Text(pen.name).tag(Optional(pen.id)) }
                        }
                        Text(
                            "Enabling adds the declared prompts and skills to this scope. Instructions may influence model behavior; existing tool approvals still apply."
                        )
                        if !package.manifest.mcp.isEmpty {
                            Text(
                                "MCP suggestions require separate, app-wide setup after import. Global/Pen scope applies to this package’s prompts and skills only. Test can launch a program or connect to a server using your macOS user access; package import does neither."
                            )
                            .foregroundStyle(.secondary)
                        }
                        if let error { Text(error).foregroundStyle(model.theme.tokens.tint) }
                    }
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Export…") { savePackageForReview(package, model: model) { error = $0 } }
                    Button("Install Disabled") { install(enabled: false) }
                    Button("Install and Enable") { install(enabled: true) }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20).frame(width: 580, height: 540)
        }
        .disabled(installing)
        .interactiveDismissDisabled(installing)
    }

    private func install(enabled: Bool) {
        guard penID == nil || model.pens.contains(where: { $0.id == penID }) else {
            error = "The selected Pen is no longer available. Choose another scope."
            return
        }
        installing = true
        Task {
            defer { installing = false }
            do {
                try await model.userExtensions.install(package, penID: penID, enabled: enabled)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct PackageDetails: View {
    let package: ExtensionPackage
    var showName = true
    @State private var showsContents = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showName { Text(package.manifest.name).font(.headline) }
            Text("\(package.manifest.version) · \(package.manifest.author)").font(.caption)
            Text("Author supplied by the package; identity is not verified.").font(.caption).foregroundStyle(.secondary)
            Text(package.manifest.description).font(.callout)
            Text(package.manifest.id).font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(
                "\(countLabel(package.manifest.skills.count, "skill")) · \(countLabel(package.manifest.prompts.count, "prompt")) · \(countLabel(package.manifest.mcp.count, "MCP suggestion"))"
            )
            .font(.caption.weight(.medium))
            ForEach(package.manifest.permissions, id: \.self) { permission in
                Text(permissionDescription(permission)).font(.caption)
            }
            DisclosureGroup("Contents (\(package.fileNames.count) files)", isExpanded: $showsContents) {
                if showsContents {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(package.fileNames, id: \.self) { path in
                            PackageFilePreview(path: path, package: package)
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .font(.caption)
        }
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func countLabel(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    private func permissionDescription(_ permission: String) -> String {
        switch permission {
        case "skill-resources": "Skills: the model can load this package's instructions and bundled text resources."
        case "prompt-context": "Prompts: adds instruction text to future turns in the selected scope."
        case "mcp-setup": "MCP: offers connection setup suggestions. No connection is enabled by this package."
        default: permission
        }
    }
}

private struct PackageFilePreview: View {
    let path: String
    let package: ExtensionPackage
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(path, isExpanded: $expanded) {
            if expanded {
                let text = package.text(at: path) ?? ""
                Text(String(text.prefix(12_000)))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if text.count > 12_000 {
                    Text("Preview limited to 12,000 characters. Export the package to inspect the complete file.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

@MainActor private func savePackageForReview(
    _ package: ExtensionPackage, model: AppModel, onError: @escaping (String) -> Void
) {
    let panel = NSSavePanel()
    panel.title = "Export GOATed Extension"
    panel.nameFieldStringValue = package.manifest.id + ".goated"
    panel.allowedContentTypes = [UTType(filenameExtension: "goated") ?? .zip]
    GOATFileSelector.present(panel) { response in
        guard response == .OK, let url = panel.url else { return }
        Task {
            do { try await model.userExtensions.store.export(package, to: url) } catch {
                onError(error.localizedDescription)
            }
        }
    }
}
