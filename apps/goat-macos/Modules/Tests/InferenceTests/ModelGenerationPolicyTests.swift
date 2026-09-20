import Foundation
import Testing

@testable import Inference

private func policyRequest(
    _ model: String, effort: Effort = .climb,
    capabilities: ModelCapabilities? = nil,
    override: SamplingOverride? = nil
) -> GenerationRequest {
    let family = ModelFamilyRegistry.profile(for: model, userFileURL: nil)
    let caps = capabilities ?? family?.capabilities ?? .unknown
    let compatibility = ModelCompatibilityResolver.resolve(
        identity: ModelIdentity(engineProfileID: "fixture", modelID: model),
        familyProfile: family, samplingOverride: override)
    return GenerationRequest(
        model: model,
        turns: [
            ChatTurn(role: .system, text: "Stable system"),
            ChatTurn(role: .user, text: "Build the project"),
        ], effort: effort,
        modelCapabilities: caps, compatibility: compatibility)
}

private func policyBody(_ request: GenerationRequest) throws -> [String: Any] {
    try #require(
        JSONSerialization.jsonObject(
            with: JSONEncoder().encode(
                OpenAICompatEngine.makeBody(for: request))) as? [String: Any])
}

@Test func museUsesPublishedSamplingAndEffortInActualWireRequest() throws {
    for (effort, strength) in [(Effort.graze, "low"), (.trot, "medium"), (.climb, "high"), (.summit, "xhigh")] {
        let request = policyRequest("Muse-Glimmer-30B-4bit", effort: effort)
        let body = try policyBody(request)
        #expect(body["temperature"] as? Double == 1)
        #expect(body["top_p"] as? Double == 0.95)
        #expect(body["top_k"] as? Int == 64)
        #expect(body["reasoning_effort"] == nil)
        #expect(body["chat_template_kwargs"] == nil)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect((messages[0]["content"] as? String)?.hasPrefix("Reasoning strength: \(strength).") == true)
    }
}

@Test func familySamplingIsIndependentOfEffortForFixedModeModels() throws {
    let cases: [(String, Double, Double?)] = [
        ("DeepSeek-R1", 0.6, 0.95), ("DeepSeek-V3.1", 0.6, 0.95), ("DeepSeek-V3.2", 1, 0.95),
        ("Qwen3-Coder-30B-A3B-Instruct", 0.7, 0.8), ("Qwen3-VL-8B-Thinking", 1, 0.95),
        ("Qwen3-VL-8B-Instruct", 0.7, 0.8), ("GLM-4.1V-9B-Thinking", 0.8, 0.6),
        ("GLM-4.5V", 1, 0.0001), ("GLM-4.6V", 0.8, 0.6), ("GLM-5", 1, 0.95),
        ("MiniMax-M2", 1, 0.95), ("Kimi-K2-Instruct", 0.6, nil), ("Kimi-K2-Thinking", 1, nil),
        ("Kimi-K2.5", 1, 0.95), ("Mistral-Small-3.2-24B-Instruct", 0.15, nil),
        ("Phi-4-reasoning", 0.8, 0.95), ("Seed-OSS-36B-Instruct", 1.1, 0.95),
    ]
    for (model, temperature, topP) in cases {
        for effort in Effort.allCases {
            let body = try policyBody(policyRequest(model, effort: effort))
            #expect(body["temperature"] as? Double == temperature, "\(model)")
            #expect(body["top_p"] as? Double == topP, "\(model)")
        }
    }
}

@Test func unknownModelsAndUnverifiedVariantsKeepEngineDefaults() throws {
    for name in [
        "unknown", "Qwen3.5-27B", "GLM-4.7V", "MiniMax-M2.99", "Muse-Glimmer-30B-assistant",
        "google/gemma-3-27b-it", "meta-llama/Llama-3.1-8B-Instruct",
    ] {
        let body = try policyBody(policyRequest(name))
        #expect(body["temperature"] == nil, "\(name)")
        #expect(body["top_p"] == nil, "\(name)")
        #expect(body["top_k"] == nil, "\(name)")
    }
}

