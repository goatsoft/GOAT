import Hindsight
import Memory
import SwiftUI

private struct MemorySettingsLoadKey: Hashable {
    let providerID: MemoryProviderID
    let isEnabled: Bool
    let hindsightEnabled: Bool
    let connectionIdentity: String
}

private enum HindsightBankMode: String, CaseIterable, Identifiable {
    case existing = "Existing bank"
    case create = "New bank"

    var id: String { rawValue }
}

private enum HindsightTemplateChoice: String, CaseIterable, Identifiable {
    case goat = "GOAT starter"
    case blank = "Blank"
    case custom = "Custom JSON"

    var id: String { rawValue }
}

enum HindsightConnectionValidation {
    static func validBankID(_ value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.utf8.count <= 128
            && value.utf8.allSatisfy { byte in
                (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 45 || byte == 95
            }
    }

    static func canSubmitExistingBank(serverTestPassed: Bool, bankID: String) -> Bool {
        serverTestPassed && validBankID(bankID)
    }
}

private struct HindsightConnectionSheet: View {
    let existing: MemoryProviderRecord?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var apiURL = ""
    @State private var apiToken = ""
    @State private var banks: [HindsightBankSummary] = []
    @State private var bankMode = HindsightBankMode.existing
    @State private var selectedBankID = ""
    @State private var newBankID = ""
    @State private var templateChoice = HindsightTemplateChoice.goat
    @State private var customTemplate = HindsightBankDefaults.goatTemplate
    @State private var initialMemory = ""
    @State private var testingServer = false
    @State private var testingBank = false
    @State private var saving = false
    @State private var testedServerFingerprint: String?
    @State private var testedBankFingerprint: String?
    @State private var bankTestResult: HindsightProviderStatus?
    @State private var serverMessage: String?
    @State private var error: String?
    @State private var showingRemoveConfirmation = false

    private var isEditing: Bool { existing != nil }
    private var working: Bool { testingServer || testingBank || saving }

    init(existing: MemoryProviderRecord?) {
        self.existing = existing
        let connection = existing?.hindsight?.connection
        let legacy = existing?.hindsight?.expectedIdentity
        let bankID = connection?.bankID ?? legacy?.bankID ?? ""
        _apiURL = State(initialValue: connection?.apiURL ?? legacy?.apiURL ?? "")
        _selectedBankID = State(initialValue: bankID)
        _newBankID = State(initialValue: bankID.isEmpty ? HindsightBankDefaults.globalBankID : "")
    }

