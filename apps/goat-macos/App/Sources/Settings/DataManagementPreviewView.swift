import AppKit
import Herd
import SwiftUI

struct DataManagementPreviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var plan = DataManagementPlan()
    @State private var reviewing = false
    @State private var inventory: DataManagementInventory?
    @State private var inventoryError: String?
    @State private var copied = false
    @State private var uninstall = UninstallCoordinator.shared
    @State private var confirmingUninstall = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if uninstall.pending {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Uninstall is prepared").font(.headline)
                    Text(
                        "Finish all work, then quit GOAT normally. Cleanup starts only after GOAT has closed. You can cancel before quitting. The request expires after one hour."
                    )
                    .font(.callout)
                    if let recovery = uninstall.recovery {
                        Text(recovery.path).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Button("Cancel uninstall") { uninstall.cancel() }
                }
                .padding(24)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let error = uninstall.error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.callout)
                    }
                    if reviewing {
                        review
                    } else {
                        choices
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(uninstall.pending || uninstall.preparing)
            }
            Divider()
            footer
        }
        .frame(width: 720, height: 660)
        .background(model.theme.tokens.bg)
        .tint(model.theme.tokens.tint)
        .task { await inspectLocations() }
        .confirmationDialog("Prepare automatic uninstall?", isPresented: $confirmingUninstall) {
            Button("Uninstall after I quit GOAT", role: .destructive) {
                guard let inventory else { return }
                Task { await uninstall.prepare(plan: plan, inventory: inventory, model: model) }
            }
        } message: {
            Text(
                "Selected data will move to a private recovery folder and this app copy will move to Trash after GOAT closes. Finish active work before quitting. Keep options are shown in the review."
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: reviewing ? "checklist" : "externaldrive")
                    .foregroundStyle(model.theme.tokens.tint)
                Text(reviewing ? "Review your plan" : "Manage GOAT data")
                    .font(.title2.bold())
                Spacer()
                Text(plan.action == .uninstall ? "Uninstall" : "Preview").font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(model.theme.tokens.tint.opacity(0.15), in: Capsule())
            }
            Text(
                plan.action == .uninstall
                    ? "Review what to keep. Automatic removal waits until you have finished your work and closed GOAT."
                    : "Explore a reset. These reset previews do not change files or preferences or create a backup."
            )
            .font(.callout).foregroundStyle(.secondary)
        }
        .padding(24)
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker("Action", selection: $plan.action) {
                ForEach(DataManagementPlan.Action.allCases) { action in
                    Text(action.rawValue).tag(action)
                }
            }
            .pickerStyle(.segmented)

            switch plan.action {
            case .preferences:
                summaryBlock(
                    "Return preferences to defaults", symbol: "slider.horizontal.3",
                    text:
                        "Review appearance, app behaviour, window layout and local permission decisions. Your GOAT Home location, connections, conversations and local files stay in place."
                )
            case .localData:
                Text("Choose the data to include").font(.headline)
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(DataManagementPlan.Group.allCases) { group in
                        Toggle(
                            isOn: Binding(
                                get: { plan.groups.contains(group) },
                                set: { plan.select(group, included: $0) })
                        ) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(group.rawValue).font(.body.weight(.medium))
                                Text(group.explanation).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            case .uninstall:
                summaryBlock(
                    "Choose what to keep", symbol: "app.dashed",
                    text:
                        "GOAT can uninstall automatically after you close it. Keep the data you want for a later reinstall. Removed data goes to a private recovery folder; the app goes to Trash."
                )
                Toggle("Keep macOS app preferences and window state", isOn: $plan.keepPreferences)
                    .toggleStyle(.checkbox)
                Toggle("Keep all GOAT Home data", isOn: $plan.keepsHomeData)
                    .toggleStyle(.checkbox)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(DataManagementPlan.Group.allCases.filter { $0 != .chats }) { group in
                        Toggle(
                            "Keep \(group.rawValue.lowercased())",
                            isOn: Binding(
                                get: { !plan.groups.contains(group) },
                                set: { plan.select(group, included: !$0) })
                        )
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.leading, 18)
                Toggle(
                    "Keep chats and attachments (Application Support)",
                    isOn: Binding(
                        get: { !plan.groups.contains(.chats) },
                        set: { plan.select(.chats, included: !$0) })
                )
                .toggleStyle(.checkbox)
                Text("Removing Pen metadata also includes its chats. Keeping chats keeps their Pen metadata.")
                    .font(.caption).foregroundStyle(.secondary)
                if let app = inventory?.locations.first(where: { $0.id == "app" }) {
                    locationRow(app)
                    Button("Show app in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([app.url])
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Separately installed CLI").font(.headline)
                    Text(plan.cliURL?.path ?? "No CLI selected. Any separate installation will be kept.")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    HStack {
                        Button("Choose CLI copy…") { chooseLocation(directory: false) { plan.cliURL = $0 } }
                        if plan.cliURL != nil {
                            Button("Keep CLI") { plan.cliURL = nil }
                        }
                    }
                    Text("Select only the goat command you installed. Linked targets are kept.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("Storage locations on this Mac") { locations }
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(plan.action.rawValue).font(.headline)
            bulletSection("Would change", items: plan.affected, symbol: "minus.circle")
            bulletSection("Kept", items: plan.kept, symbol: "checkmark.shield")
            VStack(alignment: .leading, spacing: 8) {
                Text("Backup destination").font(.headline)
                Text(
                    plan.backupURL?.path
                        ?? (plan.action == .uninstall
                            ? "A private GOAT Recovery folder in Downloads."
                            : "Choose a private folder outside GOAT’s data locations.")
                )
                .font(.callout).textSelection(.enabled)
                Button("Choose backup folder…") { chooseLocation(directory: true) { plan.backupURL = $0 } }
                if let inventory, let warning = plan.backupWarning(inventory: inventory) {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(model.theme.tokens.tint)
                }
                Text(
                    plan.action == .uninstall
                        ? "Selected data is moved here after GOAT closes. Choose a folder on the same volume. Recovery data can contain credentials and conversations."
                        : "No backup has been created or verified. Backups can contain credentials and conversations."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            summaryBlock(
                "Before making changes", symbol: "pause.circle",
                text:
                    "Finish chats, queued work, imports and command jobs, then quit GOAT. Keep a private backup of owned files, including the closed database and its WAL/SHM companions. Inspect shared folders and keep unrecognised files and linked targets."
            )
            summaryBlock(
                "Recovery", symbol: "arrow.uturn.backward.circle",
                text:
                    "Restore to the recorded locations while GOAT is closed, using a compatible version. Preserve ownership and private permissions. Review existing files before replacing them."
            )
            DisclosureGroup("Review storage locations") { locations }
        }
    }

    @ViewBuilder private var locations: some View {
        if let inventory {
            VStack(alignment: .leading, spacing: 14) {
                Text(
                    "GOAT Home: \(inventory.homeSource). The chat database and attachments have their own Application Support location."
                )
                .font(.caption).foregroundStyle(.secondary)
                StorageLocationTree(inventory: inventory)
                Text("Preferences are managed by macOS for \(inventory.preferencesDomain).")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Folder presence is not proof of ownership. Only reviewed GOAT entries belong in a removal plan.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 10)
        } else if let inventoryError {
            Text(inventoryError).foregroundStyle(.secondary)
        } else {
            ProgressView("Reading locations…")
        }
    }

    private func locationRow(_ location: DataManagementInventory.Location) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(location.title).font(.callout.weight(.medium))
                Spacer()
                Text(location.status.rawValue).font(.caption).foregroundStyle(.secondary)
            }
            Text(location.url.path).font(.caption.monospaced())
                .foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func summaryBlock(_ title: String, symbol: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.headline)
                .foregroundStyle(model.theme.tokens.tint)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(model.theme.tokens.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }

    private func bulletSection(_ title: String, items: [String], symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.headline)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text("•").foregroundStyle(model.theme.tokens.tint)
                    Text(item).font(.callout)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if reviewing {
                Button("Back") {
                    reviewing = false
                    copied = false
                }
            }
            Button(reviewing ? "Done" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Spacer()
            if reviewing && plan.action == .uninstall {
                Button(uninstall.preparing ? "Preparing…" : "Prepare uninstall…") { confirmingUninstall = true }
                    .disabled(
                        uninstall.pending || uninstall.preparing || inventory == nil
                            || inventory.map { plan.backupWarning(inventory: $0) != nil } == true
                    )
                    .buttonStyle(.borderedProminent)
            } else if reviewing {
                Button(copied ? "Checklist copied" : "Copy checklist") {
                    guard let inventory else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(plan.checklist(inventory: inventory), forType: .string)
                    copied = true
                }
                .disabled(inventory == nil || inventory.map { plan.backupWarning(inventory: $0) != nil } == true)
                .buttonStyle(.borderedProminent)
            } else {
                Button("Review choices") { reviewing = true }
                    .disabled(!plan.canReview || inventory == nil)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func chooseLocation(directory: Bool, selected: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory
        panel.canChooseFiles = !directory
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        GOATFileSelector.present(panel) { response in
            if response == .OK, let url = panel.url {
                selected(url)
                copied = false
            }
        }
    }

    private func inspectLocations() async {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            inventoryError = "Could not locate this account’s Application Support folder."
            return
        }
        let environmentHome = ProcessInfo.processInfo.environment["GOAT_HOME"] ?? ""
        let preferenceHome = UserDefaults.standard.string(forKey: "goat.home") ?? ""
        let source =
            !environmentHome.isEmpty
            ? "Environment override" : !preferenceHome.isEmpty ? "Settings override" : "Default location"
        let snapshot = DataManagementInventory(
            home: Home.url, support: support.appendingPathComponent("GOAT"), app: Bundle.main.bundleURL,
            homeSource: source, preferencesDomain: Bundle.main.bundleIdentifier ?? "dev.leet.goat")
        inventory = await Task.detached(priority: .utility) { snapshot.inspected() }.value
    }
}
