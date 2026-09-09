import AppKit
import Caprine
import CoreGraphics
import Herd
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, herd, judas, engine, memory, goated, mcp, appearance
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .herd: "Herd"
        case .judas: "JUDAS"
        case .engine: "Engine"
        case .memory: "Memory"
        case .goated: "Extensions"
        case .mcp: "MCP"
        case .appearance: "Appearance"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .herd: "folder.badge.gearshape"
        case .judas: "shield.lefthalf.filled"
        case .engine: "cpu"
        case .memory: "brain"
        case .goated: "shippingbox.fill"
        case .mcp: "wrench.and.screwdriver"
        case .appearance: "paintbrush"
        }
    }
    var description: String {
        switch self {
        case .general: "Defaults and safeguards for every GOAT session."
        case .herd: "Project folders and the local Git status GOAT can safely read."
        case .judas: "Choose what connects. Keep local services, previews and privacy under your control."
        case .engine: "Connect and manage the local models that power GOAT."
        case .memory: "Global persistent context for chats that are not in a Pen."
        case .goated: "Manage GOAT skills and the extension surface."
        case .mcp: "Connect tools and control what GOAT may call."
        case .appearance: "Shape GOAT’s look, feel, and reading comfort."
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var goatedSection: GOATedSettingsSection = .skills
    @State private var search = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader
                Divider().opacity(0.35)
                Group {
                    if !model.startupPhase.hasLocalState {
                        VStack(spacing: 12) {
                            if case .failed = model.startupPhase {
                                Image(systemName: "externaldrive.badge.exclamationmark")
                                    .font(.title)
                                    .foregroundStyle(.orange)
                                Text(model.startupPhase.statusText)
                                    .multilineTextAlignment(.center)
                                Button("Retry") { Task { await model.retryStartup() } }
                            } else {
                                GoatLoadingIndicator()
                                Text(model.startupPhase.statusText)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(24)
                    } else {
                        switch model.settingsTab {
                        case .general: GeneralSettings()
                        case .herd: HerdSettings()
                        case .judas:
                            JudasSettings(
                                openEngine: { model.settingsTab = .engine },
                                openMemory: { model.settingsTab = .memory },
                                openMCP: { model.settingsTab = .mcp })
                        case .engine: EngineSettings()
                        case .memory: MemorySettingsView()
                        case .goated: GOATedSettingsView(section: $goatedSection)
                        case .mcp: MCPSettingsView()
                        case .appearance: AppearanceSettings()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 780, idealWidth: 860, minHeight: 600, idealHeight: 660)
        .background(CaprineBackground(model.theme.tokens, transparency: model.windowTransparency, extraOpacity: 0.24))
        .background(
            WindowConfigurator(
                alwaysOnTop: model.settingsAlwaysOnTop,
                showsAlwaysOnTopToggle: true,
                onAlwaysOnTopToggle: { model.settingsAlwaysOnTop.toggle() },
                controlTint: model.theme.tokens.tint)
        )
        .tint(model.theme.tokens.tint)
        .goatPresentation()
    }

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: model.settingsTab.symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(model.theme.tokens.tint)
                    .frame(width: 54, height: 54)
                    .background(
                        model.theme.tokens.tint.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.settingsTab.title).font(.title2.weight(.bold))
                    Text(model.settingsTab.description).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                if model.settingsTab == .memory {
                    Label(
                        model.memory.isEnabled ? "Active" : "Paused",
                        systemImage: model.memory.isEnabled ? "checkmark.circle.fill" : "pause.circle"
                    )
                    .foregroundStyle(model.memory.isEnabled ? .green : .secondary)
                    .font(.subheadline.weight(.medium))
                }
            }

            if model.settingsTab == .goated {
                GOATedSettingsTabBar(
                    selection: $goatedSection,
                    tint: model.theme.tokens.tint
                )
                .padding(.top, 10)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            SidebarSearchField(text: $search, prompt: "Search settings")
            Text("SETTINGS").font(.caption2.weight(.bold)).foregroundStyle(.tertiary).padding(.top, 4)
            VStack(spacing: 6) {
                ForEach(filteredTabs) { item in tabButton(item) }
            }
            Spacer()
        }
        .padding(16)
        .frame(width: 218, alignment: .leading)
    }

    private var filteredTabs: [SettingsTab] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return SettingsTab.allCases }
        return SettingsTab.allCases.filter {
            $0.title.lowercased().contains(query) || $0.description.lowercased().contains(query)
                || ($0 == .judas
                    && "network lan thunderbolt local internet off-grid previews security privacy permissions activity hoofprint connections"
                        .contains(query))
        }
    }

    private func tabButton(_ item: SettingsTab) -> some View {
        let selected = model.settingsTab == item
        return Button {
            model.settingsTab = item
        } label: {
            HStack(spacing: 13) {
                Image(systemName: item.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 18)
                Text(item.title)
                    .font(.body.weight(.medium))
                Spacer()
            }
            .foregroundStyle(selected ? .white : Color.secondary)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(model.theme.tokens.tint)
                        .shadow(color: model.theme.tokens.glow.opacity(0.4), radius: 5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            LabeledContent("Default effort") {
                EffortDropdown(effort: $model.defaultEffort)
            }
            Section {
                Text("New chats start at this effort. You can change it per chat from the composer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle(isOn: $model.automaticChatTitles) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatic chat titles")
                    Text("Name new chats from the first exchange using your selected model. Manual names are kept.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Herd

struct HerdSettings: View {
    @Environment(AppModel.self) private var model
    @State private var gitInstallation: GitInstallationStatus?
    @State private var checkingGit = false

    var body: some View {
        Form {
            Section("Project folders") {
                LabeledContent("Default Herd location") {
                    Text(model.herdRootPath)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 8) {
                    Button("Choose Folder…") { chooseHerdRoot() }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.open(
                            URL(fileURLWithPath: model.herdRootPath, isDirectory: true))
                    }
                    .disabled(!FileManager.default.fileExists(atPath: model.herdRootPath))
                }
                Text(
                    "New Pens create their user-owned project folder here by default. Existing Pens and folders are never moved."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Git integration") {
                if checkingGit, gitInstallation == nil {
                    GoatLoadingIndicator("Checking Git…")
                        .controlSize(.small)
                } else if let gitInstallation {
                    Label(
                        gitInstallation.detail,
                        systemImage: gitInstallation.isAvailable
                            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(gitInstallation.isAvailable ? .green : .orange)
                    if let version = gitInstallation.version {
                        Text(version)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if gitInstallation.isAvailable, !gitInstallation.hasIdentity {
                        Label(
                            "Git identity is not configured. Status works, but a future commit action will need user.name and user.email.",
                            systemImage: "person.crop.circle.badge.exclamationmark"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                } else {
                    Text("Git has not been checked yet.")
                        .foregroundStyle(.secondary)
                }
                Button("Check Again") { Task { await refreshGitInstallation() } }
                    .disabled(checkingGit)
            }

            Section {
                Text(
                    "GOAT reads local Git status. If you explicitly choose Initialize Git repository for a new project folder, it runs git init only. It never fetches, stages, commits, switches branches, or contacts a remote repository."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task { await refreshGitInstallation() }
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

    private func refreshGitInstallation() async {
        checkingGit = true
        gitInstallation = await GitWorkspaceWorker.shared.installation()
        checkingGit = false
    }
}

// MARK: - Appearance

/// A little gradient pill - theme preview for the dropdown menu items.
struct ThemeSwatch: View {
    let spec: ThemeSpec

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(
                LinearGradient(
                    colors: [Color(hexString: spec.accent), Color(hexString: spec.accent2)],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .frame(width: 30, height: 14)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
            )
    }
}

/// Attached under the theme field: the gradient, then square swatches of every color used.
/// The theme preview: the hero preview image with the theme's gradient + colour swatches overlaid
/// as a strip along the bottom. Falls back to a bg→surface wash when there's no image. In Phase 2
/// the strip's gradient + swatches become the editable controls.
struct ThemePreviewCard: View {
    let spec: ThemeSpec
    var reloadToken = 0
    @State private var image: CGImage?

    private var swatches: [(String, Color)] {
        [
            ("accent", Color(hexString: spec.accent)),
            ("accent2", Color(hexString: spec.accent2)),
            ("glow", Color(hexString: spec.glow)),
            ("tint", Color(hexString: spec.tint)),
            ("selection", Color(hexString: spec.selection)),
            ("bg", Color(hexString: spec.bg)),
            ("surface", Color(hexString: spec.surface)),
            ("ink", Color(hexString: spec.ink)),
            ("muted", Color(hexString: spec.muted)),
        ]
    }

    @ViewBuilder private var content: some View {
        if ThemeCatalog.isBuiltin(spec.id) {
            Image("theme-preview-\(spec.id)").resizable().scaledToFill()
        } else if let image {
            Image(decorative: image, scale: 1).resizable().scaledToFill()
        } else {
            LinearGradient(
                colors: [Color(hexString: spec.bg), Color(hexString: spec.surface)],
                startPoint: .top, endPoint: .bottom)
        }
    }

    var body: some View {
        // Keep the preview at the image's real 16:9 shape (previews ship 16:9), so nothing is cropped.
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay { content }
            .overlay(alignment: .bottom) { strip }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.1)))
            .padding(.vertical, 4)
            .task(id: "\(spec.id):\(spec.preview ?? ""): \(reloadToken)") {
                image = nil
                guard !ThemeCatalog.isBuiltin(spec.id) else { return }
                let loaded = await ImageFileWorker.shared.themePreview(for: spec)
                guard !Task.isCancelled else { return }
                image = loaded
            }
    }

    private var strip: some View {
        VStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 5)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hexString: spec.accent), Color(hexString: spec.glow),
                            Color(hexString: spec.accent2),
                        ],
                        startPoint: .leading, endPoint: .trailing)
                )
                .frame(height: 10)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.2), lineWidth: 0.5))

            HStack(spacing: 6) {
                ForEach(swatches, id: \.0) { name, color in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: 20, height: 20)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                        .help(name)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }
}

struct AppearanceSettings: View {
    @Environment(AppModel.self) private var model
    @State private var appIcon = AppIconManager.current
    @State private var showImport = false
    @State private var editingTheme: ThemeSpec?
    @State private var pendingThemeDelete: ThemeSpec?
    @State private var exportCopied = false
    @State private var previewReloadToken = 0
    @State private var previewImportTask: Task<Void, Never>?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Theme", selection: $model.themeID) {
                    ForEach(model.availableThemes) { spec in
                        HStack(spacing: 8) {
                            ThemeSwatch(spec: spec)
                            Text(spec.displayName)
                        }
                        .tag(spec.id)
                    }
                }
                .pickerStyle(.menu)

                themeControls
            }

            TypographySettings()

            LabeledContent("Transparency") {
                VStack(spacing: 4) {
                    HStack {
                        Text("0%")
                        Spacer()
                        Text(model.windowTransparency, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .foregroundStyle(model.theme.tokens.ink)
                        Spacer()
                        Text("100%")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Slider(value: $model.windowTransparency, in: 0...1)
                        .accessibilityLabel("Window transparency")
                        .accessibilityValue(
                            model.windowTransparency.formatted(.percent.precision(.fractionLength(0)))
                        )
                        .help("0% is solid; 100% is maximum transparency. Each theme's default is at 40%.")
                    Button {
                        model.windowTransparency = CaprineBackground.defaultTransparency
                    } label: {
                        VStack(spacing: 2) {
                            Rectangle().fill(model.theme.tokens.tint).frame(width: 1, height: 5)
                            Text("Theme default · 40%")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.theme.tokens.tint)
                    .accessibilityLabel("Restore theme default transparency, 40 percent")
                    .help("Restore this theme's default transparency")
                    // Align the marker with 40% of the slider's usable track.
                    .offset(x: (CaprineBackground.defaultTransparency - 0.5) * 200)
                }
                .frame(width: 220)
            }

            Toggle(isOn: $model.animationsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Interface animations")
                    Text("Animate thinking text and interface transitions. Respects Reduce Motion.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if model.presentation.isUnlocked {
                Section("GOAT 1337") {
                    Toggle(
                        "Playful presentation",
                        isOn: Binding(
                            get: { model.presentation.isEnabled },
                            set: { model.setPlayfulPresentation($0) }))
                    Text("Mascots, effort icons, and alternate copy. Turning this off restores System appearance.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("App Icon") {
                HStack(spacing: 16) {
                    ForEach(availableIcons) { icon in
                        AppIconChoice(icon: icon, selected: selectedIcon == icon, tint: model.theme.tokens.tint) {
                            appIcon = icon
                            AppIconManager.apply(
                                icon, unlocked: model.presentation.isUnlocked, playful: model.presentation.isEnabled,
                                dark: model.theme.isDark)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                Text(
                    model.presentation.isUnlocked
                        ? "Changing the app icon keeps your current theme. Extra icons appear only with the 1337 theme."
                        : "Changing the app icon keeps your current theme."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onChange(of: model.presentation.isEnabled) { _, _ in appIcon = AppIconManager.current }
        .sheet(isPresented: $showImport) { ImportThemeSheet() }
        .sheet(item: $editingTheme) { spec in
            if let folder = ThemeStore.folder(for: spec.id) {
                JSONEditorSheet(
                    title: spec.name,
                    fileURL: folder.appendingPathComponent("theme.json"),
                    seed: ThemeStore.exportJSON(spec),
                    onSaved: { Task { await model.reloadThemes() } }
                )
            } else {
                Text("This theme has an invalid folder ID.")
                    .padding()
            }
        }
        .confirmationDialog(
            "Delete “\(pendingThemeDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingThemeDelete != nil }, set: { if !$0 { pendingThemeDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Theme", role: .destructive) {
                if let t = pendingThemeDelete {
                    Task { await model.deleteTheme(id: t.id) }
                }
                pendingThemeDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingThemeDelete = nil }
        } message: {
            Text("Removes its folder under ~/.goat/config/themes. This can't be undone.")
        }
        .onDisappear {
            previewImportTask?.cancel()
            previewImportTask = nil
        }
    }

    private var availableIcons: [AppIcon] {
        AppIconManager.available(unlocked: model.presentation.isUnlocked, playful: model.presentation.isEnabled)
    }

    private var selectedIcon: AppIcon {
        availableIcons.contains(appIcon) ? appIcon : .system
    }

    // MARK: Theme management (Phase 1: built-ins locked, user themes via JSON + preview)

    @ViewBuilder private var themeControls: some View {
        let selected = model.theme
        // System is a follow-the-OS alias, so preview the concrete theme it resolves to.
        let display =
            selected.appearance == .system
            ? (selected.isDark ? ThemeCatalog.midnight : ThemeCatalog.light)
            : selected
        ThemePreviewCard(spec: display, reloadToken: previewReloadToken)
        if ThemeCatalog.isBuiltin(selected.id) {
            HStack {
                Text("Built-in theme (read-only)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Duplicate to Edit…") {
                    Task { await model.duplicateTheme(from: selected) }
                }
                .font(.caption)
            }
        } else {
            HStack(spacing: 10) {
                Button("Edit JSON…") { editingTheme = selected }
                Button("Set Preview…") { pickPreview(for: selected.id) }
                Button("Export") { copyExport(selected) }
                if exportCopied { Text("Copied ✓").foregroundStyle(.green) }
                Spacer()
                Button("Delete…", role: .destructive) { pendingThemeDelete = selected }
            }
            .font(.caption)
        }
        Button("Import Theme…") { showImport = true }
            .font(.caption)
    }

    private func pickPreview(for id: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        GOATFileSelector.present(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            previewImportTask?.cancel()
            previewImportTask = Task { @MainActor in
                let images = await ImageFileWorker.shared.importImages(at: [url], maxDimension: 1600)
                guard let image = images.first, !Task.isCancelled else { return }
                await model.setThemePreview(id: id, imageData: image.pngData)
                previewReloadToken &+= 1
                previewImportTask = nil
            }
        }
    }

    private func copyExport(_ spec: ThemeSpec) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ThemeStore.exportJSON(spec), forType: .string)
        exportCopied = true
    }

}

/// A single tappable app-icon thumbnail in the Appearance picker.
private struct AppIconChoice: View {
    @Environment(AppModel.self) private var model
    let icon: AppIcon
    let selected: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(
                    icon == .system
                        ? (model.theme.isDark ? AppIcon.dark.assetName : AppIcon.light.assetName) : icon.assetName
                )
                .resizable()
                .interpolation(.high)
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            selected ? tint : Color.secondary.opacity(0.25),
                            lineWidth: selected ? 3 : 1)
                )
                .overlay(alignment: .bottomTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white, tint)
                            .background(Circle().fill(.white).padding(3))
                            .offset(x: 6, y: 6)
                    }
                }
                .shadow(color: selected ? tint.opacity(0.5) : .clear, radius: 6)
                Text(icon.label)
                    .font(.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .padding(7)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? tint.opacity(0.12) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Paste a GOAT theme (JSON) to add it as a new editable user theme.
private struct ImportThemeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    @State private var isImporting = false

    var body: some View {
        GOATDialogShell(closeAction: { dismiss() }, closeDisabled: isImporting) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Import Theme").font(.title3.weight(.semibold))
                Text("Paste a GOAT theme (JSON). It's added as a new, editable theme (docs/THEMES.md).")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minWidth: 460, minHeight: 240)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.3)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(model.theme.tokens.tint.opacity(0.25)))
                if let error {
                    Label(error, systemImage: "xmark.circle.fill").font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Paste from Clipboard") {
                        text = NSPasteboard.general.string(forType: .string) ?? text
                    }
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .buttonStyle(DialogCancelButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button("Import") {
                        Task {
                            isImporting = true
                            defer { isImporting = false }
                            do {
                                try await model.importTheme(json: text)
                                dismiss()
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isImporting || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 520)
        }
    }
}
