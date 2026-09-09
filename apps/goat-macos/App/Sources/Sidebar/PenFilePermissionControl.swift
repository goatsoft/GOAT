import Pens
import SwiftUI

/// File-permission choice beside the composer attachment button, shared with Pen settings.
struct PenFilePermissionControl: View {
    let pen: Pen
    var chatID: UUID?
    var compact = false
    @Environment(AppModel.self) private var model
    @State private var workspaceIdentity: String?
    @State private var showingChoices = false
    @State private var selectionError: String?

    private var scope: PenFilePermissionModel.Scope {
        guard let workspaceIdentity else { return .ask }
        return model.filePermissions.scope(penID: pen.id, chatID: chatID, workspaceIdentity: workspaceIdentity)
    }

    var body: some View {
        Group {
            if compact {
                Button {
                    showingChoices.toggle()
                } label: {
                    Label(scope.choiceLabel, systemImage: scope.symbol)
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(model.theme.tokens.surface.opacity(0.65), in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.theme.tokens.muted)
                .help("Herder file permissions in \(pen.name)")
                .accessibilityLabel("File permissions: \(scope.label)")
                .popover(isPresented: $showingChoices, arrowEdge: .bottom) {
                    PenFilePermissionChoices(
                        scope: scope, penName: pen.name,
                        canRemember: model.filePermissions.canRemember && workspaceIdentity != nil,
                        error: selectionError ?? model.filePermissions.error,
                        onSelect: select
                    )
                    .frame(width: 430)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("File permissions", systemImage: "folder.badge.gearshape")
                        .font(.headline)
                    if pen.workspace != nil {
                        PenFilePermissionChoices(
                            scope: scope, penName: pen.name,
                            canRemember: model.filePermissions.canRemember && workspaceIdentity != nil,
                            error: selectionError ?? model.filePermissions.error,
                            isPen: true, onSelect: select)
                    } else {
                        Text("Choose a project folder above to manage file permissions for this Pen.")
                            .font(.callout).foregroundStyle(model.theme.tokens.muted)
                    }
                }
            }
        }
        .disabled(model.filePermissions.isUpdating)
        .task(id: pen.workspace?.path) {
            workspaceIdentity = nil
            guard let path = pen.workspace?.path else { return }
            let identity = await Task.detached {
                try? PenFileTools(workspace: URL(fileURLWithPath: path)).workspaceIdentity
            }.value
            guard !Task.isCancelled else { return }
            workspaceIdentity = identity
        }
    }

    private func select(_ choice: PenFilePermissionModel.Scope) {
        guard let workspace = pen.workspace else { return }
        selectionError = nil
        Task {
            do {
                let identity = try await Task.detached {
                    try PenFileTools(workspace: URL(fileURLWithPath: workspace.path)).workspaceIdentity
                }.value
                guard pen.workspace == workspace, !Task.isCancelled else { return }
                workspaceIdentity = identity
                if await model.filePermissions.select(
                    choice, penID: pen.id, chatID: chatID, workspaceIdentity: identity)
                {
                    showingChoices = false
                }
            } catch {
                selectionError = "The Pen folder is unavailable. Check its location on the Pen page."
            }
        }
    }

}

struct PenFilePermissionChoices: View {
    let scope: PenFilePermissionModel.Scope
    let penName: String
    let canRemember: Bool
    let error: String?
    var isPen = false
    let onSelect: (PenFilePermissionModel.Scope) -> Void
    @Environment(AppModel.self) private var model
    @State private var hovered: PenFilePermissionModel.Scope?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(isPen ? "Choose the default for this Pen's chats." : "How should file changes be approved?")
                .font(.callout)
                .foregroundStyle(model.theme.tokens.muted)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            ForEach(isPen ? [.ask, .pen] : PenFilePermissionModel.Scope.allCases, id: \.self) { choice in
                Button {
                    onSelect(choice)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: choice.symbol)
                            .frame(width: 20)
                            .foregroundStyle(model.theme.tokens.muted)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(choice.choiceLabel).font(.callout)
                            Text(detail(for: choice))
                                .font(.caption)
                                .foregroundStyle(model.theme.tokens.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "checkmark")
                            .foregroundStyle(model.theme.tokens.tint)
                            .opacity(scope == choice ? 1 : 0)
                    }
                    .padding(10)
                    .contentShape(Rectangle())
                    .background(
                        model.theme.tokens.tint.opacity(hovered == choice ? 0.09 : 0),
                        in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .disabled(choice != .ask && !canRemember)
                .onHover { hovered = $0 ? choice : nil }
                .accessibilityLabel(choice.choiceLabel)
                .accessibilityValue(scope == choice ? "Selected" : "Not selected")
                .accessibilityHint(detail(for: choice))
            }
            Divider().padding(.vertical, 5)
            Text("Files inside \(penName) only. Shell and external tool approvals are separate.")
                .font(.caption)
                .foregroundStyle(model.theme.tokens.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
            if let error {
                Text(error).font(.caption).foregroundStyle(model.theme.tokens.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
            }
        }
        .padding(isPen ? 0 : 12)
    }

