import Caprine
import Inference
import SwiftUI

// Menu rows for the current chat's model and effort, shared by the menu-bar Chat menu. Each row
// carries an icon and a one-line description so the menu echoes the composer's goatie rows as
// closely as a native macOS menu allows (menus can't host the popover's two-line sprite rows,
// but they do show a leading image + text + checkmark). Commands don't get the SwiftUI
// environment, so these read the shared AppModel directly.

/// The available models as checkable rows - "name - vision · org", with a chip icon.
struct ModelMenuItems: View {
    private var model: AppModel { .shared }

    var body: some View {
        let projection = ModelMenuProjection(
            models: model.models, preferences: model.modelPreferences,
            engineProfileID: model.activeEngineProfile?.id, selectedModelID: activeID)
        if model.models.isEmpty && projection.unavailableFavourites.isEmpty {
            if model.activeEngineProfile == nil {
                Button("Set Up an Engine to Inspect Models") { model.settingsTab = .engine }
            } else {
                Button("No Models - Refresh Engine") { Task { await model.refreshModelCatalog() } }
            }
        } else {
            let selected = projection.selectedModel
            let favourites = projection.favourites.filter { $0.id != selected?.id }
            let others = projection.otherModels.filter { $0.id != selected?.id }
            if let selected {
                modelRow(selected, favourite: projection.favourites.contains { $0.id == selected.id })
                    .disabled(model.shepherd.hasActiveTurn || model.engineTransitioning)
            }
            ForEach(favourites) { ref in
                modelRow(ref, favourite: true)
                    .disabled(model.shepherd.hasActiveTurn || model.engineTransitioning)
            }
            ForEach(projection.unavailableFavourites, id: \.identity) { preference in
                Label {
                    Text("\(ModelRef(id: preference.identity.modelID).displayName) - Unavailable")
                } icon: {
                    Image(systemName: "star.fill").foregroundStyle(Caprine.Semantic.favourite)
                }
            }
            Menu("Other models") {
                if others.isEmpty {
                    Text("No other models")
                } else {
                    ForEach(others) { ref in
                        modelRow(ref, favourite: false)
                            .disabled(model.shepherd.hasActiveTurn || model.engineTransitioning)
                    }
                }
            }
            .disabled(others.isEmpty)
        }
        Divider()
        SubagentModelMenu(model: model, parentModelID: activeID)
    }

    private var activeID: String? { model.resolvedModelID(for: model.currentSession) }

    private func subtitle(for ref: ModelRef) -> String {
        let org = ref.id.contains("/") ? String(ref.id.split(separator: "/")[0]) : "local"
        var traits: [String] = []
        if ref.isCoderFocused { traits.append("Coder") }
        let vision =
            switch ref.capabilities.vision.support {
            case .supported: true
            case .unsupported: false
            case .unknown: ref.looksVisionCapable
            }
        if vision { traits.append("Vision") }
        traits.append(org)
        return traits.joined(separator: " · ")
    }

    private func modelRow(_ ref: ModelRef, favourite: Bool) -> some View {
        Button {
            model.selectModel(ref.id, in: model.currentSession)
        } label: {
            HStack(spacing: Caprine.ModelMenu.systemRowSpacing) {
                Image(systemName: ref.menuTypeSymbol)
                    .foregroundStyle(Caprine.Semantic.onAccent)
                Text("\(ref.displayName) - \(subtitle(for: ref))")
                Spacer(minLength: Caprine.ModelMenu.rowSpacer)
                if favourite {
                    Image(systemName: "star.fill").foregroundStyle(Caprine.Semantic.favourite)
                }
                if activeID == ref.id {
                    Image(systemName: "checkmark").foregroundStyle(Caprine.Semantic.onAccent)
                }
            }
        }
    }
}

/// The effort levels as checkable rows (⌘1-⌘n) - the effort goatie + "name - blurb".
struct EffortMenuItems: View {
    private var model: AppModel { .shared }

    var body: some View {
        ForEach(Array(Effort.allCases.enumerated()), id: \.element) { index, effort in
            Toggle(isOn: binding(for: effort)) {
                Label {
                    Text("\(effort.label) - \(effort.blurb)")
                        .foregroundStyle(effort.presentationColor(in: model.theme))
                } icon: {
                    if model.presentation.isEnabled {
                        effort.goatie.image.resizable().frame(
                            width: Caprine.ModelMenu.iconSize,
                            height: Caprine.ModelMenu.iconSize
                        )
                    }
                }
            }
            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        }
    }

    private func binding(for effort: Effort) -> Binding<Bool> {
        Binding(
            get: { model.currentSession?.effort == effort },
            set: { isOn in
                guard isOn, let session = model.currentSession else { return }
                model.selectEffort(effort, in: session)
            })
    }
}

/// Shared by the composer, inspector and menu bar; selection remains engine-scoped.
struct SubagentModelMenu: View {
    @Bindable var model: AppModel
    let parentModelID: String?
    @Environment(\.openSettings) private var openSettings

    private var selectionLocked: Bool {
        model.shepherd.hasActiveTurn || model.engineTransitioning || model.extensionsChanging
    }

    var body: some View {
        let projection = SubagentMenuProjection(
            models: model.models, parentModelID: parentModelID, hasLocalEngine: model.toolRouter.isEngineLocal())
        let selected = model.selectedSubagentModelID
        Menu {
            if let reason = projection.unavailableReason {
                Text(reason)
            }
            Toggle(
                "Enable Subagents",
                isOn: Binding(
                    get: { model.memory.builtInSettings.subagentsEnabled },
                    set: { enabled in
                        guard !selectionLocked else { return }
                        model.memory.builtInSettings.subagentsEnabled = enabled
                    })
            )
            .disabled(selectionLocked || projection.unavailableReason != nil)
            Picker(
                "Worker model",
                selection: Binding(
                    get: { model.selectedSubagentModelID ?? "" },
                    set: { value in
                        guard !selectionLocked, projection.unavailableReason == nil,
                            let engineID = model.activeEngineProfile?.id
                        else { return }
                        model.memory.builtInSettings.setSubagentModelID(value.isEmpty ? nil : value, for: engineID)
                    })
            ) {
                Text("Not selected").tag("")
                ForEach(projection.workers) { worker in
                    Text(worker.displayName + (worker.id == parentModelID ? " (same as parent)" : ""))
                        .tag(worker.id)
                }
                if let selected, !projection.workers.contains(where: { $0.id == selected }) {
                    Text("Unavailable: \(ModelRef(id: selected).displayName)").tag(selected)
                }
            }
            .disabled(selectionLocked || projection.unavailableReason != nil)
            if projection.workers.isEmpty { Text("No supported workers in this engine's catalogue.") }
            if !model.memory.builtInSettings.herderEnabled { Text("Enable Herder in Extensions to investigate files.") }
            Text("Load both models in the engine. Memory is checked before delegation.")
            Divider()
            Button("Subagent Settings…") {
                model.settingsTab = .goated
                openSettings()
            }
        } label: {
            Text("Subagent: " + (selected.map { ModelRef(id: $0).displayName } ?? "Not selected"))
        }
    }
}
