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
    @State private var preferencesReset = false
    @State private var uninstall = UninstallCoordinator.shared
    @State private var showingStorageLocations = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if uninstall.pending {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Waiting for GOAT to close").font(.headline)
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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: reviewing ? "checklist" : "externaldrive")
                    .foregroundStyle(model.theme.tokens.tint)
                Text(uninstall.pending ? "Uninstall scheduled" : reviewing ? "Are you sure?" : "Manage GOAT data")
                    .font(.title2.bold())
                Spacer()
                Text(plan.action == .uninstall ? "Uninstall" : "Preferences").font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(model.theme.tokens.tint.opacity(0.15), in: Capsule())
            }
            Text(
                reviewing
                    ? "Removal starts after you finish work and quit GOAT. You can cancel before quitting."
                    : plan.action == .uninstall
                        ? "Review what to keep. Automatic removal waits until you have finished your work and closed GOAT."
                        : "Reset the preferences listed below. Your data stays in place and GOAT stays open."
            )
            .font(.callout).foregroundStyle(.secondary)
        }
        .padding(24)
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 8) {
                choiceTab(
                    "Reset preferences", symbol: "arrow.counterclockwise", value: .preferences, selection: $plan.action)
                choiceTab("Uninstall GOAT", symbol: "trash", value: .uninstall, selection: $plan.action)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Action")

            switch plan.action {
            case .preferences:
                bulletSection("Resets to defaults", items: plan.affected, symbol: "slider.horizontal.3")
                bulletSection("Kept", items: plan.kept, symbol: "checkmark.shield")
                if preferencesReset {
                    Label("Preferences reset.", systemImage: "checkmark.circle")
                        .font(.callout).foregroundStyle(model.theme.tokens.tint)
                }
            case .uninstall:
                Picker("Uninstall options", selection: $plan.uninstallMode) {
                    ForEach(DataManagementPlan.UninstallMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
                summaryBlock(
                    "Choose what to keep", symbol: "app.dashed",
                    text:
                        "Partial uninstall keeps GOAT Home data and chats, with app preferences unchecked. Uninstall all clears every keep option. You can adjust the boxes below. Removed data goes to recovery after GOAT closes; the app goes to Trash."
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
            storageDisclosure("Storage locations on this Mac")
        }
    }

    private func choiceTab<Value: Equatable>(
        _ title: String, symbol: String, value: Value, selection: Binding<Value>
    ) -> some View {
        let selected = selection.wrappedValue == value
        return Button {
            selection.wrappedValue = value
        } label: {
            Label(title, systemImage: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(selected ? model.theme.tokens.tint : model.theme.tokens.ink)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    selected ? model.theme.tokens.tint.opacity(0.18) : model.theme.tokens.surface,
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(
                            selected ? model.theme.tokens.tint.opacity(0.75) : model.theme.tokens.ink.opacity(0.12),
                            lineWidth: selected ? 1.5 : 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(
                "The selected app and CLI copies will move to Trash. Any data or app preferences you chose to remove will be saved in a private recovery folder."
            )
            .font(.callout).foregroundStyle(.secondary)
            bulletSection("Will remove", items: plan.affected, symbol: "trash")
            bulletSection("Will keep", items: plan.kept, symbol: "checkmark.shield")
            VStack(alignment: .leading, spacing: 8) {
                Text("Recovery folder").font(.headline)
                Text(plan.backupURL?.path ?? "A private GOAT Recovery folder in Downloads.")
                    .font(.callout).textSelection(.enabled)
                Button("Change folder…") { chooseLocation(directory: true) { plan.backupURL = $0 } }
                if let inventory, let warning = plan.backupWarning(inventory: inventory) {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(model.theme.tokens.tint)
                }
                Text(
                    "Keep recovery data private. It can contain credentials and conversations. Choose a folder on the same volume as the data."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            storageDisclosure("Storage locations on this Mac")
        }
    }

    private func storageDisclosure(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showingStorageLocations.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: showingStorageLocations ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(title)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(showingStorageLocations ? "Expanded" : "Collapsed")
            .accessibilityHint("Show or hide storage locations on this Mac")
            if showingStorageLocations { locations }
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
                Button("Back") { reviewing = false }
                    .disabled(uninstall.pending || uninstall.preparing)
            }
            Button(uninstall.pending ? "Done" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Spacer()
            if plan.action == .preferences {
                Button("Reset preferences") {
                    model.resetPreferences()
                    preferencesReset = true
                }
                .disabled(uninstall.pending || uninstall.preparing)
                .buttonStyle(.borderedProminent)
            } else if reviewing {
                Button(uninstall.preparing ? "Starting…" : "Uninstall", role: .destructive) {
                    guard let inventory else { return }
                    Task { await uninstall.prepare(plan: plan, inventory: inventory, model: model) }
                }
                .disabled(
                    uninstall.pending || uninstall.preparing || inventory == nil
                        || inventory.map { plan.backupWarning(inventory: $0) != nil } == true
                )
                .buttonStyle(.borderedProminent)
            } else {
                Button("Review choices") { reviewing = true }
                    .disabled(inventory == nil)
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