    private func detail(for choice: PenFilePermissionModel.Scope) -> String {
        if isPen && choice == .ask {
            return
                "Ask before each file change. Selecting this also resets permissions granted to individual chats in this Pen."
        }
        return choice.detail(current: scope)
    }
}

struct PenCommandPermissionControl: View {
    let pen: Pen
    @Environment(AppModel.self) private var model
    @State private var editor: Editor?

    private struct Editor: Identifiable {
        let id = UUID()
        let grant: PenCommandPermissionModel.Grant?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Command permissions", systemImage: "terminal").font(.headline)
                Spacer()
                Button("Add tool…", systemImage: "plus") { editor = Editor(grant: nil) }
                    .buttonStyle(SecondaryChipButtonStyle())
                    .disabled(pen.workspace == nil)
            }
            Text(
                "Allow an executable in this Pen with any arguments, including custom project scripts. Network access is a separate setting and remains subject to JUDAS."
            )
            .font(.callout).foregroundStyle(model.theme.tokens.muted)
            Text(
                "System pwd, ls, cat, head, tail and wc are available offline by default. Other tools ask unless listed below. Tools and their child processes share the Pen's file and network restrictions. Removing permission affects future commands; use Stop to end active work."
            )
            .font(.caption).foregroundStyle(model.theme.tokens.muted)
            let grants = model.commandPermissions.grants.filter { $0.penID == pen.id }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            ForEach(grants) { grant in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(grant.name).font(.callout.weight(.medium))
                        if let path = grant.executablePath {
                            Text(path).font(.caption.monospaced()).foregroundStyle(model.theme.tokens.muted)
                                .lineLimit(1).truncationMode(.middle).help(path)
                        }
                        Text(
                            "\(scopeName(grant)) · \(grant.network ? "Network allowed when requested" : "Network not included")"
                        )
                        .font(.caption).foregroundStyle(model.theme.tokens.muted)
                    }
                    Spacer()
                    Button("Edit…") { editor = Editor(grant: grant) }.buttonStyle(.borderless)
                        .disabled(pen.workspace == nil)
                    Button("Remove") { model.commandPermissions.revoke(grant.id) }.buttonStyle(.borderless)
                }
            }
            if grants.isEmpty {
                Text(
                    pen.workspace == nil
                        ? "Choose a project folder to add allowed tools."
                        : "No additional tools allowed yet. Add one here or remember a command approval while chatting."
                )
                .font(.caption).foregroundStyle(model.theme.tokens.muted)
            } else {
                Button("Reset command whitelist") { model.commandPermissions.reset(penID: pen.id) }
                    .buttonStyle(.borderless)
            }
            if let error = model.commandPermissions.error {
                Text(error).font(.caption).foregroundStyle(model.theme.tokens.muted)
            }
        }
        .sheet(item: $editor) { edit in PenCommandEditorSheet(pen: pen, grant: edit.grant) }
    }

    private func scopeName(_ grant: PenCommandPermissionModel.Grant) -> String {
        guard let id = grant.chatID else { return "All chats in this Pen" }
        return model.chats.first(where: { $0.id == id })?.title ?? "Unavailable chat"
    }
}
