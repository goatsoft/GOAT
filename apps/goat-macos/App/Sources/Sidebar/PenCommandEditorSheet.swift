import Pens
import SwiftUI

struct PenCommandEditorSheet: View {
    let pen: Pen
    let grant: PenCommandPermissionModel.Grant?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var command: String
    @State private var network: Bool
    @State private var chatID: UUID?
    @State private var review: PenCommandPermissionModel.Review?
    @State private var working = false
    @State private var error: String?

    init(pen: Pen, grant: PenCommandPermissionModel.Grant?) {
        self.pen = pen
        self.grant = grant
        _command = State(initialValue: grant?.executablePath ?? grant?.name ?? "")
        _network = State(initialValue: grant?.network ?? false)
        _chatID = State(initialValue: grant?.chatID)
    }

    var body: some View {
        GOATDialogShell(closeAction: { dismiss() }, closeDisabled: working) {
            VStack(alignment: .leading, spacing: 14) {
                Text(grant == nil ? "Allow a tool in \(pen.name)" : "Edit allowed tool")
                    .font(.title3.weight(.semibold))
                TextField("Executable", text: $command, prompt: Text("npm, git, python3 or a full executable path"))
                    .themedField(tint: model.theme.tokens.tint)
                    .autocorrectionDisabled()
                Text(
                    "Enter just the executable. Any arguments and custom scripts are allowed within this Pen's restrictions."
                )
                .font(.caption).foregroundStyle(.secondary)
                Picker("Scope", selection: $chatID) {
                    Text("All chats in this Pen").tag(UUID?.none)
                    ForEach(model.chats.filter { $0.projectID == pen.id }) { chat in
                        Text(chat.title).tag(Optional(chat.id))
                    }
                    if let chatID, !model.chats.contains(where: { $0.id == chatID && $0.projectID == pen.id }) {
                        Text("Unavailable chat").tag(Optional(chatID))
                    }
                }
                Text(
                    "Pen-wide permissions apply to every chat. To restrict a chat, edit or remove any broader Pen allowance too."
                )
                .font(.caption).foregroundStyle(.secondary)
                Toggle("Allow network access when requested", isOn: $network)
                Text(
                    "Enables downloads and remote connections for this tool and its child processes. Offline commands stay offline. JUDAS can still block connections; this permission is not limited to particular sites."
                )
                .font(.caption).foregroundStyle(.secondary)
                if let review {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("Executable found", systemImage: "checkmark.circle")
                            .font(.callout.weight(.medium))
                        Text(review.executable.path).font(.caption.monospaced()).textSelection(.enabled)
                        Text("Changes to this executable or the Pen folder require checking permission again.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(model.theme.tokens.tint) }
                HStack {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    if working { GoatLoadingIndicator().controlSize(.small) }
                    Button("Check executable") { check() }.disabled(
                        command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Save permission") { save() }.disabled(review == nil).keyboardShortcut(.defaultAction)
                }
            }
            .padding(20).frame(width: 560)
        }
        .disabled(working)
        .interactiveDismissDisabled(working)
        .onChange(of: command) { _, _ in
            review = nil
            error = nil
        }
    }

    private func check() {
        guard let workspace = pen.workspace else { return }
        working = true
        error = nil
        review = nil
        Task {
            defer { working = false }
            do {
                let result = try await model.commandPermissions.review(
                    command: command,
                    workspace: URL(fileURLWithPath: workspace.path))
                guard model.pens.contains(where: { $0.id == pen.id && $0.workspace == workspace }) else {
                    error = "The Pen folder changed. Close this dialog and try again."
                    return
                }
                review = result
            } catch { self.error = error.localizedDescription }
        }
    }

    private func save() {
        guard let review,
            model.pens.contains(where: { $0.id == pen.id && $0.workspace?.path == review.workspace.path }),
            chatID == nil || model.chats.contains(where: { $0.id == chatID && $0.projectID == pen.id })
        else {
            error = "Choose an available Pen folder and chat before saving."
            return
        }
        working = true
        error = nil
        Task {
            defer { working = false }
            if await model.commandPermissions.saveReviewed(
                review, penID: pen.id, chatID: chatID,
                network: network, replacing: grant?.id)
            {
                dismiss()
            } else {
                self.review = nil
                error =
                    model.commandPermissions.error ?? "Permissions changed. Check the executable again before saving."
            }
        }
    }
}
