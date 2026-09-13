import Caprine
import Inference
import SwiftUI

struct ModelCompatibilitySection: View {
    @Environment(AppModel.self) private var model
    let identity: ModelIdentity
    let review: LegacyCompatibilityReview?
    @State private var selectedLegacyModelID = ""

    private var preference: ModelPreference? {
        model.modelPreferences.first { $0.identity == identity }
    }

    var body: some View {
        Section("Compatibility") {
            Picker("Request format", selection: overrideBinding) {
                Text("Automatic").tag(ModelCompatibilityOverride.automatic)
                Text("Generic OpenAI-compatible").tag(ModelCompatibilityOverride.genericOpenAI)
                Text("Qwen chat template").tag(ModelCompatibilityOverride.qwenChatTemplate)
            }
            .pickerStyle(.menu)
            .disabled(model.shepherd.hasActiveTurn || model.engineTransitioning)

            if let review, review.state == .pending {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Review migrated engine compatibility", systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout.weight(.medium))
                    Text(
                        "The old engine-wide setting was \(review.legacyStyle == .qwenChatTemplate ? "Qwen chat template" : "automatic"). Assign it to one model or discard it before relying on per-model compatibility."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    HStack {
                        Picker("Model", selection: $selectedLegacyModelID) {
                            Text("Choose a model").tag("")
                            ForEach(model.models) { ref in
                                Text(ref.displayName).tag(ref.id)
                            }
                        }
                        .pickerStyle(.menu)
                        Button("Apply to Selected Model") {
                            Task {
                                _ = await model.resolveLegacyCompatibility(
                                    for: identity.engineProfileID,
                                    assignTo: selectedLegacyModelID.isEmpty ? nil : selectedLegacyModelID)
                            }
                        }
                        .disabled(selectedLegacyModelID.isEmpty || model.shepherd.hasActiveTurn)
                        Button("Use Automatic") {
                            Task { _ = await model.discardLegacyCompatibility(for: identity.engineProfileID) }
                        }
                    }
                }
            }
        }
        .onAppear { selectedLegacyModelID = review?.assignedModelID ?? "" }
    }

    private var overrideBinding: Binding<ModelCompatibilityOverride> {
        Binding(
            get: { preference?.compatibilityOverride ?? .automatic },
            set: { value in Task { _ = await model.setCompatibilityOverride(value, for: identity) } })
    }
}
