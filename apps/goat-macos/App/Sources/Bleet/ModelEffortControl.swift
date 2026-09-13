import Bleet
import Caprine
import Inference
import SwiftUI

struct ModelEffortControl: View {
    @Bindable var session: ChatSession
    @Binding var showMenu: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    private var projection: ModelMenuProjection {
        ModelMenuProjection(
            models: model.models, preferences: model.modelPreferences,
            engineProfileID: model.activeEngineProfile?.id,
            selectedModelID: model.resolvedModelID(for: session))
    }

    private var activeModelID: String? { model.resolvedModelID(for: session) }

    private var nativeMenuLabel: AttributedString {
        var modelPart = AttributedString(projection.selectedDisplayName)
        modelPart.foregroundColor = .white

        var separator = AttributedString(" · ")
        separator.foregroundColor = .secondary

        var effortPart = AttributedString(session.effort.label)
        effortPart.foregroundColor = session.effort.presentationColor(in: model.theme)

        modelPart.append(separator)
        modelPart.append(effortPart)
        return modelPart
    }

    var body: some View {
        Menu {
            nativeMenuContent
        } label: {
            Text(nativeMenuLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .tint(.white)
        .foregroundStyle(.white)
        .accessibilityLabel("Model and effort")
        .accessibilityValue(
            "\(projection.selectedDisplayName), \(projection.selectedAvailability), \(session.effort.label)"
        )
        .help("Model and effort - \(session.effort.blurb) (Command-1 through Command-4)")
    }

    @ViewBuilder
    private var nativeMenuContent: some View {
        let selected = projection.selectedModel
        let favourites = projection.favourites.filter { $0.id != selected?.id }
        let others = projection.otherModels.filter { $0.id != selected?.id }
        Section {
            if let selected {
                systemModelRow(
                    selected, favourite: projection.favourites.contains { $0.id == selected.id }
                )
                .disabled(model.shepherd.hasActiveTurn || model.engineTransitioning)
            }
            ForEach(favourites) { ref in
                systemModelRow(ref, favourite: true)
                    .disabled(model.shepherd.hasActiveTurn || model.engineTransitioning)
            }
            ForEach(projection.unavailableFavourites, id: \.identity) { preference in
                systemModelRow(
                    ModelRef(id: preference.identity.modelID), favourite: true,
                    subtitle: "Unavailable"
                )
                .disabled(true)
            }
            if selected == nil, favourites.isEmpty, projection.unavailableFavourites.isEmpty {
                Text("No models available")
            }
        } header: {
            Text("MODEL")
        }

        Menu("Other models") {
            if others.isEmpty {
                Text("No other models")
            } else {
                ForEach(others) { ref in
                    systemModelRow(ref)
                        .disabled(model.shepherd.hasActiveTurn || model.engineTransitioning)
                }
            }
        }
        .disabled(others.isEmpty)

        Menu("Effort") {
            ForEach(Effort.allCases) { effort in
                Toggle(isOn: effortBinding(for: effort)) {
                    Text("\(effort.label) - \(effort.blurb)")
                        .foregroundStyle(effort.presentationColor(in: model.theme))
                }
            }
        }

        Divider()
        Button("Manage Models…") {
            model.settingsTab = .models
            openSettings()
        }
        if model.activeEngineProfile != nil {
            Button("Refresh Models") { Task { await model.refreshModelCatalog() } }
        }
    }

    private func systemModelRow(
        _ ref: ModelRef, favourite: Bool = false, subtitle: String? = nil
    ) -> some View {
        Button {
            guard !model.shepherd.hasActiveTurn, !model.engineTransitioning else { return }
            model.selectModel(ref.id, in: session)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: ref.menuTypeSymbol)
                    .foregroundStyle(.white)
                Text("\(ref.displayName) · \(subtitle ?? self.subtitle(for: ref))")
                Spacer(minLength: 16)
                if favourite {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                }
                if ref.id == activeModelID {
                    Image(systemName: "checkmark").foregroundStyle(.white)
                }
            }
        }
    }

