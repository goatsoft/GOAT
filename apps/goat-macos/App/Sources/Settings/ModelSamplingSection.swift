import Caprine
import Inference
import SwiftUI

struct ModelSamplingSection: View {
    @Environment(AppModel.self) private var model
    let identity: ModelIdentity
    let modelRef: ModelRef
    @State private var custom = false
    @State private var temperature = ""
    @State private var topP = ""
    @State private var topK = ""
    @State private var minP = ""
    @State private var repetitionPenalty = ""
    @State private var presencePenalty = ""
    @State private var notice: String?

    private var preference: ModelPreference? { model.modelPreferences.first { $0.identity == identity } }
    private var policy: ModelGenerationPolicy? { ModelFamilyRegistry.profile(for: identity.modelID)?.generation }
    private var parameters: EffectiveGenerationParameters {
        let compatibility = model.generationContext(for: identity.modelID)?.compatibility
        return EffectiveGenerationParameters(
            request: GenerationRequest(
                model: identity.modelID, turns: [], effort: model.currentSession?.effort ?? .trot,
                modelCapabilities: modelRef.capabilities, compatibility: compatibility))
    }

    var body: some View {
        SectionCard(title: "Generation", systemImage: "slider.horizontal.3") {
            Picker(
                "Sampling managed by",
                selection: Binding(
                    get: { model.activeEngineProfile?.generationSettingsOwner ?? .goatManaged },
                    set: { owner in
                        guard var profile = model.activeEngineProfile,
                            profile.id == identity.engineProfileID
                        else { return }
                        profile.generationSettingsOwner = owner
                        Task {
                            if !(await model.addOrUpdateEngine(profile, connect: false)) {
                                notice = "Sampling ownership could not be saved."
                            }
                        }
                    })
            ) {
                Text("Engine").tag(GenerationSettingsOwner.engineManaged)
                Text("GOAT").tag(GenerationSettingsOwner.goatManaged)
            }
            Text("Applies to this engine. Explicit per-model sampling values still take precedence.")
                .font(Caprine.Models.metadataFont).foregroundStyle(model.theme.tokens.muted)
            LabeledContent("Requested sampling", value: parameters.sampling.summary)
            Text("The engine may apply its own overrides. These values describe the request.")
                .font(Caprine.Models.metadataFont).foregroundStyle(model.theme.tokens.muted)
            LabeledContent("Source", value: parameters.samplingSource.rawValue)
            if let rule = parameters.familyRuleID { LabeledContent("Family rule", value: rule) }
            LabeledContent(
                "Reasoning",
                value: parameters.reasoningInstruction
                    ?? parameters.nativeReasoningEffort ?? "Engine default")
            LabeledContent("Reasoning history", value: parameters.historyPolicy.rawValue)
            if !parameters.omittedSamplingParameters.isEmpty {
                Text("Engine does not support: " + parameters.omittedSamplingParameters.joined(separator: ", "))
                    .font(Caprine.Models.metadataFont).foregroundStyle(model.theme.tokens.muted)
            }
            if let note = policy?.note {
                Text(note).font(Caprine.Models.metadataFont).foregroundStyle(model.theme.tokens.muted)
            }
            ForEach(policy?.sources ?? [], id: \.self) { source in
                if let url = URL(string: source) {
                    Link("Published model guidance", destination: url).font(Caprine.Models.metadataFont)
                }
            }
            Toggle("Custom sampling", isOn: $custom)
            if custom {
                Text("Blank fields use engine defaults. Custom values replace the family recommendation.")
                    .font(Caprine.Models.metadataFont).foregroundStyle(model.theme.tokens.muted)
                TextField("Temperature (0–2)", text: $temperature)
                TextField("Top p (greater than 0, up to 1)", text: $topP)
                TextField("Top k (0 or greater)", text: $topK)
                TextField("Min p (0–1)", text: $minP)
                TextField("Repetition penalty (greater than 0, up to 2)", text: $repetitionPenalty)
                TextField("Presence penalty (-2 to 2)", text: $presencePenalty)
            }
            HStack {
                Button("Apply") { Task { await apply() } }
                Button("Clear Custom Sampling") {
                    Task {
                        if await model.setSamplingOverride(nil, for: identity) {
                            load()
                            notice = nil
                        } else {
                            notice = "Sampling preferences could not be saved."
                        }
                    }
                }
            }
            if let notice {
                Text(notice).font(Caprine.Models.metadataFont).foregroundStyle(model.theme.tokens.muted)
            }
        }
        .disabled(model.shepherd.hasActiveTurn || model.engineTransitioning)
        .onAppear { load() }
        .onChange(of: identity) { _, _ in
            load()
            notice = nil
        }
    }

    private func load() {
        let value = preference?.samplingOverride
        custom = value != nil
        temperature = value?.temperature.map(String.init(describing:)) ?? ""
        topP = value?.topP.map(String.init(describing:)) ?? ""
        topK = value?.topK.map(String.init(describing:)) ?? ""
        minP = value?.minP.map(String.init(describing:)) ?? ""
        repetitionPenalty = value?.repetitionPenalty.map(String.init(describing:)) ?? ""
        presencePenalty = value?.presencePenalty.map(String.init(describing:)) ?? ""
    }

    private func apply() async {
        let values = [temperature, topP, minP, repetitionPenalty, presencePenalty].map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let integer = topK.trimmingCharacters(in: .whitespaces)
        guard
            !custom
                || (values.allSatisfy { $0.isEmpty || Double($0) != nil }
                    && (integer.isEmpty || Int(integer) != nil))
        else {
            notice = "Enter numeric values within the displayed ranges."
            return
        }
        let sampling =
            custom
            ? SamplingOverride(
                temperature: Double(values[0]), topP: Double(values[1]),
                topK: Int(integer), minP: Double(values[2]), repetitionPenalty: Double(values[3]),
                presencePenalty: Double(values[4])) : nil
        guard sampling?.isValid ?? true else {
            notice = "Enter numeric values within the displayed ranges."
            return
        }
        notice =
            await model.setSamplingOverride(sampling, for: identity)
            ? "Sampling preferences saved." : "Sampling preferences could not be saved."
    }
}