@Test func qwenHybridUsesDocumentedSoftSwitchAndModeSampling() throws {
    let graze = try policyBody(policyRequest("Qwen3-32B", effort: .graze))
    let climb = try policyBody(policyRequest("Qwen3-32B", effort: .climb))
    #expect(graze["temperature"] as? Double == 0.7)
    #expect(graze["top_p"] as? Double == 0.8)
    #expect(climb["temperature"] as? Double == 0.6)
    #expect(climb["top_p"] as? Double == 0.95)
    #expect(graze["chat_template_kwargs"] == nil)
}

@Test func userSamplingReplacesFamilyAndExplicitEmptyMetadataVetoesIt() throws {
    let custom = SamplingOverride(temperature: 0.9)
    let request = policyRequest("Muse-Glimmer-30B", override: custom)
    let body = try policyBody(request)
    #expect(body["temperature"] as? Double == 0.9)
    #expect(body["top_p"] == nil)
    #expect(EffectiveGenerationParameters(request: request).samplingSource == .userOverride)
    let caps = ModelCapabilities(supportedRequestParameters: [])
    let vetoed = policyRequest("Muse-Glimmer-30B", capabilities: caps, override: custom)
    #expect(try policyBody(vetoed)["temperature"] == nil)
    #expect(EffectiveGenerationParameters(request: vetoed).omittedSamplingParameters == ["temperature"])
    let inherited = policyRequest("Muse-Glimmer-30B", override: SamplingOverride())
    #expect(try policyBody(inherited)["temperature"] == nil)
}

@Test func advertisedParameterAllowlistSurvivesParsingAndMerge() throws {
    let data = Data(#"{"data":[{"id":"Muse-Glimmer-30B","supported_parameters":["temperature","top_p"]}]}"#.utf8)
    let model = try #require(EngineCapabilityMetadataParser.openAIModelList(data).first)
    let request = policyRequest(model.id, capabilities: model.capabilities)
    let body = try policyBody(request)
    #expect(body["temperature"] as? Double == 1)
    #expect(body["top_k"] == nil)
    let merged = model.capabilities.merged(with: ModelCapabilities(supportedRequestParameters: ["temperature"]))
    #expect(merged.supportedRequestParameters == ["temperature"])
}

@Test func reasoningReplayFollowsEachPublishedHistoryContract() throws {
    for (name, oldExpected, currentExpected) in [
        ("Muse-Glimmer-30B", true, true),
        ("Kimi-K2.5", false, true), ("MiniMax-M2", false, true), ("GLM-4.7", false, true),
        ("Qwen3-32B", false, false), ("gpt-oss-20b", false, false),
    ] {
        var request = policyRequest(name)
        request.turns += [
            ChatTurn(role: .assistant, text: "Earlier", thinking: "Old reasoning"),
            ChatTurn(role: .user, text: "Continue"),
            ChatTurn(
                role: .assistant, text: "", thinking: "Current reasoning",
                toolCalls: [
                    ToolCallEvent(id: "call_0", name: "read", argumentsJSON: "{}")
                ]),
            ChatTurn(role: .tool, text: "file content", toolCallID: "call_0"),
        ]
        let messages = try #require(policyBody(request)["messages"] as? [[String: Any]])
        #expect((messages[2]["reasoning_content"] != nil) == oldExpected, "\(name)")
        #expect((messages[4]["reasoning_content"] != nil) == currentExpected, "\(name)")
        #expect(messages[4]["tool_calls"] != nil)
        #expect(messages[5]["tool_call_id"] as? String == "call_0")
    }
}

@Test func engineReasoningVetoAndNativeEffortTakePrecedence() throws {
    let caps = ModelCapabilities(
        reasoning: .supported(by: .modelDetail),
        reasoningHistory: .unsupported(by: .modelDetail), advertisedRequestParameters: ["reasoning_effort"])
    let request = policyRequest("Muse-Glimmer-30B", capabilities: caps)
    let parameters = EffectiveGenerationParameters(request: request)
    #expect(parameters.historyPolicy == .omit)
    #expect(parameters.reasoningInstruction == nil)
    #expect(try policyBody(request)["reasoning_effort"] as? String == "high")
}

@Test func canonicalPreparationPreservesIdentityAndIsIdempotent() throws {
    var request = policyRequest("Muse-Glimmer-30B")
    request.round = 7
    request.rejectedSamplingParameters = ["top_k"]
    let first = CanonicalRequestPreparation.prepare(request)
    let second = CanonicalRequestPreparation.prepare(first)
    #expect(first.turns.map(\.text) == second.turns.map(\.text))
    #expect(second.round == 7)
    #expect(second.rejectedSamplingParameters == ["top_k"])
    let plan = try PromptBudgeter().plan(request, model: ModelRef(id: request.model, contextLength: 32768))
    #expect(plan.request.round == 7)
    #expect(try policyBody(plan.request)["top_k"] == nil)
}

@Test func invalidSamplingIsRejectedAndLegacyPreferencesDecode() throws {
    #expect(!SamplingOverride(temperature: .nan).isValid)
    #expect(!SamplingOverride(topP: 0).isValid)
    #expect(!SamplingOverride(topK: -1).isValid)
    let raw = #"{"identity":{"engineProfileID":"e","modelID":"m"}}"#
    #expect(try JSONDecoder().decode(ModelPreference.self, from: Data(raw.utf8)).samplingOverride == nil)
    let invalid =
        #"{"schema":1,"families":[{"id":"bad","matchAny":["bad"],"generation":{"sampling":{"temperature":-1},"sources":[]}}]}"#
    #expect(ModelFamilyRegistry.decodeRules(from: Data(invalid.utf8)).isEmpty)
}

@Test func everyBundledRuleHasAuditableGenerationPolicy() {
    #expect(!ModelFamilyRegistry.builtInRules.isEmpty)
    for rule in ModelFamilyRegistry.builtInRules {
        #expect(rule.generation?.isValid == true, "\(rule.id)")
        #expect(rule.generation?.sources.isEmpty == false, "\(rule.id)")
    }
}

@Test func onlyExplicitSamplingRejectionsQualifyForRecovery() {
    #expect(
        EngineError.httpDetail(400, "Unsupported parameter: top_k", retryAfter: nil).rejectedSamplingParameter
            == "top_k")
    #expect(EngineError.httpDetail(400, "temperature out of range", retryAfter: nil).rejectedSamplingParameter == nil)
    #expect(EngineError.httpDetail(400, "unsupported tool_calls", retryAfter: nil).rejectedSamplingParameter == nil)
    #expect(EngineError.httpDetail(500, "unsupported temperature", retryAfter: nil).rejectedSamplingParameter == nil)
}

