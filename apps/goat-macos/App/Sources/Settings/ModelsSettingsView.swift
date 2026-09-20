import Caprine
import Inference
import SwiftUI

enum ModelFilterFacet: String, CaseIterable, Identifiable {
    case favourites, coder, vision, multimodal, thinking, tools
    var id: String { rawValue }
    var label: String {
        switch self {
        case .favourites: "Favourites"
        case .coder: "Coder"
        case .vision: "Vision"
        case .multimodal: "Multimodal"
        case .thinking: "Thinking"
        case .tools: "Tools"
        }
    }
    var symbol: String {
        switch self {
        case .favourites: "star.fill"
        case .coder: "chevron.left.forwardslash.chevron.right"
        case .vision: "eye"
        case .multimodal: "sparkles"
        case .thinking: "brain"
        case .tools: "wrench.and.screwdriver"
        }
    }
}

struct ModelsSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var search = ""
    @State private var activeFilters: Set<ModelFilterFacet> = []
    @State private var showFilters = false
    @State private var selection: ModelIdentity?
    @State private var showingModelResults = false
    @FocusState private var searchFocused: Bool

    private var engineID: String? { model.activeEngineProfile?.id }
    private var projection: ModelCatalogProjection? { model.modelCatalogProjection }
    private var filteredFavouriteModels: [ModelRef] { filter(projection?.availableFavourites ?? []) }
    private var filteredOtherModels: [ModelRef] { filter(projection?.availableOthers ?? []) }
    private var filteredUnavailable: [ModelPreference] {
        guard activeFilters.subtracting([.favourites]).isEmpty else { return [] }
        return (projection?.unavailableFavourites ?? []).filter { matches($0.identity.modelID) }
    }
    private var selectedModelRef: ModelRef? {
        guard let selection else { return nil }
        return model.models.first { $0.id == selection.modelID }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: Caprine.Models.spacing) {
                header
                if let selection {
                    ModelDetailView(identity: selection, modelRef: selectedModelRef, onClear: { self.selection = nil })
                } else {
                    // Centre the empty state under the search column, not the whole pane: the
                    // trailing hidden filter label reserves the same width the real control takes
                    // in the header, so the two share a horizontal centre.
                    HStack(spacing: Caprine.Models.spacing) {
                        ContentUnavailableView {
                            Label("Choose a model to inspect", systemImage: "square.stack.3d.up")
                        } description: {
                            Text(
                                "Search the configured engine's catalog to inspect a model's capabilities and metadata."
                            )
                        }
                        .frame(maxWidth: .infinity)
                        Button(action: {}) { filterButtonLabel }
                            .buttonStyle(.plain)
                            .hidden()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { dismissModelMenu() }
                }
            }
        }
        .padding(Caprine.Models.inset)
        .onChange(of: model.activeEngineProfile?.id) { _, _ in selection = nil }
        .onChange(of: selection) { _, value in
            if value != nil { dismissModelMenu() }
        }
        .onAppear { dismissModelMenu() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Caprine.Models.spacing) {
            HStack {
                VStack(alignment: .leading, spacing: Caprine.Models.tightSpacing) {
                    Text("Models").font(Caprine.Models.titleFont)
                    Text(engineSummary)
                        .font(Caprine.Models.metadataFont)
                        .foregroundStyle(model.theme.tokens.muted)
                }
                Spacer()
                Button {
                    Task { await model.refreshModelCatalog() }
                } label: {
                    Label(
                        "Refresh Models",
                        systemImage: model.modelCatalogRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                }
                .disabled(model.modelCatalogRefreshing || engineID == nil || model.shepherd.hasActiveTurn)
                .buttonStyle(.plain)
                .foregroundStyle(model.theme.tokens.muted)
                Button("Engine Settings…") {
                    model.settingsTab = .engine
                    openSettings()
                }
                .buttonStyle(SecondaryChipButtonStyle())
            }
            HStack(spacing: Caprine.Models.spacing) {
                modelSearchField
                filterControl
            }
        }
        .zIndex(showingModelResults ? 100 : 0)
    }

    private var modelSearchField: some View {
        HStack(spacing: Caprine.Models.compactSpacing) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(model.theme.tokens.muted)
            TextField("Search available models", text: $search)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit(selectFirstMatch)
            if !search.isEmpty {
                Button {
                    search = ""
                    searchFocused = true
                    showingModelResults = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(model.theme.tokens.muted)
                }
                .buttonStyle(.borderless)
            }
            Image(systemName: "chevron.down")
                .font(Caprine.Models.sectionFont)
                .foregroundStyle(model.theme.tokens.muted)
        }
        .padding(.horizontal, Caprine.Models.compactInset)
        .frame(height: Caprine.Models.controlHeight)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Caprine.Models.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Caprine.Models.cornerRadius)
                .stroke(
                    searchFocused
                        ? model.theme.tokens.tint
                        : model.theme.tokens.muted.opacity(Caprine.Models.borderOpacity),
                    lineWidth: Caprine.Models.borderWidth
                )
        }
        .overlay(alignment: .topLeading) {
            if showingModelResults {
                modelResultsDropdown
                    .offset(y: Caprine.Models.dropdownOffset)
                    .zIndex(10)
            }
        }
        .onChange(of: search) { _, _ in
            if searchFocused { showingModelResults = true }
        }
        .onChange(of: searchFocused) { _, focused in
            showingModelResults = focused
        }
    }

    private var modelResultsDropdown: some View {
        Group {
            if shouldShowEmptyState {
                emptyState
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: Caprine.Models.dropdownMinHeight)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            Color.clear
                                .frame(height: Caprine.Models.borderWidth)
                                .id("model-menu-top")
                            if !filteredFavouriteModels.isEmpty {
                                sectionHeader("Favourites")
                                ForEach(filteredFavouriteModels) { ref in
                                    resultRow(ref)
                                }
                            }
                            if !filteredOtherModels.isEmpty {
                                sectionHeader("Available")
                                ForEach(filteredOtherModels) { ref in
                                    resultRow(ref)
                                }
                            }
                            if !filteredUnavailable.isEmpty {
                                sectionHeader("Unavailable favourites")
                                ForEach(filteredUnavailable, id: \.identity) { preference in
                                    resultRow(
                                        identity: preference.identity,
                                        modelRef: nil,
                                        isUnavailable: true)
                                }
                            }
                        }
                        .padding(.vertical, Caprine.Models.tightSpacing)
                    }
                    .frame(
                        maxWidth: .infinity,
                        minHeight: Caprine.Models.dropdownHeight,
                        maxHeight: Caprine.Models.dropdownHeight
                    )
                    .onChange(of: showingModelResults) { _, isShowing in
                        if isShowing {
                            withAnimation(.none) {
                                proxy.scrollTo("model-menu-top", anchor: .top)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Caprine.Models.controlInset)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Caprine.Models.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Caprine.Models.cornerRadius)
                .stroke(
                    model.theme.tokens.muted.opacity(Caprine.Models.dropdownBorderOpacity),
                    lineWidth: Caprine.Models.borderWidth
                )
        }
        .shadow(
            color: .black.opacity(Caprine.Models.shadowOpacity),
            radius: Caprine.Models.shadowRadius,
            y: Caprine.Models.shadowOffset
        )
        .onExitCommand { dismissModelMenu() }
    }

    private func dismissModelMenu() {
        showingModelResults = false
        searchFocused = false
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Caprine.Models.sectionFont)
            .foregroundStyle(model.theme.tokens.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Caprine.Models.inset)
            .padding(.top, Caprine.Models.compactSpacing)
            .padding(.bottom, Caprine.Models.controlInset)
    }

    private func resultRow(_ ref: ModelRef) -> some View {
        resultRow(
            identity: ModelIdentity(engineProfileID: engineID ?? "", modelID: ref.id),
            modelRef: ref,
            isUnavailable: false)
    }

    private func resultRow(
        identity: ModelIdentity,
        modelRef: ModelRef?,
        isUnavailable: Bool
    ) -> some View {
        ModelInventoryRow(
            identity: identity,
            modelRef: modelRef,
            isSelected: selection == identity,
            isUnavailable: isUnavailable,
            onSelect: {
                selection = identity
                dismissModelMenu()
            }
        )
        .padding(.horizontal, Caprine.Models.rowInset)
    }

    private func row(for ref: ModelRef) -> some View {
        let identity = ModelIdentity(engineProfileID: engineID ?? "", modelID: ref.id)
        return ModelInventoryRow(
            identity: identity, modelRef: ref, isSelected: selection == identity, isUnavailable: false
        )
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
                Button("Open Engine Settings…") {
                    model.settingsTab = .engine
                    openSettings()
                }
            }
        } else if !model.health.isOK {
            ContentUnavailableView {
                Label("Model catalog unavailable", systemImage: "wifi.exclamationmark")
            } description: {
                Text(
                    "Connect the configured engine to discover models and inspect their capabilities. Saved favourites will remain here while it is offline."
                )
            } actions: {
                Button("Refresh Models") { Task { await model.refreshModelCatalog() } }
                Button("Open Engine Settings…") {
                    model.settingsTab = .engine
                    openSettings()
                }
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

    private func filter(_ values: [ModelRef]) -> [ModelRef] {
        values.filter { (matches($0.displayName) || matches($0.id)) && facetMatches($0) }
    }

    /// Favourites is an AND constraint; the type facets are OR among themselves, and a type facet
    /// matches any model that has that capability (Vision matches Muse-Glimmer, etc.).
    private func facetMatches(_ ref: ModelRef) -> Bool {
        if activeFilters.contains(.favourites), !isFavourite(ref) { return false }
        let typeFacets = activeFilters.subtracting([.favourites])
        guard !typeFacets.isEmpty else { return true }
        let vision = ref.capabilities.vision.support == .supported || ref.looksVisionCapable
        let reasoning = ref.capabilities.reasoning.support == .supported
        let tools = ref.capabilities.tools.support == .supported
        return typeFacets.contains { facet in
            switch facet {
            case .favourites: true
            case .coder: ref.isCoderFocused
            case .vision: vision
            case .multimodal: vision && reasoning
            case .thinking: reasoning
            case .tools: tools
            }
        }
    }

    private func isFavourite(_ ref: ModelRef) -> Bool {
        let identity = ModelIdentity(engineProfileID: engineID ?? "", modelID: ref.id)
        return model.modelPreferences.first { $0.identity == identity }?.isFavourite ?? false
    }

    private func toggleFilter(_ facet: ModelFilterFacet) {
        if activeFilters.contains(facet) {
            activeFilters.remove(facet)
        } else {
            activeFilters.insert(facet)
        }
    }

    private var filterButtonLabel: some View {
        HStack(spacing: Caprine.Models.compactSpacing) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(Caprine.Models.iconFont)
            // Always laid out (hidden when zero) so the search field never shifts as the count
            // appears or clears. The facet count is single-digit, so the pill width is stable.
            Text("\(activeFilters.count)")
                .font(Caprine.Models.sectionFont)
                .monospacedDigit()
                .foregroundStyle(model.theme.tokens.muted)
                .padding(.horizontal, Caprine.Models.compactSpacing)
                .padding(.vertical, Caprine.Models.borderWidth)
                .background(Capsule().fill(model.theme.tokens.muted.opacity(Caprine.Models.badgeOpacity)))
                .opacity(activeFilters.isEmpty ? 0 : 1)
        }
        .foregroundStyle(model.theme.tokens.muted)
        .frame(height: Caprine.Models.controlHeight)
        .contentShape(Rectangle())
    }

    private var filterControl: some View {
        Button {
            showFilters.toggle()
        } label: {
            filterButtonLabel
        }
        .buttonStyle(.plain)
        .help("Filter models")
        .popover(isPresented: $showFilters, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Caprine.Models.borderWidth * 2) {
                ForEach(ModelFilterFacet.allCases) { facet in
                    Button {
                        toggleFilter(facet)
                    } label: {
                        HStack(spacing: Caprine.Models.compactInset) {
                            Label(facet.label, systemImage: facet.symbol)
                            Spacer(minLength: Caprine.Models.iconSize)
                            Image(systemName: "checkmark")
                                .foregroundStyle(model.theme.tokens.tint)
                                .opacity(activeFilters.contains(facet) ? 1 : 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, Caprine.Models.controlInset)
                    .padding(.horizontal, Caprine.Models.controlInset)
                }
                if !activeFilters.isEmpty {
                    Divider()
                    Button("Clear filters") { activeFilters.removeAll() }
                        .buttonStyle(.plain)
                        .foregroundStyle(model.theme.tokens.muted)
                        .padding(.vertical, Caprine.Models.controlInset)
                        .padding(.horizontal, Caprine.Models.controlInset)
                }
            }
            .padding(Caprine.Models.compactInset)
            .frame(minWidth: Caprine.Models.popoverMinWidth, alignment: .leading)
        }
    }

    private func matches(_ value: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || value.localizedCaseInsensitiveContains(query)
    }

    private func selectFirstMatch() {
        let first = filteredFavouriteModels.first ?? filteredOtherModels.first
        guard let first else { return }
        selection = ModelIdentity(engineProfileID: engineID ?? "", modelID: first.id)
    }
}
