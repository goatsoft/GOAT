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
                Text(modelRef?.displayName ?? identity.modelID)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
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
        .contentShape(Rectangle())
        .opacity(isUnavailable ? 0.72 : 1)
        .onTapGesture { onSelect?() }
    }
}