@Test func auditedGraniteVersionMatchesWithoutClaimingFutureVersions() {
    #expect(
        ModelFamilyRegistry.profile(for: "ibm-granite/granite-4.0-h-small", userFileURL: nil)?.ruleID == "granite-4")
    #expect(ModelFamilyRegistry.profile(for: "ibm-granite/granite-4.1-h-small", userFileURL: nil) == nil)
}

@Test func fixedModeQwenDoesNotInheritHybridTemplateControls() throws {
    let model = "Qwen3-Coder-30B-A3B-Instruct"
    let profile = ModelFamilyRegistry.profile(for: model, userFileURL: nil)
    let compatibility = ModelCompatibilityResolver.resolve(
        identity: ModelIdentity(engineProfileID: "fixture", modelID: model),
        override: .qwenChatTemplate, familyProfile: profile)
    let request = GenerationRequest(model: model, turns: [], effort: .graze, compatibility: compatibility)
    let body = try policyBody(request)
    #expect(body["temperature"] as? Double == 0.7)
    #expect(body["repetition_penalty"] as? Double == 1.05)
    #expect(body["chat_template_kwargs"] == nil)
}

@Test func currentCatalogVariantsUseTheirOwnPolicies() throws {
    let cases: [(String, String, Double, Double, Int?)] = [
        ("Qwen3-Coder-Next-MLX-4bit", "qwen3-coder-next", 1, 0.95, 40),
        ("Qwen3.8-27B-MLX-8bit", "qwen3.8-27b", 1, 0.95, 20),
        ("GLM-4.7-Flash-4bit", "glm-4.7-flash", 1, 0.95, nil),
        ("gemma-4-31B-it-MLX-6bit", "gemma-4-31b-it", 1, 0.95, 64),
    ]
    for (model, rule, temperature, topP, topK) in cases {
        let request = policyRequest(model)
        let body = try policyBody(request)
        #expect(request.compatibility.familyRuleID == rule)
        #expect(body["temperature"] as? Double == temperature)
        #expect(body["top_p"] as? Double == topP)
        #expect(body["top_k"] as? Int == topK)
    }
    #expect(ModelFamilyRegistry.profile(for: "gemma-4-12b-coder-fable5-composer2.5-4bit", userFileURL: nil) == nil)
    let qwen = try policyBody(policyRequest("Qwen3.8-27B"))
    #expect(qwen["presence_penalty"] as? Double == 0)
    #expect(EffectiveGenerationParameters(request: policyRequest("Qwen3.8-27B")).historyPolicy == .all)
}

