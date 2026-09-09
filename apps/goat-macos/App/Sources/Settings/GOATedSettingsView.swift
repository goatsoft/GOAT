import AppKit
import Foundation
import GOATed
import Herd
import SwiftUI

enum GOATedSettingsSection: String, CaseIterable, Identifiable {
    case skills = "Skills"
    case extensions = "Extensions"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .skills: "shippingbox"
        case .extensions: "puzzlepiece.extension"
        }
    }
}

struct SkillManagementRoot: Identifiable, Sendable {
    let id: String
    let label: String
    let root: URL
    let source: SkillSource
    let isLocked: Bool
}

struct ManagedSkill: Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let rootID: String
    let isLocked: Bool
}

struct SkillManagementSnapshot: Sendable {
    var skills: [ManagedSkill] = []
    var issues: [SkillIssue] = []
}

struct GOATedSettingsView: View {
    @Environment(AppModel.self) private var model
    @Binding var section: GOATedSettingsSection
    @State private var snapshot = SkillManagementSnapshot()
    @State private var isRefreshing = false
    @State private var pendingRemoval: ManagedSkill?
    @State private var errorMessage: String?
    @State private var extensionReport: [String] = []
    @State private var extensionOrigin = ExtensionOrigin.builtIn

    private enum ExtensionOrigin: String, CaseIterable, Identifiable {
        case builtIn = "Built-in"
        case user = "User"
        var id: String { rawValue }
    }

    private struct BuiltInExtension: Identifiable {
        let name: String
        let detail: String
        let symbol: String
        var enabled: Binding<Bool>? = nil
        var id: String { name }
    }

    var body: some View {
        Group {
            switch section {
            case .skills:
                skillsView
            case .extensions:
                extensionsView
            }
        }
        .padding(24)
        .task { await refreshSkills() }
        .confirmationDialog(
            "Remove \(pendingRemoval?.name ?? "skill")?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Skill", role: .destructive) {
                guard let skill = pendingRemoval else { return }
                pendingRemoval = nil
                Task { await remove(skill) }
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("This deletes the user-owned skill folder. Built-in skills cannot be removed.")
        }
        .alert("Skills", isPresented: errorPresented) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    private var skillsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    chooseSkillFolder(for: globalRoot)
                } label: {
                    Label("Add Skill…", systemImage: "plus")
                }
                .buttonStyle(SecondaryChipButtonStyle())