    private var menuContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("MODEL")
                .font(Caprine.ModelMenu.sectionFont.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, Caprine.ModelMenu.horizontalInset)
                .padding(.top, Caprine.ModelMenu.verticalInset)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if projection.favourites.isEmpty {
                        plainRow("Choose favourites in Models settings.") {
                            showMenu = false
                            model.settingsTab = .models
                            openSettings()
                        }
                    } else {
                        ForEach(projection.favourites) { ref in
                            twoLineRow(ref, selected: ref.id == activeModelID, favourite: true) {
                                model.selectModel(ref.id, in: session)
                                showMenu = false
                            }
                            .disabled(model.shepherd.hasActiveTurn || model.engineTransitioning)
                        }
                    }
                    ForEach(projection.unavailableFavourites, id: \.identity) { preference in
                        twoLineRow(
                            ModelRef(id: preference.identity.modelID), selected: false,
                            favourite: true, subtitle: "Unavailable"
                        ) {}
                        .disabled(true)
                    }
                }
            }
            .frame(maxHeight: Caprine.ModelMenu.maxListHeight)

            submenu(
                title: "Other models", value: projection.otherModels.isEmpty ? nil : "\(projection.otherModels.count)",
                disabled: projection.otherModels.isEmpty
            ) {
                if projection.otherModels.isEmpty {
                    Text("No other models")
                } else {
                    ForEach(projection.otherModels) { ref in
                        modelMenuRow(ref, selected: ref.id == activeModelID)
                    }
                }
            }

            Divider().padding(.vertical, 4)
            submenu(title: "Effort", value: session.effort.label, disabled: false) {
                ForEach(Effort.allCases) { effort in
                    Toggle(isOn: effortBinding(for: effort)) {
                        Text("\(effort.label) - \(effort.blurb)")
                            .foregroundStyle(effort.presentationColor(in: model.theme))
                    }
                }
            }

            Divider().padding(.vertical, 4)
            plainRow("Manage Models…") {
                showMenu = false
                model.settingsTab = .models
                openSettings()
            }
            if model.activeEngineProfile != nil {
                plainRow("Refresh Models") {
                    showMenu = false
                    Task { await model.refreshModelCatalog() }
                }
            }
        }
        .padding(.vertical, Caprine.ModelMenu.verticalInset)
    }

    private func submenu<Content: View>(
        title: String, value: String?, disabled: Bool, @ViewBuilder content: () -> Content
    ) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: Caprine.ModelMenu.spacing) {
                Text(title)
                Spacer()
                if let value { Text(value).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, Caprine.ModelMenu.horizontalInset)
            .padding(.vertical, Caprine.ModelMenu.verticalInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .disabled(disabled)
        .accessibilityLabel(value.map { "\(title), \($0)" } ?? title)
    }

    private func modelMenuRow(_ ref: ModelRef, selected: Bool) -> some View {
        Button {
            guard !model.shepherd.hasActiveTurn, !model.engineTransitioning else { return }
            model.selectModel(ref.id, in: session)
            showMenu = false
        } label: {
            HStack(spacing: 9) {
                Image(systemName: ref.looksVisionCapable ? "eye" : "cpu")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.secondary)
                Text("\(ref.displayName) · \(subtitle(for: ref))")
                Spacer(minLength: 12)
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.secondary)
                }
            }
            .font(Caprine.ModelMenu.titleFont)
            .padding(.horizontal, Caprine.ModelMenu.horizontalInset)
            .padding(.vertical, Caprine.ModelMenu.verticalInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private func effortBinding(for effort: Effort) -> Binding<Bool> {
        Binding(
            get: { session.effort == effort },
            set: { selected in
                guard selected else { return }
                model.selectEffort(effort, in: session)
                showMenu = false
            })
    }

    private func twoLineRow(
        _ ref: ModelRef, selected: Bool, favourite: Bool = false, subtitle: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if favourite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(ref.displayName).font(.system(size: 13, weight: .semibold))
                    Text(subtitle ?? self.subtitle(for: ref)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(
                        model.theme.tokens.tint)
                }
            }
            .padding(.horizontal, Caprine.ModelMenu.horizontalInset)
            .padding(.vertical, Caprine.ModelMenu.verticalInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func plainRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Caprine.ModelMenu.titleFont)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Caprine.ModelMenu.horizontalInset)
                .padding(.vertical, Caprine.ModelMenu.verticalInset)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func subtitle(for ref: ModelRef) -> String {
        var traits: [String] = []
        if ref.isCoderFocused { traits.append("Coder") }
        if ref.capabilities.vision.support == .supported || ref.looksVisionCapable { traits.append("Vision") }
        traits.append(ref.id.contains("/") ? String(ref.id.split(separator: "/")[0]) : "local")
        return traits.joined(separator: " · ")
    }
}

extension ModelRef {
    /// A distinct SF Symbol per model type for the compact model menus. Presentation only,
    /// derived from resolved capabilities and name heuristics; never authoritative.
    var menuTypeSymbol: String {
        let vision = capabilities.vision.support == .supported || looksVisionCapable
        let reasoning = capabilities.reasoning.support == .supported
        if isCoderFocused { return "chevron.left.forwardslash.chevron.right" }
        if vision && reasoning { return "sparkles" }
        if vision { return "eye" }
        if reasoning { return "brain" }
        return "cpu"
    }
}