@Test func checkpointEffortRestrictionsNarrowButNeverInventEngineSupport() {
    let unknown = policyRequest("Qwen3.8-27B")
    #expect(EffectiveGenerationParameters(request: unknown).nativeReasoningEffort == nil)
    let capabilities = ModelCapabilities(
        reasoning: .supported(by: .modelList),
        advertisedRequestParameters: ["reasoning_effort"])
    let request = policyRequest("Qwen3.8-27B", effort: .climb, capabilities: capabilities)
    #expect(EffectiveGenerationParameters(request: request).nativeReasoningEffort != "high")
    #expect(EffectiveGenerationParameters(request: request).nativeReasoningEffort != nil)
}

@Test func presencePenaltyValidatesPersistsAndHonorsEngineRestrictions() throws {
    let custom = SamplingOverride(presencePenalty: 1.5)
    #expect(try JSONDecoder().decode(SamplingOverride.self, from: JSONEncoder().encode(custom)) == custom)
    #expect(!SamplingOverride(presencePenalty: .infinity).isValid)
    #expect(!SamplingOverride(presencePenalty: 2.1).isValid)
    let request = policyRequest(
        "unknown", capabilities: ModelCapabilities(supportedRequestParameters: []), override: custom)
    #expect(try policyBody(request)["presence_penalty"] == nil)
    #expect(custom.removing(["presence_penalty"]).fields.isEmpty)
    #expect(
        EngineError.httpDetail(400, "Unsupported parameter: presence_penalty", retryAfter: nil)
            .rejectedSamplingParameter == "presence_penalty")
}

@Test func productionWireEncodingKeepsNestedSchemasStableAcrossRounds() throws {
    var request = policyRequest("Muse-Glimmer-30B")
    request.tools = [
        ToolSpec(
            name: "write_file", description: "Write text",
            parametersJSON:
                #"{"type":"object","required":["zulu","alpha"],"properties":{"zulu":{"type":"string","description":"Z"},"alpha":{"type":"string","description":"A"}}}"#
        )
    ]
    let first = try OpenAICompatEngine.encodedBody(for: request)
    let wire = String(decoding: first, as: UTF8.self)
    #expect(
        wire.contains(
            #""properties":{"alpha":{"description":"A","type":"string"},"zulu":{"description":"Z","type":"string"}}"#))
    #expect(wire.contains(#""required":["zulu","alpha"]"#))
    for round in 1...10 {
        request.round = round
        #expect(try OpenAICompatEngine.encodedBody(for: request) == first)
    }
}

@Test func engineManagedSamplingOmitsFamilyValuesButPreservesReasoningAndExplicitOverrides() throws {
    var request = policyRequest("Muse-Glimmer-30B-4bit")
    let original = EffectiveGenerationParameters(request: request)
    request.compatibility.generationSettingsOwner = .engineManaged
    let body = try policyBody(request)
    for key in ["temperature", "top_p", "top_k", "min_p", "repetition_penalty", "presence_penalty"] {
        #expect(body[key] == nil)
    }
    let managed = EffectiveGenerationParameters(request: request)
    #expect(managed.samplingSource == .engineDefault)
    #expect(managed.historyPolicy == original.historyPolicy)
    #expect(managed.reasoningInstruction == original.reasoningInstruction)
    request.compatibility.samplingOverride = SamplingOverride(temperature: 0.42)
    #expect(try policyBody(request)["temperature"] as? Double == 0.42)
    #expect(EffectiveGenerationParameters(request: request).samplingSource == .userOverride)
}

@Test func engineManagedQwenOverrideDoesNotReintroduceImplicitSampling() throws {
    var request = policyRequest("unknown")
    request.compatibility = ModelCompatibilityResolver.resolve(
        identity: ModelIdentity(engineProfileID: "fixture", modelID: "unknown"),
        override: .qwenChatTemplate, generationSettingsOwner: .engineManaged)
    let body = try policyBody(request)
    #expect(body["temperature"] == nil)
    #expect(body["top_p"] == nil)
    #expect(body["chat_template_kwargs"] != nil)
}