    var body: some View {
        GOATDialogShell(closeAction: { dismiss() }, closeDisabled: working) {
            VStack(alignment: .leading, spacing: 12) {
                Text(isEditing ? "Edit Hindsight" : "Connect Hindsight")
                    .font(.title3.weight(.semibold))
                Text("Connect a Hindsight server, then select an existing memory bank or create a new one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                TextField("Server URL", text: $apiURL, prompt: Text("http://localhost:8888"))
                    .themedField(tint: model.theme.tokens.tint)
                    .accessibilityLabel("Hindsight server URL")
                    .autocorrectionDisabled()
                SecureField("API Key", text: $apiToken, prompt: Text(savedKeyPrompt))
                    .themedField(tint: model.theme.tokens.tint)
                    .accessibilityLabel("Hindsight API key")
                    .privacySensitive()

                HStack {
                    Text(
                        "HTTP is allowed for localhost and private-network IPs. Other servers "
                            + "require HTTPS. Keys are stored outside memory.json."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await testServer() }
                    } label: {
                        if testingServer { GoatLoadingIndicator().controlSize(.small) } else { Text("Test Server") }
                    }
                    .buttonStyle(SecondaryChipButtonStyle())
                    .disabled(serverFingerprint == nil || working)
                }

                if serverTestPassed {
                    Divider()
                    Picker("Bank", selection: $bankMode) {
                        ForEach(HindsightBankMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if bankMode == .existing {
                        existingBankFields
                    } else {
                        newBankFields
                    }
                }

                if let serverMessage {
                    Label(serverMessage, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if let bankTestResult {
                    Label(
                        bankTestResult.state == .ready
                            ? "Healthy: connected to bank \(selectedBankID)."
                            : (bankTestResult.error ?? "GOAT could not validate this Hindsight bank."),
                        systemImage: bankTestResult.state == .ready
                            ? "checkmark.circle.fill" : "xmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(bankTestResult.state == .ready ? Color.green : Color.orange)
                    .lineLimit(3)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(4)
                }

                HStack {
                    if isEditing {
                        Button("Remove Configuration", role: .destructive) {
                            showingRemoveConfirmation = true
                        }
                        .disabled(working)
                    }
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .buttonStyle(DialogCancelButtonStyle())
                        .keyboardShortcut(.cancelAction)
                        .disabled(working)
                    if bankMode == .existing, serverTestPassed {
                        Button {
                            Task { await testBank() }
                        } label: {
                            if testingBank { GoatLoadingIndicator().controlSize(.small) } else { Text("Test Bank") }
                        }
                        .buttonStyle(SecondaryChipButtonStyle())
                        .disabled(!HindsightConnectionValidation.validBankID(selectedBankID) || working)
                    }
                    Button(primaryActionTitle) {
                        Task { await connect() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConnect || working)
                }
            }
            .padding(20)
            .frame(width: 560)
        }
        .onChange(of: serverRevision) { _, _ in resetServerTest() }
        .onChange(of: bankRevision) { _, _ in resetBankTest() }
        .disabled(saving)
        .interactiveDismissDisabled(working)
        .confirmationDialog(
            "Remove Hindsight configuration?",
            isPresented: $showingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Configuration", role: .destructive) {
                Task { await removeConfiguration() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This removes all GOAT Hindsight connections and saved keys. It does not delete any Hindsight bank or server data. Affected GOAT scopes return to Markdown (local)."
            )
        }
    }

    @ViewBuilder private var existingBankFields: some View {
        if banks.isEmpty {
            Text("This server has no banks yet. Choose New bank to create one.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Picker("Memory bank", selection: $selectedBankID) {
                ForEach(banks) { bank in
                    Text(bankLabel(bank)).tag(bank.bankID)
                }
            }
            Text("GOAT validates the selected bank's official MCP tools before saving.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var newBankFields: some View {
        TextField("Bank ID", text: $newBankID, prompt: Text("goat"))
            .themedField(tint: model.theme.tokens.tint)
            .accessibilityLabel("New Hindsight bank ID")
            .autocorrectionDisabled()

        HStack {
            Picker("Template", selection: $templateChoice) {
                ForEach(HindsightTemplateChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            Spacer()
            if let templatesURL = URL(string: "https://hindsight.vectorize.io/templates") {
                Link("Browse Hindsight templates", destination: templatesURL)
                    .font(.caption)
                    .buttonStyle(SecondaryChipButtonStyle())
            }
        }

        if templateChoice == .goat {
            Text("Configures durable retention and a GOAT user-context mental model. It adds no memories by itself.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if templateChoice == .custom {
            TextEditor(text: $customTemplate)
                .font(.system(.caption, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(7)
                .frame(minHeight: 120, maxHeight: 170)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(model.theme.tokens.tint.opacity(0.55), lineWidth: 1)
                }
                .accessibilityLabel("Hindsight bank template JSON")
        }

        TextField(
            "Initial memory (optional)",
            text: $initialMemory,
            prompt: Text("A durable preference, goal, or decision you want GOAT to remember"),
            axis: .vertical
        )
        .lineLimit(2...5)
        .themedField(tint: model.theme.tokens.tint)
        Text("The starter memory is sent only after the new bank connects successfully.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var trimmedURL: String { apiURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedNewBankID: String { newBankID.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var savedKeyPrompt: String {
        guard let existing, model.memory.hindsightHasAPIKey(for: existing.id) else {
            return "Optional for local servers"
        }
        return "•••••• (saved, leave blank to keep)"
    }
    private var serverRevision: String { [apiURL, apiToken].joined(separator: "\u{0}") }
    private var bankRevision: String { [bankMode.rawValue, selectedBankID].joined(separator: "\u{0}") }
    private var serverFingerprint: String? {
        guard (try? HindsightProviderClient.validatedBaseURL(trimmedURL)) != nil else { return nil }
        return serverRevision
    }
    private var serverTestPassed: Bool { testedServerFingerprint == serverFingerprint }
    private var currentBankFingerprint: String? {
        guard
            HindsightConnectionValidation.canSubmitExistingBank(
                serverTestPassed: serverTestPassed,
                bankID: selectedBankID)
        else { return nil }
        return [serverRevision, selectedBankID].joined(separator: "\u{0}")
    }
    private var bankTestPassed: Bool {
        bankTestResult?.state == .ready && testedBankFingerprint == currentBankFingerprint
    }
    private var selectedTemplate: String? {
        switch templateChoice {
        case .blank: nil
        case .goat: HindsightBankDefaults.goatTemplate
        case .custom: customTemplate
        }
    }
    private var creationValid: Bool {
        guard serverTestPassed, HindsightConnectionValidation.validBankID(trimmedNewBankID),
            !banks.contains(where: { $0.bankID == trimmedNewBankID }),
            initialMemory.utf8.count <= 24 * 1_024
        else { return false }
        guard let selectedTemplate else { return true }
        return (try? HindsightControlClient.validatedTemplateData(selectedTemplate)) != nil
    }
    private var canConnect: Bool {
        bankMode == .existing ? currentBankFingerprint != nil : creationValid
    }
    private var primaryActionTitle: String {
        if bankMode == .create { return "Create & Connect" }
        return isEditing ? "Save" : "Connect"
    }

    private func bankLabel(_ bank: HindsightBankSummary) -> String {
        let title = bank.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = title?.isEmpty == false ? "\(title!) (\(bank.bankID))" : bank.bankID
        return "\(prefix) · \(bank.factCount) facts"
    }

    private func resetServerTest() {
        banks = []
        testedServerFingerprint = nil
        serverMessage = nil
        resetBankTest()
        error = nil
    }

    private func resetBankTest() {
        bankTestResult = nil
        testedBankFingerprint = nil
        error = nil
    }

    private func testServer() async {
        guard let fingerprint = serverFingerprint else { return }
        testingServer = true
        error = nil
        do {
            let discovered = try await model.memory.discoverHindsightBanks(
                existingProviderID: existing?.id,
                apiURL: trimmedURL,
                apiToken: apiToken)
            guard serverFingerprint == fingerprint else {
                testingServer = false
                return
            }
            banks = discovered.sorted { $0.bankID.localizedStandardCompare($1.bankID) == .orderedAscending }
            testedServerFingerprint = fingerprint
            serverMessage = "Server connected. Found \(banks.count) bank\(banks.count == 1 ? "" : "s")."
            if !banks.contains(where: { $0.bankID == selectedBankID }) {
                selectedBankID = banks.first?.bankID ?? ""
            }
            if banks.isEmpty { bankMode = .create }
        } catch {
            self.error = error.localizedDescription
        }
        testingServer = false
    }

    @discardableResult
    private func testBank() async -> Bool {
        guard let fingerprint = currentBankFingerprint else { return false }
        testingBank = true
        error = nil
        let result = await model.memory.testHindsightConfiguration(
            existingProviderID: existing?.id,
            apiURL: trimmedURL,
            bankID: selectedBankID,
            apiToken: apiToken)
        guard currentBankFingerprint == fingerprint else {
            testingBank = false
            return false
        }
        bankTestResult = result
        testedBankFingerprint = fingerprint
        testingBank = false
        return result.state == .ready
    }

    private func connect() async {
        guard canConnect else { return }
        if bankMode == .existing, !bankTestPassed {
            guard await testBank() else { return }
        }
        saving = true
        error = nil
        let bankID: String
        if bankMode == .create {
            bankID = trimmedNewBankID
            do {
                try await model.memory.createHindsightBank(
                    existingProviderID: existing?.id,
                    apiURL: trimmedURL,
                    bankID: bankID,
                    apiToken: apiToken,
                    templateJSON: selectedTemplate)
            } catch {
                self.error = error.localizedDescription
                saving = false
                return
            }
        } else {
            bankID = selectedBankID
        }

        let shouldActivate = existing == nil || existing?.hindsight?.connection == nil
        let saved = await model.memory.saveHindsightConfiguration(
            existingProviderID: existing?.id,
            apiURL: trimmedURL,
            bankID: bankID,
            apiToken: apiToken,
            activate: shouldActivate,
            initialMemory: bankMode == .create ? initialMemory : "")
        saving = false
        if saved {
            dismiss()
        } else {
            error = model.memory.configurationError ?? "GOAT could not save this Hindsight connection."
        }
    }

    private func removeConfiguration() async {
        guard let existing else { return }
        saving = true
        error = nil
        let removed = await model.memory.removeHindsightConfiguration(existing.id)
        saving = false
        if removed {
            dismiss()
        } else {
            error = model.memory.configurationError ?? "GOAT could not remove this Hindsight connection."
        }
    }
}

struct MemorySettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var entries: [MemoryBrowserEntry] = []
    @State private var graph = MemoryGraphSnapshot.empty
    @State private var graphError: String?
    @State private var loading = false
    @State private var document: MemoryBrowserDocument?
    @State private var error: String?
    @State private var documentError: String?
    @State private var mode = MemoryBrowserMode.pages
    @State private var showingHindsightConnection = false
    @State private var hoveringHindsightCard = false

    /// Settings is the browser for the application's global store. It must not follow whichever
    /// chat happened to be selected, because a Pen's store belongs only to that Pen.
    private var projectID: UUID? { nil }
    private var providerID: MemoryProviderID { model.memory.configuration.global.providerID }
    private var usesLLMWiki: Bool { model.memory.usesLLMWiki(forProjectID: projectID) }
    private var loadKey: MemorySettingsLoadKey {
        MemorySettingsLoadKey(
            providerID: providerID, isEnabled: model.memory.isEnabled(forProjectID: projectID),
            hindsightEnabled: model.memory.builtInSettings.hindsightEnabled,
            connectionIdentity: hindsightHealthProbeKey ?? "")
    }
    /// Include the complete selected connection so saving an edit to the same provider requests a
    /// fresh health check instead of retaining the status for the prior server or bank.
    private var hindsightHealthProbeKey: String? {
        guard let provider = model.memory.configuredHindsightProvider,
            let connection = provider.hindsight?.connection
        else { return nil }
        return [provider.id.rawValue, connection.apiURL, connection.bankID].joined(separator: "\u{0}")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                controls
                library
            }
            .padding(24)
        }
        .task(id: loadKey) { await refresh() }
        .task(id: hindsightHealthProbeKey) {
            guard hindsightHealthProbeKey != nil else { return }
            while !Task.isCancelled {
                await refreshHindsightHealth()
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
        .sheet(isPresented: documentPresented) {
            if let document {
                MemoryDocumentPreview(document: document, projectID: projectID)
            }
        }
        .sheet(
            isPresented: $showingHindsightConnection,
            onDismiss: {
                Task {
                    await refreshHindsightHealth()
                    await refresh()
                }
            }
        ) {
            HindsightConnectionSheet(existing: model.memory.configuredHindsightProvider)
        }
        .alert("Couldn’t open memory document", isPresented: documentErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(documentError ?? "Unknown error")
        }
    }

    /// The connection dialog validates a disposable draft. The card must report the operational,
    /// saved provider, so probe that client after an edit is dismissed and whenever the connection
    /// selection changes.
    private func refreshHindsightHealth() async {
        guard let provider = model.memory.configuredHindsightProvider,
            provider.hindsight?.connection != nil
        else { return }
        _ = await model.memory.testHindsight(provider.id)
    }

    private var controls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                settingToggle(
                    title: "Enable memory",
                    detail: "Turns prompt memory, memory tools, and new writes on or off globally.",
                    isOn: Binding(
                        get: { model.memory.isEnabled },
                        set: { value in
                            if !value {
                                entries = []
                                graph = .empty
                                document = nil
                                error = nil
                            }
                            Task {
                                await model.memory.setEnabled(value)
                                await refresh()
                            }
                        }
                    ))
                Group {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Storage provider").font(.headline)
                            Text(
                                "Provider changes never merge Global and Pen stores. Pen memory is browsed from its Pen."
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.flexible(minimum: 0), spacing: 10),
                                count: model.memory.builtInSettings.hindsightEnabled ? 3 : 2),
                            spacing: 10
                        ) {
                            ForEach(model.memory.providers.filter { $0.kind == .wiki }) { provider in
                                providerCard(provider)
                            }
                            if model.memory.builtInSettings.hindsightEnabled { hindsightProviderCard }
                        }
                    }
                    providerStatus
                }
                .disabled(!model.memory.isEnabled)
                .opacity(model.memory.isEnabled ? 1 : 0.45)
                if let configurationError = model.memory.configurationError {
                    Text(configurationError).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(6)
        } label: {
            Label("Memory controls", systemImage: "slider.horizontal.3")
        }
    }

    private func settingToggle(title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(title, isOn: isOn).labelsHidden()
        }
    }

    private func providerCard(_ provider: MemoryProviderRecord) -> some View {
        let selected = provider.id == providerID
        let available = model.memory.isProviderAvailable(provider.id)
        return Button {
            Task {
                await model.memory.setProvider(provider.id, forProjectID: nil)
                await refresh()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: providerSymbol(provider))
                    .font(.title3)
                    .foregroundStyle(selected ? model.theme.tokens.tint : .secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(
                        available
                            ? (provider.kind == .wiki ? "Stored on this Mac" : "Managed service")
                            : "Unavailable until its provider contract is ready"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
            .padding(.trailing, 28)
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
            .background(
                selected ? model.theme.tokens.tint.opacity(0.12) : Color.secondary.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? model.theme.tokens.tint.opacity(0.65) : .clear, lineWidth: 1)
            }
            .overlay(alignment: .trailing) {
                providerSelectionIndicator(selected: selected)
                    .padding(.trailing, 12)
            }
        }
        .buttonStyle(.plain)
        .disabled(!available && provider.kind != .hindsight)
        .accessibilityLabel("Use \(provider.displayName) for memory")
    }

    private var hindsightProviderCard: some View {
        let provider = model.memory.configuredHindsightProvider
        let selected = provider?.id == providerID
        let status = provider.flatMap { model.memory.hindsightStatus(for: $0.id) }
        let connection = provider?.hindsight?.connection
        let legacy = provider?.hindsight?.expectedIdentity

        return Button {
            guard let provider else {
                showingHindsightConnection = true
                return
            }
            if provider.hindsight?.connection == nil {
                showingHindsightConnection = true
                return
            }
            if selected {
                showingHindsightConnection = true
                return
            }
            Task {
                await model.memory.setProvider(provider.id, forProjectID: nil)
                await refresh()
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image("hindsight-logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hindsight")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if provider == nil {
                        Text("Connect a server memory bank")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    } else {
                        HStack(spacing: 4) {
                            Text(connection?.bankID ?? legacy?.bankID ?? "Unknown bank")
                                .fontWeight(.medium)
                            Text("·")
                            Text(connection?.apiURL ?? legacy?.apiURL ?? "Unknown server")
                                .truncationMode(.middle)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    }

                    Label(
                        hindsightHealthText(provider: provider, status: status),
                        systemImage: hindsightHealthSymbol(status)
                    )
                    .font(.caption2)
                    .foregroundStyle(hindsightHealthColor(provider: provider, status: status))
                    .lineLimit(1)
                    .help(status?.error ?? "Health of the saved Hindsight bank connection")
                }
                Spacer(minLength: 0)
            }
            .padding(.trailing, 28)
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .background(
                selected ? model.theme.tokens.tint.opacity(0.12) : Color.secondary.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? model.theme.tokens.tint.opacity(0.65) : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            hindsightSelectionIndicator(
                selected: selected,
                showsEdit: selected && provider != nil && hoveringHindsightCard
            )
            .padding(.trailing, 12)
        }
        .onHover { hoveringHindsightCard = $0 }
        .help(selected && provider != nil ? "Edit Hindsight connection" : "Use Hindsight for memory")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            selected && provider != nil ? "Edit Hindsight connection" : "Use Hindsight for memory")
    }

    private func providerSelectionIndicator(selected: Bool) -> some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(selected ? model.theme.tokens.tint : Color.secondary.opacity(0.45))
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    private func hindsightSelectionIndicator(selected: Bool, showsEdit: Bool) -> some View {
        Image(
            systemName: showsEdit
                ? "pencil.circle.fill" : (selected ? "checkmark.circle.fill" : "circle")
        )
        .foregroundStyle(selected ? model.theme.tokens.tint : Color.secondary.opacity(0.45))
        .contentTransition(.symbolEffect(.replace))
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func hindsightHealthText(
        provider: MemoryProviderRecord?,
        status: HindsightProviderStatus?
    ) -> String {
        guard provider != nil else { return "Not configured" }
        guard provider?.hindsight?.connection != nil else { return "Reconnect required" }
        switch status?.state {
        case .ready: return "Healthy"
        case .failed: return "Unavailable"
        case .unavailable, nil: return "Not checked"
        }
    }

    private func hindsightHealthSymbol(_ status: HindsightProviderStatus?) -> String {
        switch status?.state {
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .unavailable, nil: "circle.dotted"
        }
    }

    private func hindsightHealthColor(
        provider: MemoryProviderRecord?,
        status: HindsightProviderStatus?
    ) -> Color {
        guard provider != nil else { return .secondary }
        switch status?.state {
        case .ready: return .green
        case .failed: return .orange
        case .unavailable, nil: return .secondary
        }
    }

    private func providerSymbol(_ provider: MemoryProviderRecord) -> String {
        switch provider.id {
        case .localWiki: "book.closed.fill"
        case .llmWiki: "point.3.connected.trianglepath.dotted"
        default: provider.kind == .hindsight ? "brain.head.profile" : "externaldrive.fill"
        }
    }

    @ViewBuilder private var providerStatus: some View {
        if model.memory.builtInSettings.hindsightEnabled,
            model.memory.providers.first(where: { $0.id == providerID })?.kind == .hindsight
        {
            EmptyView()
        } else if let reason = model.memory.unavailableProviderReason(providerID) {
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        } else {
            switch providerID {
            case .localWiki:
                Label(
                    "Markdown (local) is stored on this Mac. Disabling memory preserves its notes.",
                    systemImage: "externaldrive.fill"
                )
                .font(.caption).foregroundStyle(.secondary)
            case .llmWiki:
                Label(
                    "LLM Wiki (local) keeps raw sources and curated pages in this GOAT folder.",
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
                .font(.caption).foregroundStyle(.secondary)
            default:
                Label(
                    "This provider is not connected. GOAT is fail-closed and will not read or write memory.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Global memory", systemImage: "books.vertical").font(.headline)
                    Text("Recent records for chats outside a Pen.")
                        .font(.caption).foregroundStyle(model.theme.tokens.muted)
                }
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(SecondaryChipButtonStyle()).help("Refresh global memory")
                .disabled(loading)
            }
            if let connection = model.memory.hindsightConnection(forProjectID: nil),
                let url = model.memory.hindsightBankURL(forProjectID: nil)
            {
                HStack {
                    Text(connection.bankID).font(.caption.monospaced())
                        .foregroundStyle(model.theme.tokens.muted).textSelection(.enabled)
                    Spacer()
                    Link("Open in Hindsight", destination: url).judasLinks().font(.caption)
                        .buttonStyle(SecondaryChipButtonStyle())
                }
            }
            if usesLLMWiki {
                MemoryBrowserModePicker(selection: $mode).frame(maxWidth: 300)
            }
            if !model.memory.builtInSettings.hindsightEnabled,
                model.memory.provider(forProjectID: projectID)?.kind == .hindsight
            {
                ContentUnavailableView(
                    "Hindsight is paused", systemImage: "pause.circle",
                    description: Text(
                        "Enable Hindsight in Extensions or choose a local storage provider above. Saved memories are preserved."
                    ))
            } else if !model.memory.isEnabled {
                ContentUnavailableView(
                    "Memory is paused", systemImage: "pause.circle",
                    description: Text("Enable memory to browse saved records."))
            } else if loading {
                GoatLoadingIndicator("Loading global memory…").padding(.vertical, 20)
            } else if let error {
                ContentUnavailableView(
                    "Memory is unavailable", systemImage: "exclamationmark.triangle",
                    description: Text(error))
            } else if usesLLMWiki && mode == .map {
                if let graphError {
                    Text(graphError).foregroundStyle(model.theme.tokens.muted)
                } else {
                    MemoryGraphView(
                        graph: graph, tint: model.theme.tokens.tint,
                        onSelect: { id in Task { await read(id) } }
                    ).frame(height: 340)
                }
            } else if usesLLMWiki && mode == .insights {
                MemoryGraphInsightsView(graph: graph, tint: model.theme.tokens.tint)
            } else if entries.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "brain")
                        .font(.title2).foregroundStyle(model.theme.tokens.tint)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("No global memories yet").font(.callout.weight(.semibold))
                            .foregroundStyle(model.theme.tokens.ink)
                        Text("Memories saved from chats outside a Pen will appear here.")
                            .font(.callout).foregroundStyle(model.theme.tokens.muted)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(model.theme.tokens.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            } else {
                MemoryRecordList(entries: entries, tint: model.theme.tokens.tint) { id in
                    Task { await read(id) }
                }
                Text("Showing up to \(MemoryModel.recentRecordLimit) recent global records.")
                    .font(.caption).foregroundStyle(model.theme.tokens.muted)
            }
        }
        .penPanel(tokens: model.theme.tokens)
    }

    private var documentPresented: Binding<Bool> {
        Binding(get: { document != nil }, set: { if !$0 { document = nil } })
    }

    private var documentErrorPresented: Binding<Bool> {
        Binding(get: { documentError != nil }, set: { if !$0 { documentError = nil } })
    }

    private func refresh() async {
        let request = loadKey
        entries = []
        graph = .empty
        document = nil
        error = nil
        graphError = nil
        loading = request.isEnabled
        defer { if owns(request) { loading = false } }
        guard request.isEnabled else {
            entries = []
            document = nil
            return
        }
        do {
            let loadedEntries = try await model.memory.recentBrowserEntries(forProjectID: projectID)
            guard owns(request) else { return }
            entries = loadedEntries
            if model.memory.usesLLMWiki(forProjectID: projectID) {
                do {
                    let loadedGraph = try await model.memory.llmWikiGraph(forProjectID: projectID)
                    guard owns(request) else { return }
                    graph = loadedGraph
                } catch {
                    guard owns(request) else { return }
                    graphError = "The memory map is unavailable. Recent records are still available."
                }
            } else {
                mode = .pages
                graph = .empty
            }
            error = nil
        } catch {
            guard owns(request) else { return }
            graph = .empty
            self.error = error.localizedDescription
        }
    }

    private func owns(_ request: MemorySettingsLoadKey) -> Bool {
        !Task.isCancelled && loadKey == request
    }

    private func read(_ entry: MemoryBrowserEntry) async {
        await read(entry.id)
    }

    private func read(_ id: MemoryEntryID) async {
        let request = loadKey
        do {
            let loadedDocument = try await model.memory.browserDocument(id, projectID: projectID)
            guard owns(request) else { return }
            document = loadedDocument
        } catch {
            guard owns(request) else { return }
            documentError = error.localizedDescription
        }
    }
}
