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
        if model.models.isEmpty {
            Button("No Models - Wake the Engine") { Task { await model.discover() } }
        } else {
            ForEach(model.models) { ref in
                Toggle(isOn: binding(for: ref.id)) {
                    Label {
                        Text("\(ref.displayName) - \(subtitle(for: ref))")
                    } icon: {
                        Image(systemName: ref.looksVisionCapable ? "eye" : "cpu")
                    }
                }
            }
        }
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

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { activeID == id },
            set: { isOn in
                guard isOn else { return }
                model.selectModel(id, in: model.currentSession)
            })
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
                } icon: {
                    if model.presentation.isEnabled { effort.goatie.image.resizable().frame(width: 16, height: 16) }
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
                session.effort = effort
                model.persistMeta(session)
            })
    }
}
