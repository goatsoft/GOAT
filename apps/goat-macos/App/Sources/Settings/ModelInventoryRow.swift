import Caprine
import Inference
import SwiftUI

struct ModelInventoryRow: View {
    @Environment(AppModel.self) private var model
    let identity: ModelIdentity
    let modelRef: ModelRef?
    let isSelected: Bool
    let isUnavailable: Bool
    let onSelect: (() -> Void)?

    init(
        identity: ModelIdentity,
        modelRef: ModelRef?,
        isSelected: Bool,
        isUnavailable: Bool,
        onSelect: (() -> Void)? = nil
    ) {
        self.identity = identity
        self.modelRef = modelRef
        self.isSelected = isSelected
        self.isUnavailable = isUnavailable
        self.onSelect = onSelect
    }

    private var preference: ModelPreference? {
        model.modelPreferences.first { $0.identity == identity }
    }

    @State private var isHovering = false

    private var isCurrentChatModel: Bool {
        model.resolvedModelID(for: model.currentSession) == identity.modelID
    }

    var body: some View {
        HStack(spacing: Caprine.Models.spacing) {
            Button {
                Task { _ = await model.setModelFavourite(!(preference?.isFavourite ?? false), for: identity) }
            } label: {
                Image(systemName: preference?.isFavourite == true ? "star.fill" : "star")
                    .foregroundStyle(preference?.isFavourite == true ? .yellow : .secondary)
            }
            .buttonStyle(.borderless)
            .help(preference?.isFavourite == true ? "Remove favourite" : "Add favourite")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(modelRef?.displayName ?? identity.modelID)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if let modelRef {
                        Image(systemName: modelRef.menuTypeSymbol)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if isCurrentChatModel {
                        Text("Current")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
                Text(identity.modelID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isUnavailable {
                Text("Unavailable")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if isSelected && !isUnavailable {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .fontWeight(.semibold)
            }
        }
        .padding(.vertical, Caprine.Models.rowInset)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.16)
                        : (isHovering ? Color.primary.opacity(0.06) : Color.clear))
        )
        .contentShape(Rectangle())
        .opacity(isUnavailable ? 0.72 : 1)
        .onHover { isHovering = $0 }
        .onTapGesture { onSelect?() }
    }
}
