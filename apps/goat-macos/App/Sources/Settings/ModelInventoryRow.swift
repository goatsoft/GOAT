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
                    .foregroundStyle(
                        preference?.isFavourite == true ? Caprine.Semantic.favourite : model.theme.tokens.muted
                    )
            }
            .buttonStyle(.borderless)
            .help(preference?.isFavourite == true ? "Remove favourite" : "Add favourite")

            VStack(alignment: .leading, spacing: Caprine.Models.tightSpacing) {
                HStack(spacing: Caprine.Models.compactSpacing) {
                    Text(modelRef?.displayName ?? identity.modelID)
                        .font(Caprine.Models.rowTitleFont)
                        .lineLimit(1)
                    if let modelRef {
                        Image(systemName: modelRef.menuTypeSymbol)
                            .font(Caprine.Models.metadataFont)
                            .foregroundStyle(model.theme.tokens.muted)
                    }
                    if isCurrentChatModel {
                        Text("Current")
                            .font(Caprine.Models.badgeFont)
                            .foregroundStyle(model.theme.tokens.muted)
                            .padding(.horizontal, Caprine.Models.compactSpacing)
                            .padding(.vertical, Caprine.Models.borderWidth)
                            .background(
                                Capsule().fill(model.theme.tokens.muted.opacity(Caprine.Models.badgeOpacity))
                            )
                    }
                }
                Text(identity.modelID)
                    .font(Caprine.Models.detailFont)
                    .foregroundStyle(model.theme.tokens.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: Caprine.Models.controlInset)
            if isUnavailable {
                Text("Unavailable")
                    .font(Caprine.Models.badgeFont)
                    .foregroundStyle(model.theme.tokens.muted)
            }
            if isSelected && !isUnavailable {
                Image(systemName: "checkmark")
                    .foregroundStyle(model.theme.tokens.tint)
                    .fontWeight(.semibold)
            }
        }
        .padding(.vertical, Caprine.Models.rowInset)
        .padding(.horizontal, Caprine.Models.rowInset)
        .background(
            RoundedRectangle(cornerRadius: Caprine.Models.rowCornerRadius)
                .fill(
                    isSelected
                        ? model.theme.tokens.selection.opacity(Caprine.Models.selectionOpacity)
                        : (isHovering ? model.theme.tokens.ink.opacity(Caprine.Models.hoverOpacity) : Color.clear))
        )
        .contentShape(Rectangle())
        .opacity(isUnavailable ? Caprine.Models.unavailableOpacity : 1)
        .onHover { isHovering = $0 }
        .onTapGesture { onSelect?() }
    }
}
