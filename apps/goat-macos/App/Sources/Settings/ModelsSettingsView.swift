import Caprine
import Inference
import SwiftUI

struct ModelsSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var search = ""
    @State private var favouritesOnly = false
    @State private var selection: ModelIdentity?

    private var engineID: String? { model.activeEngineProfile?.id }
    private var projection: ModelCatalogProjection? { model.modelCatalogProjection }
    private var filteredFavouriteModels: [ModelRef] { filter(projection?.availableFavourites ?? []) }
    private var filteredOtherModels: [ModelRef] { favouritesOnly ? [] : filter(projection?.availableOthers ?? []) }
    private var filteredUnavailable: [ModelPreference] {
        (projection?.unavailableFavourites ?? []).filter { matches($0.identity.modelID) }
    }
    private var selectedModelRef: ModelRef? {
        guard let selection else { return nil }
        return model.models.first { $0.id == selection.modelID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Caprine.Models.spacing) {
            header
            Divider()
            HSplitView {
                inventory
                    .frame(minWidth: Caprine.Models.listMinWidth, idealWidth: Caprine.Models.listIdealWidth)
                if let selection {
                    ModelDetailView(identity: selection, modelRef: selectedModelRef)
                } else {
                    ContentUnavailableView("Select a model", systemImage: "square.stack.3d.up")
                        .frame(minWidth: Caprine.Models.detailMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(Caprine.Models.inset)
        .onChange(of: model.activeEngineProfile?.id) { _, _ in selection = nil }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Caprine.Models.spacing) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Models").font(.title2.weight(.semibold))
                    Text(engineSummary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Engine Settings…") { model.settingsTab = .engine; openSettings() }
                Button {
                    Task { await model.refreshModelCatalog() }
                } label: {
                    Label("Refresh Models", systemImage: model.modelCatalogRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                }
                .disabled(model.modelCatalogRefreshing || engineID == nil || model.shepherd.hasActiveTurn)
            }
            HStack(spacing: Caprine.Models.spacing) {
                TextField("Search models", text: $search)
                    .textFieldStyle(.roundedBorder)
                Toggle("Favourites only", isOn: $favouritesOnly)
                    .toggleStyle(.checkbox)
            }
        }
    }

    private var inventory: some View {
        Group {
            if shouldShowEmptyState {
                emptyState
            } else {
                List(selection: $selection) {
                    if !filteredFavouriteModels.isEmpty {
                        Section("Favourites") {
                            ForEach(filteredFavouriteModels) { ref in row(for: ref) }
                        }
                    }
                    if !filteredOtherModels.isEmpty {
                        Section("Available") {
                            ForEach(filteredOtherModels) { ref in row(for: ref) }
                        }
                    }
                    if !filteredUnavailable.isEmpty {
                        Section("Unavailable favourites") {
                            ForEach(filteredUnavailable, id: \.identity) { preference in
                                let identity = preference.identity
                                ModelInventoryRow(identity: identity, modelRef: nil, isSelected: selection == identity, isUnavailable: true)
                                    .tag(identity)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func row(for ref: ModelRef) -> some View {
        let identity = ModelIdentity(engineProfileID: engineID ?? "", modelID: ref.id)
        return ModelInventoryRow(identity: identity, modelRef: ref, isSelected: selection == identity, isUnavailable: false)
            .tag(identity)
    }

    private var shouldShowEmptyState: Bool {
        filteredFavouriteModels.isEmpty && filteredOtherModels.isEmpty && filteredUnavailable.isEmpty
    }

    @ViewBuilder private var emptyState: some View {
        if engineID == nil {
            ContentUnavailableView {
                Label("No engine configured", systemImage: "cpu")
            } description: {
                Text("Add an engine to discover models and inspect their capabilities.")
            } actions: {
                Button("Open Engine Settings…") { model.settingsTab = .engine; openSettings() }
            }
        } else if !model.health.isOK {
            ContentUnavailableView {
                Label("Model catalog unavailable", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Connect the configured engine to discover models and inspect their capabilities. Saved favourites will remain here while it is offline.")
            } actions: {
                Button("Refresh Models") { Task { await model.refreshModelCatalog() } }
                Button("Open Engine Settings…") { model.settingsTab = .engine; openSettings() }
            }
        } else if model.models.isEmpty && search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView {
                Label("No models reported", systemImage: "square.stack.3d.up.slash")
            } description: {
                Text("Load a model in the configured engine, then refresh to inspect its capabilities.")
            } actions: {
                Button("Refresh Models") { Task { await model.refreshModelCatalog() } }
            }
        } else {
            ContentUnavailableView.search(text: search)
        }
    }

    private var engineSummary: String {
        guard let profile = model.activeEngineProfile else { return "No engine configured" }
        if case .offline(let message) = model.health { return "\(profile.name) - Offline: \(message)" }
        if case .authRequired = model.health { return "\(profile.name) - Authentication required" }
        return "\(profile.name) - \(model.models.count) model\(model.models.count == 1 ? "" : "s") available"
    }

    private func filter(_ values: [ModelRef]) -> [ModelRef] { values.filter { matches($0.id) } }

    private func matches(_ value: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || value.localizedCaseInsensitiveContains(query)
    }
}
