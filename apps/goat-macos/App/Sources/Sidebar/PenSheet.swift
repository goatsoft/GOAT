import AppKit
import Herd
import Pens
import SwiftUI

private enum NewPenWorkspaceChoice: String, CaseIterable, Identifiable {
    case create, existing, none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .create: "New folder"
        case .existing: "Existing folder"
        case .none: "No folder yet"
        }
    }

    var systemImage: String {
        switch self {
        case .create: "folder.badge.plus"
        case .existing: "folder"
        case .none: "folder.badge.questionmark"
        }
    }
}

/// Create or edit a Pen. New Pens can create or bind a user-owned workspace. Instructions and
/// references stay editable from the Pen landing page afterward.
struct PenSheet: View {
    let pen: Pen?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var emoji = ""
    @State private var color = OKLCH.fallback
    @State private var workspaceChoice: NewPenWorkspaceChoice = .create
    @State private var existingWorkspace: URL?
    @State private var initializeGitRepository = false
    @State private var gitInstallation: GitInstallationStatus?
    @State private var workspaceError: String?
    @State private var seeded = false
    @State private var isSaving = false

    private var isEditing: Bool { pen != nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var canSave: Bool {
        !trimmedName.isEmpty && !isSaving
            && (isEditing || workspaceChoice != .existing || existingWorkspace != nil)
    }

    var body: some View {
        GOATDialogShell(closeAction: { dismiss() }, closeDisabled: isSaving, extraOpacity: 0.26) {
            VStack(alignment: .leading, spacing: 16) {
                Text(isEditing ? "Edit Pen" : "New Pen")
                    .font(.title3.weight(.semibold))

                HStack(spacing: 10) {
                    EmojiField(emoji: $emoji, tint: model.theme.tokens.tint)
                    TextField("Name", text: $name)
                        .themedField(tint: model.theme.tokens.tint)
                        .onSubmit {
                            if !trimmedName.isEmpty { Task { await save() } }
                        }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Colour")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    OKLCHPicker(color: $color, tint: model.theme.tokens.tint)
                }

                if !isEditing {
                    workspacePicker
                }

                // Live preview of the sidebar pill.
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(color))
                    Text(emoji.isEmpty ? "🐐" : emoji)
                    Text(trimmedName.isEmpty ? "Pen name" : trimmedName)
                        .fontWeight(.medium)
                        .foregroundStyle(trimmedName.isEmpty ? .tertiary : .primary)
                }
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(Color(color).opacity(0.16)))
                .overlay(Capsule().strokeBorder(Color(color).opacity(0.35), lineWidth: 1))

                HStack {
                    if !isEditing {
                        Text("GOAT keeps its own instructions and memory separate from your project folder.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .buttonStyle(DialogCancelButtonStyle())
                        .keyboardShortcut(.cancelAction)
                        .disabled(isSaving)
                    Button(isEditing ? "Save" : "Create") { Task { await save() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                }
            }
            .padding(20)
            .frame(width: 500)
        }
        .onAppear(perform: seed)
        .task {
            guard !isEditing else { return }
            gitInstallation = await GitWorkspaceWorker.shared.installation()
        }
    }

    private var workspacePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Project folder")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 7) {
                ForEach(NewPenWorkspaceChoice.allCases) { choice in
                    WorkspaceChoiceButton(
                        choice: choice,
                        isSelected: workspaceChoice == choice,
                        tint: model.theme.tokens.tint
                    ) {
                        workspaceChoice = choice
                        if choice != .create { initializeGitRepository = false }
                        workspaceError = nil
                    }
                }
            }

            switch workspaceChoice {
            case .create:
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .foregroundStyle(model.theme.tokens.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.herdRootPath)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(
                            "GOAT will create \(HerdWorkspace.slug(for: trimmedName.isEmpty ? "pen" : trimmedName)) here."
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button {
                        chooseHerdRoot()
                    } label: {
                        Label("Choose…", systemImage: "folder")
                    }
                    .buttonStyle(SecondaryChipButtonStyle())
                    .controlSize(.small)
                }
                .padding(10)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))

                if gitInstallation?.isAvailable == true {
                    Toggle(isOn: $initializeGitRepository) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Initialize Git repository", systemImage: "arrow.triangle.branch")
                                .font(.caption.weight(.medium))
                            Text("Creates an empty local repository. GOAT will not add or commit files.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.quaternary.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                }
            case .existing:
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(existingWorkspace == nil ? Color.secondary : model.theme.tokens.tint)
                    Text(existingWorkspace?.path ?? "Choose an existing project folder")
                        .font(.caption)
                        .foregroundStyle(existingWorkspace == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button {
                        chooseExistingWorkspace()
                    } label: {
                        Label("Choose…", systemImage: "folder")
                    }
                    .buttonStyle(SecondaryChipButtonStyle())
                    .controlSize(.small)
                }
                .padding(10)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            case .none:
                Text("You can bind a project folder later from this Pen.")
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

    private func seed() {
        guard !seeded else { return }
        seeded = true
        if let pen {
            name = pen.name
            emoji = pen.emoji
            color = pen.color
        } else {
            color = OKLCH.palette.randomElement() ?? .fallback
        }
    }

    private func save() async {
        guard canSave else { return }
        isSaving = true
        defer { isSaving = false }
        let workspace: PenWorkspace?
        if isEditing {
            workspace = pen?.workspace
        } else {
            do {
                switch workspaceChoice {
                case .create:
                    workspace = try await HerdWorkspaceFileWorker.shared.createWorkspace(
                        name: trimmedName, rootPath: model.herdRootPath)
                    if initializeGitRepository, let workspace {
                        switch await GitWorkspaceWorker.shared.initializeRepository(at: workspace) {
                        case .initialized, .alreadyRepository:
                            break
                        case .failed(let detail):
                            existingWorkspace = URL(fileURLWithPath: workspace.path, isDirectory: true)
                            workspaceChoice = .existing
                            initializeGitRepository = false
                            workspaceError = "Project folder was created, but Git could not initialize it: \(detail)"
                            return
                        }
                    }
                case .existing:
                    guard let existingWorkspace else { return }
                    workspace = await HerdWorkspaceFileWorker.shared.bindWorkspace(at: existingWorkspace)
                case .none:
                    workspace = nil
                }
            } catch {
                workspaceError = "Couldn’t create the project folder: \(error.localizedDescription)"
                return
            }
        }
        guard
            await model.savePen(
                existing: pen, name: trimmedName, emoji: emoji,
                instructions: pen?.instructions ?? "", color: color, workspace: workspace)
                != nil
        else { return }
        dismiss()
    }

    private func chooseHerdRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: model.herdRootPath, isDirectory: true)
        GOATFileSelector.present(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            model.herdRootPath = url.standardizedFileURL.path
        }
    }

    private func chooseExistingWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        GOATFileSelector.present(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            existingWorkspace = url.standardizedFileURL
            workspaceError = nil
        }
    }
}

/// A quiet, desktop-sized folder-mode selector. The selected state is an outlined card with a
/// checkmark rather than a filled segmented-control button, so all three paths stay readable.
private struct WorkspaceChoiceButton: View {
    let choice: NewPenWorkspaceChoice
    let isSelected: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: choice.systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(choice.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark" : "circle")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isSelected ? tint : Color.secondary.opacity(0.6))
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(tint.opacity(0.10))
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.quaternary.opacity(0.18))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isSelected ? tint.opacity(0.6) : Color.white.opacity(0.10),
                        lineWidth: isSelected ? 1.25 : 0.75)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
