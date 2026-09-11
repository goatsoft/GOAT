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

    var body: some View {
        Button { showMenu.toggle() } label: {
            HStack(spacing: 6) {
                if model.modelCapabilitiesLoading, model.capabilityProbeModelID == activeModelID {
                    GoatLoadingIndicator().controlSize(.mini)
                }
                Text(projection.selectedDisplayName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(session.effort.label)
                    .foregroundStyle(session.effort.presentationColor(in: model.theme))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 12))
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Model and effort")
        .accessibilityValue("\(projection.selectedDisplayName), \(projection.selectedAvailability), \(session.effort.label)")
        .help("Model and effort - \(session.effort.blurb) (Command-1 through Command-4)")
        .popover(isPresented: $showMenu, arrowEdge: .bottom) {
            menuContent.frame(width: Caprine.ModelMenu.width)
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
                            twoLineRow(ref, selected: ref.id == activeModelID) {
                                model.selectModel(ref.id, in: session)
                                showMenu = false
                            }
                            .disabled(model.shepherd.hasActiveTurn || model.engineTransitioning)
                        }
                    }
                    ForEach(projection.unavailableFavourites, id: \.identity) { preference in
                        twoLineRow(ModelRef(id: preference.identity.modelID), selected: false, subtitle: "Unavailable") {}
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
                        Toggle(isOn: modelSelectionBinding(for: ref.id)) {
                            Text("\(ref.displayName) · \(subtitle(for: ref))")
                        }
                    }
                }
            }

            Divider().padding(.vertical, 4)
            submenu(title: "Effort", value: session.effort.label, disabled: false) {
                ForEach(Effort.allCases) { effort in
                    Toggle(isOn: effortBinding(for: effort)) {
                        Text("\(effort.label) - \(effort.blurb)")
                    }
                }
            }

            Divider().padding(.vertical, 4)
            plainRow("Manage Models…") {
                showMenu = false
                model.settingsTab = .models
                openSettings()
            }
            if model.engineAppURL != nil {
                plainRow("Open \(model.enginePreset.name)…") {
                    showMenu = false
                    model.openEngineApp()
                }
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

    private func submenu<Content: View>(title: String, value: String?, disabled: Bool, @ViewBuilder content: () -> Content) -> some View {
        Menu { content() } label: {
            HStack(spacing: Caprine.ModelMenu.spacing) {
                Text(title)
                Spacer()
                if let value { Text(value).foregroundStyle(.secondary) }
                Image(systemName: "chevron.right")
            }
            .padding(.horizontal, Caprine.ModelMenu.horizontalInset)
            .padding(.vertical, Caprine.ModelMenu.verticalInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .disabled(disabled)
        .accessibilityLabel(value.map { "\(title), \($0)" } ?? title)
    }

    private func modelSelectionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { activeModelID == id },
            set: { selected in
                guard selected, !model.shepherd.hasActiveTurn, !model.engineTransitioning else { return }
                model.selectModel(id, in: session)
                showMenu = false
            })
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

    private func twoLineRow(_ ref: ModelRef, selected: Bool, subtitle: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(ref.displayName).font(.system(size: 13, weight: .semibold))
                    Text(subtitle ?? self.subtitle(for: ref)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(model.theme.tokens.tint) }
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