                Button {
                    open(globalRoot)
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                .buttonStyle(SecondaryChipButtonStyle())

                Button {
                    Task { await refreshSkills() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(SecondaryChipButtonStyle())
                .disabled(isRefreshing)
                .help("Refresh skills")

                Spacer()
                if isRefreshing { GoatLoadingIndicator().controlSize(.small) }
            }

            Text(
                "Global skills apply to every chat and load progressively when their descriptions match a request. Add Pen skills from that Pen’s page."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            List {
                ForEach(groupedSkills, id: \.label) { group in
                    Section(group.label) {
                        ForEach(group.skills) { skill in
                            skillRow(skill)
                        }
                    }
                }

                if snapshot.skills.isEmpty, !isRefreshing {
                    ContentUnavailableView(
                        "No Skills Found",
                        systemImage: "shippingbox",
                        description: Text("Add an Agent Skills folder containing a valid SKILL.md."))
                }

                if !snapshot.issues.isEmpty {
                    Section("Needs attention") {
                        ForEach(Array(snapshot.issues.enumerated()), id: \.offset) { _, issue in
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(issue.source).font(.callout.weight(.medium))
                                    Text(issue.message).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private var extensionsView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Extension source", selection: $extensionOrigin) {
                ForEach(ExtensionOrigin.allCases) { origin in
                    Text(origin.rawValue).tag(origin)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if extensionOrigin == .builtIn {
                        ForEach(builtInExtensions) { item in
                            extensionRow(item)
                        }
                        if let error = model.extensionError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(model.theme.tokens.tint)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        DisclosureGroup("Diagnostics") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(
                                    "Runtime registrations and recent issues. Registration does not mean a service is connected."
                                )
                                .foregroundStyle(.secondary)
                                Button("Refresh status") {
                                    Task { extensionReport = await model.extensionReport() }
                                }
                                ForEach(Array(extensionReport.enumerated()), id: \.offset) { _, line in
                                    Text(line).foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                            .task { extensionReport = await model.extensionReport() }
                        }
                        .padding(.top, 8)
                    } else {
                        UserExtensionsView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
            }
        }
    }

    private var builtInExtensions: [BuiltInExtension] {
        [
            BuiltInExtension(
                name: "Herder",
                detail:
                    "Search, read and edit Pen files, and run commands for installs, builds and tests. Scoped file and command approvals still apply.",
                symbol: "folder.badge.gearshape",
                enabled: Binding(
                    get: { model.memory.builtInSettings.herderEnabled },
                    set: { model.memory.builtInSettings.herderEnabled = $0 })),
            BuiltInExtension(
                name: "Hindsight Memory",
                detail:
                    "Use your configured Hindsight server for memory context and completed-chat retention. Set up its connection and memory banks in Memory settings.",
                symbol: "eye.fill",
                enabled: Binding(
                    get: { model.memory.builtInSettings.hindsightEnabled },
                    set: { value in Task { await model.setHindsightExtensionEnabled(value) } })),
            BuiltInExtension(
                name: "JUDAS",
                detail:
                    "Required core functionality. Enforces GOAT's connection policy and records security activity. Manage its policy in JUDAS settings; enforcement stays on.",
                symbol: "shield.lefthalf.filled"),
            BuiltInExtension(
                name: "Hitch",
                detail:
                    "Allow programs running as your macOS user to list Pens and chats, create chats, send messages and follow or cancel their turns. Uses a private local socket. Tool approvals stay in GOAT.",
                symbol: "terminal",
                enabled: Binding(
                    get: { model.controlEnabled },
                    set: { value in Task { await model.setControlEnabled(value) } })),
            BuiltInExtension(
                name: "Pronk",
                detail:
                    "Example extension: adopt a fictional goat in a Pen, offer imaginary treats and ask for a pasture report. Access is limited to Pronk's own local state. Turning it off removes its tools; saved goats stay on this Mac.",
                symbol: "hare",
                enabled: Binding(
                    get: { model.pronkEnabled },
                    set: { value in Task { await model.setPronkEnabled(value) } })),
            BuiltInExtension(
                name: "Skills",
                detail:
                    "Required core functionality. Discover Global and Pen skills, load instructions when needed, and use chat commands. Manage your own skills from Skills; user extension skills follow their extension’s switch.",
                symbol: "shippingbox.fill"),
        ].sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func skillRow(_ skill: ManagedSkill) -> some View {
        HStack(spacing: 12) {
            Image(systemName: skill.isLocked ? "lock.fill" : "shippingbox")
                .foregroundStyle(skill.isLocked ? .secondary : model.theme.tokens.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(skill.name).font(.body.weight(.semibold))
                    if skill.isLocked {
                        Text("BUILT-IN")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(skill.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            if !skill.isLocked {
                Button(role: .destructive) {
                    pendingRemoval = skill
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove \(skill.name)")
            }
        }
        .padding(.vertical, 4)
    }

    private func extensionRow(_ item: BuiltInExtension) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                if let enabled = item.enabled {
                    Toggle("Enable \(item.name)", isOn: enabled)
                        .disabled(model.extensionsChanging || model.shepherd.activeTurnID != nil)
                }
                if item.name == "Herder" { herderConfiguration }
                if item.name == "Hindsight Memory" {
                    Text(
                        "On by default. Turning this off pauses Hindsight and hides it from Memory choices. Saved connections, selected banks and server data are preserved; affected memory stays paused until you enable Hindsight or choose a local provider."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                if item.enabled != nil && model.shepherd.activeTurnID != nil {
                    Text("Available when the active chat turn finishes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.body)
                    .foregroundStyle(model.theme.tokens.tint)
                    .frame(width: 18)
                Text(item.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let enabled = item.enabled {
                    Text(enabled.wrappedValue ? "On" : "Off")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(enabled.wrappedValue ? model.theme.tokens.tint : .secondary)
                        .fixedSize()
                } else {
                    Label("Required core", systemImage: "lock.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
        .disclosureGroupStyle(ExtensionDisclosureStyle())
        .padding(10)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    private var herderConfiguration: some View {
        @Bindable var settings = model.memory.builtInSettings
        return VStack(alignment: .leading, spacing: 10) {
            Divider()
            Toggle("File creation and edits", isOn: $settings.herderWritesEnabled)
            Text(
                "Controls native file writes. Search and reading remain available. Shell commands can also change files when approved."
            )
            .font(.caption).foregroundStyle(.secondary)
            Toggle("Shell commands", isOn: $settings.herderCommandsEnabled)
            Text(
                "Non-interactive commands confined to the Pen. To use Herder for reading only, turn off both file edits and shell commands."
            )
            .font(.caption).foregroundStyle(.secondary)
            Picker(
                "Default command timeout",
                selection: Binding(
                    get: { settings.commandTimeout }, set: { settings.setCommandTimeout($0) })
            ) {
                ForEach(Array(Set([30, 60, 120, 300, 600, settings.commandTimeout])).sorted(), id: \.self) { seconds in
                    Text("\(seconds) seconds").tag(seconds)
                }
            }
            .disabled(!settings.herderCommandsEnabled)
            Text(
                "Used when a command supplies no timeout. Commands can request up to 600 seconds. Manage file permissions and the command whitelist below Skills on each Pen page. Network access still requires command permission and JUDAS approval."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!settings.herderEnabled || model.extensionsChanging || model.shepherd.activeTurnID != nil)
    }

    private var allRoots: [SkillManagementRoot] {
        let builtInRoot =
            Bundle.main.resourceURL?.appendingPathComponent("Skills", isDirectory: true)
            ?? Bundle.main.bundleURL.appendingPathComponent("Skills", isDirectory: true)
        return [
            SkillManagementRoot(
                id: "builtin", label: "Built-in", root: builtInRoot,
                source: .builtIn, isLocked: true),
            globalRoot,
        ]
    }

    private var globalRoot: SkillManagementRoot {
        SkillManagementRoot(
            id: "global", label: "Global", root: Home.skillsDir,
            source: .global, isLocked: false)
    }

    private var groupedSkills: [(label: String, skills: [ManagedSkill])] {
        let labels = Dictionary(uniqueKeysWithValues: allRoots.map { ($0.id, $0.label) })
        let grouped = Dictionary(grouping: snapshot.skills, by: \.rootID)
        return allRoots.compactMap { root in
            guard let skills = grouped[root.id], !skills.isEmpty else { return nil }
            return (labels[root.id] ?? root.label, skills)
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })
    }

    private func refreshSkills() async {
        isRefreshing = true
        let roots = allRoots
        snapshot = await GOATedSkillFileWorker.shared.snapshot(roots: roots)
        isRefreshing = false
    }

    private func chooseSkillFolder(for root: SkillManagementRoot) {
        let panel = NSOpenPanel()
        panel.title = "Choose a Skill Folder"
        panel.message = "Select one folder containing a valid SKILL.md."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        GOATFileSelector.present(panel) { response in
            guard response == .OK, let source = panel.url else { return }
            Task {
                let hasAccess = source.startAccessingSecurityScopedResource()
                defer { if hasAccess { source.stopAccessingSecurityScopedResource() } }
                do {
                    try await GOATedSkillFileWorker.shared.install(from: source, into: root)
                    await refreshSkills()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func open(_ root: SkillManagementRoot) {
        Task {
            do {
                try await GOATedSkillFileWorker.shared.ensureRoot(root)
                NSWorkspace.shared.open(root.root)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func remove(_ skill: ManagedSkill) async {
        guard let root = allRoots.first(where: { $0.id == skill.rootID }), !root.isLocked else {
            return
        }
        do {
            try await GOATedSkillFileWorker.shared.remove(named: skill.name, from: root)
            await refreshSkills()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct GOATedSettingsTabBar: View {
    @Binding var selection: GOATedSettingsSection
    let tint: Color

    var body: some View {
        HStack(spacing: 24) {
            ForEach(GOATedSettingsSection.allCases) { section in
                let isSelected = selection == section
                Button {
                    selection = section
                } label: {
                    Label(section.rawValue, systemImage: section.systemImage)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isSelected ? tint : Color.secondary)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) {
                            Capsule()
                                .fill(isSelected ? tint : Color.clear)
                                .frame(height: 2)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

actor GOATedSkillFileWorker {
    static let shared = GOATedSkillFileWorker()
    private static let maximumFiles = 256
    private static let maximumDepth = 16
    private static let maximumTotalBytes = 8 * 1_024 * 1_024

    func snapshot(roots: [SkillManagementRoot]) async -> SkillManagementSnapshot {
        var result = SkillManagementSnapshot()
        for root in roots {
            do {
                let directories = try LocalFileStore.childDirectories(in: root.root)
                let provider = FileSkillProvider(
                    providerID: "goat.settings.\(root.id.replacingOccurrences(of: ":", with: "."))",
                    root: root.root,
                    source: root.source)
                for directory in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let name = directory.lastPathComponent
                    do {
                        let definition = try await provider.loadSkill(named: name)
                        result.skills.append(
                            ManagedSkill(
                                id: "\(root.id):\(name)",
                                name: definition.summary.name,
                                description: definition.summary.description,
                                rootID: root.id,
                                isLocked: root.isLocked))
                    } catch {
                        result.issues.append(
                            SkillIssue(source: "\(root.label) / \(name)", message: error.localizedDescription))
                    }
                }
            } catch {
                result.issues.append(
                    SkillIssue(source: root.label, message: error.localizedDescription))
            }
        }
        return result
    }

    func ensureRoot(_ root: SkillManagementRoot) throws {
        guard !root.isLocked else { return }
        try LocalFileStore.ensureDirectory(at: root.root)
    }

    func install(from source: URL, into root: SkillManagementRoot) async throws {
        guard !root.isLocked else {
            throw LocalStoreError.unsafePath(path: root.root.path, reason: "built-in skills are read-only")
        }
        try LocalFileStore.rejectSymbolicLink(at: source)
        guard try LocalFileStore.directoryExists(at: source) else {
            throw LocalStoreError.unsafePath(path: source.path, reason: "expected a skill directory")
        }
        let name = source.lastPathComponent
        try LocalFileStore.validateComponent(name, label: "skill name")

        let sourceProvider = FileSkillProvider(
            providerID: "goat.settings.import", root: source.deletingLastPathComponent(),
            source: .runtime("Import"))
        _ = try await sourceProvider.loadSkill(named: name)

        try LocalFileStore.ensureDirectory(at: root.root)
        let destination = root.root.appendingPathComponent(name, isDirectory: true)
        try LocalFileStore.requireContained(destination, in: root.root)
        guard !(try LocalFileStore.directoryExists(at: destination)) else {
            throw LocalStoreError.operationFailed(
                path: destination.path, operation: "install skill", reason: "a skill with this name already exists")
        }

        let stagingRoot = try LocalFileStore.makeStagingDirectory(in: root.root)
        defer { try? LocalFileStore.removeItem(at: stagingRoot) }
        let stagedSkill = stagingRoot.appendingPathComponent(name, isDirectory: true)
        var fileCount = 0
        var totalBytes = 0
        try copyDirectory(
            from: source, to: stagedSkill, depth: 0,
            fileCount: &fileCount, totalBytes: &totalBytes)

        let stagedProvider = FileSkillProvider(
            providerID: "goat.settings.staged", root: stagingRoot, source: root.source)
        _ = try await stagedProvider.loadSkill(named: name)
        try LocalFileStore.commitNewDirectory(stagedSkill, to: destination, in: root.root)
    }

    func remove(named name: String, from root: SkillManagementRoot) async throws {
        guard !root.isLocked else {
            throw LocalStoreError.unsafePath(path: root.root.path, reason: "built-in skills are read-only")
        }
        try LocalFileStore.validateComponent(name, label: "skill name")
        let destination = root.root.appendingPathComponent(name, isDirectory: true)
        try LocalFileStore.requireContained(destination, in: root.root)
        let provider = FileSkillProvider(
            providerID: "goat.settings.remove", root: root.root, source: root.source)
        _ = try await provider.loadSkill(named: name)
        try LocalFileStore.removeItem(at: destination)
    }

    private func copyDirectory(
        from source: URL,
        to destination: URL,
        depth: Int,
        fileCount: inout Int,
        totalBytes: inout Int
    ) throws {
        guard depth <= Self.maximumDepth else {
            throw LocalStoreError.invalidData(path: source.path, reason: "skill resources are nested too deeply")
        }
        try LocalFileStore.rejectSymbolicLink(at: source)
        try LocalFileStore.ensureDirectory(at: destination)
        let children = try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [])
        for child in children {
            fileCount += 1
            guard fileCount <= Self.maximumFiles else {
                throw LocalStoreError.invalidData(path: source.path, reason: "skill contains too many files")
            }
            try LocalFileStore.validateComponent(child.lastPathComponent, label: "skill resource name")
            let values = try child.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw LocalStoreError.unsafePath(path: child.path, reason: "skill resources cannot be symbolic links")
            }
            let target = destination.appendingPathComponent(
                child.lastPathComponent, isDirectory: values.isDirectory == true)
            if values.isDirectory == true {
                try copyDirectory(
                    from: child, to: target, depth: depth + 1,
                    fileCount: &fileCount, totalBytes: &totalBytes)
            } else if values.isRegularFile == true {
                let maximumBytes =
                    child.lastPathComponent == "SKILL.md"
                    ? FileSkillProvider.maximumSkillBytes
                    : FileSkillProvider.maximumResourceBytes
                guard
                    let data = try LocalFileStore.boundedDataIfPresent(
                        at: child, maximumBytes: maximumBytes)
                else {
                    throw LocalStoreError.operationFailed(
                        path: child.path, operation: "import skill", reason: "resource disappeared")
                }
                totalBytes += data.count
                guard totalBytes <= Self.maximumTotalBytes else {
                    throw LocalStoreError.invalidData(path: source.path, reason: "skill exceeds the total size limit")
                }
                try LocalFileStore.write(data, to: target)
            } else {
                throw LocalStoreError.unsafePath(
                    path: child.path, reason: "skill resources must be regular files or directories")
            }
        }
    }
}
