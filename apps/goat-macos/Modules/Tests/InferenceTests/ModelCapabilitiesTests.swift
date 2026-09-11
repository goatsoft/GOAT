import Foundation
import Testing

@testable import Inference

@Test func capabilityClaimsMergeWithoutTurningConflictsIntoSupport() {
    let listSupport = CapabilityClaim.supported(by: .modelList)
    let detailUnknown = CapabilityClaim(
        support: .unknown,
        evidence: [.modelDetail])
    let detailRejects = CapabilityClaim.unsupported(by: .modelDetail)

    let preserved = listSupport.merged(with: detailUnknown)
    #expect(preserved.support == .supported)
    #expect(preserved.evidence == [.modelList, .modelDetail])

    let conflict = listSupport.merged(with: detailRejects)
    #expect(conflict.support == .unknown)
    #expect(conflict.evidence == [.modelList, .modelDetail])
}

@Test func capabilityMergeAccumulatesParametersButIntersectsExplicitValues() {
    let modelList = ModelCapabilities(
        vision: .supported(by: .modelList),
        advertisedRequestParameters: [" Tools ", "REASONING_EFFORT"],
        reasoningEffortValues: [.low, .medium, .high])
    let detail = ModelCapabilities(
        tools: .supported(by: .modelDetail),
        reasoning: .supported(by: .modelDetail),
        advertisedRequestParameters: ["temperature", "reasoning_effort"],
        reasoningEffortValues: [.medium, .high, .xhigh])

    let merged = modelList.merged(with: detail)

    #expect(merged.vision.support == .supported)
    #expect(merged.tools.support == .supported)
    #expect(merged.reasoning.support == .supported)
    #expect(merged.advertisedRequestParameters == ["tools", "reasoning_effort", "temperature"])
    #expect(merged.reasoningEffortValues == [.medium, .high])
}

@Test func reasoningEffortIsNeverGuessedWithoutAnAdvertisedField() {
    let capabilities = ModelCapabilities(
        reasoning: .supported(by: .modelDetail),
        reasoningEffortValues: [.low, .medium, .high])

    for effort in Effort.allCases {
        #expect(capabilities.reasoningEffort(for: effort) == nil)
        #expect(capabilities.nativeReasoningEffort(for: effort) == nil)
    }
}

@Test func qwenReasoningReplayRequiresTheExplicitEngineRequestStyle() {
    #expect(!ModelCapabilities.unknown.replaysReasoningHistory)
    #expect(
        !ModelCapabilities.unknown
            .applying(requestStyle: .automatic)
            .replaysReasoningHistory)
    #expect(
        ModelCapabilities.unknown
            .applying(requestStyle: .qwenChatTemplate)
            .replaysReasoningHistory)
}

@Test func advertisedReasoningEffortUsesPortableDefaultsWhenValuesAreOmitted() {
    let capabilities = ModelCapabilities(
        reasoning: .supported(by: .modelList),
        advertisedRequestParameters: ["reasoning_effort"])

    #expect(capabilities.nativeReasoningEffort(for: .graze) == "low")
    #expect(capabilities.nativeReasoningEffort(for: .trot) == "medium")
    #expect(capabilities.nativeReasoningEffort(for: .climb) == "high")
    #expect(capabilities.nativeReasoningEffort(for: .summit) == "high")
}

@Test func reasoningEffortSelectsTheClosestAdvertisedValueConservatively() {
    let sparse = ModelCapabilities(
        reasoning: .supported(by: .modelDetail),
        advertisedRequestParameters: ["reasoning_effort"],
        reasoningEffortValues: [.none, .minimal, .low, .high, .xhigh])
    let tie = ModelCapabilities(
        reasoning: .supported(by: .modelDetail),
        advertisedRequestParameters: ["reasoning_effort"],
        reasoningEffortValues: [.low, .high])

    #expect(sparse.reasoningEffort(for: .graze) == ReasoningEffortValue.none)
    #expect(sparse.reasoningEffort(for: .trot) == .low)
    #expect(sparse.reasoningEffort(for: .climb) == .high)
    #expect(sparse.reasoningEffort(for: .summit) == .xhigh)
    #expect(tie.reasoningEffort(for: .trot) == .low)
}

@Test func conflictingReasoningEvidenceNeverEnablesANativeField() {
    let list = ModelCapabilities(
        reasoning: .supported(by: .modelList),
        advertisedRequestParameters: ["reasoning_effort"],
        reasoningEffortValues: [.low, .medium, .high])
    let detail = ModelCapabilities(
        reasoning: .unsupported(by: .modelDetail),
        advertisedRequestParameters: ["reasoning_effort"],
        reasoningEffortValues: [.low, .medium, .high])

    let conflict = list.merged(with: detail)

    #expect(conflict.reasoning.support == .unknown)
    #expect(conflict.nativeReasoningEffort(for: .summit) == nil)
}

@Test func explicitUnsupportedOrEmptyEffortValuesDisableNativeReasoning() {
    let unsupported = ModelCapabilities(
        reasoning: .unsupported(by: .modelDetail),
        advertisedRequestParameters: ["reasoning_effort"],
        reasoningEffortValues: [.high])
    let empty = ModelCapabilities(
        reasoning: .supported(by: .modelDetail),
        advertisedRequestParameters: ["reasoning_effort"],
        reasoningEffortValues: [])

    #expect(unsupported.reasoningEffort(for: .summit) == nil)
    #expect(empty.reasoningEffort(for: .summit) == nil)
}

@Test func wireReasoningValuesNormalizeCaseAndWhitespace() {
    #expect(ReasoningEffortValue(wireValue: " XHIGH \n") == .xhigh)
    #expect(ReasoningEffortValue(wireValue: "unknown") == nil)
}

@Test(
    arguments: [
        "mistralai/Devstral-Small-2507",
        "Qwen/Qwen2.5-Coder-32B-Instruct",
        "deepseek-ai/deepseek-coder-v2-instruct",
        "mistralai/Codestral-22B-v0.1",
        "meta-llama/CodeLlama-70b-Instruct-hf",
        "bigcode/starcoder2-15b",
        "ibm-granite/granite-8b-code-instruct",
        "google/codegemma-7b-it",
        "moonshotai/Kimi-Dev-72B",
        "infly/OpenCoder-8B-Instruct",
        "WizardLM/WizardCoder-Python-34B-V1.0",
        "acme/my-coder-model",
        "acme/code-instruct-14b",
        "acme/coding-assistant",
    ])
func coderFocusedNamesArePrioritized(modelID: String) {
    #expect(ModelNameHeuristics.isCoderFocused(modelID))
}

@Test(
    arguments: [
        "Qwen/Qwen3-32B",
        "deepseek-ai/DeepSeek-R1",
        "meta-llama/Llama-3.3-70B-Instruct",
        "google/gemma-3-27b-it",
        "acme/text-encoder-v2",
        "acme/audio-codec",
        "acme/decode-model",
    ])
func genericAndSubstringOnlyNamesStayNeutral(modelID: String) {
    #expect(!ModelNameHeuristics.isCoderFocused(modelID))
}

@Test func museFamilyProfileExcludesTextVariants() {
    #expect(KnownModelProfiles.profile(for: "Muse-Glimmer-30B-4bit") != nil)
    #expect(KnownModelProfiles.profile(for: "Muse-Glimmer-30B-Text-4bit") == nil)
}

@Test func userFamilyRulesAreAdditiveAndNeverOverrideBuiltIns() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("goat-model-families-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let document = ModelFamilyRegistryDocument(
        families: [
            ModelFamilyRule(
                id: "custom-vision",
                matchAny: ["acme/vision-model"],
                capabilities: ["vision"]),
            ModelFamilyRule(
                id: "attempted-muse-override",
                matchAny: ["muse-glimmer-30b"],
                capabilities: ["reasoning_history"]),
        ])
    try JSONEncoder().encode(document).write(to: url)

    let customProfile = try #require(
        ModelFamilyRegistry.profile(for: "acme/vision-model", userFileURL: url))
    #expect(customProfile.capabilities.vision.support == .supported)
    #expect(customProfile.capabilities.vision.evidence == [.userModelFamily])
    #expect(customProfile.capabilities.tools.support == .unknown)

    let builtIn = try #require(
        ModelFamilyRegistry.profile(for: "Muse-Glimmer-30B-4bit", userFileURL: url))
    #expect(builtIn.capabilities.reasoningHistory.support == .unknown)
    #expect(builtIn.capabilities.vision.evidence == [.modelFamily])
}

@Test func newerModelProbeOwnsPublication() async throws {
    let ownership = ModelCapabilityProbeOwnership()
    let oldTarget = ModelCapabilityProbeOwnership.Target(engineID: "engine", modelID: "old")
    let newTarget = ModelCapabilityProbeOwnership.Target(engineID: "engine", modelID: "coder")
    let old = await ownership.begin(target: oldTarget)
    let new = await ownership.begin(target: newTarget)
    let capabilities = ModelCapabilities(tools: .supported(by: .modelDetail))

    #expect(await ownership.resolve(capabilities, for: old) == nil)
    let resolution = try #require(await ownership.resolve(capabilities, for: new))
    #expect(resolution.target == newTarget)
    #expect(resolution.capabilities == capabilities)
    #expect(await ownership.isCurrent(resolution))
}

@Test func cancelledModelProbeCannotPublish() async {
    let ownership = ModelCapabilityProbeOwnership()
    let target = ModelCapabilityProbeOwnership.Target(engineID: "engine", modelID: "coder")
    let operation = await ownership.begin(target: target)
    let task = Task {
        await withTaskCancellationHandler {
            await Task.yield()
            return await ownership.resolve(.unknown, for: operation)
        } onCancel: {
        }
    }

    task.cancel()
    #expect(await task.value == nil)
}

@Test func olderCallerIntentCannotSupersedeNewerModelSelection() async throws {
    let ownership = ModelCapabilityProbeOwnership()
    let newTarget = ModelCapabilityProbeOwnership.Target(engineID: "engine", modelID: "new")
    let oldTarget = ModelCapabilityProbeOwnership.Target(engineID: "engine", modelID: "old")

    let newest = try #require(await ownership.begin(target: newTarget, intentRevision: 8))
    let stale = await ownership.begin(target: oldTarget, intentRevision: 7)

    #expect(stale == nil)
    #expect(await ownership.isCurrent(newest))
}

@Test(arguments: [
    ("mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit", ["tools"], [] as [String]),
    ("Qwen/Qwen3-30B-A3B-Thinking-2507", ["tools", "reasoning"], []),
    ("mlx-community/Qwen3-VL-8B-Thinking-8bit", ["vision", "tools", "reasoning"], []),
    ("Qwen3-VL-32B-Instruct", ["vision", "tools"], ["reasoning"]),
    ("mlx-community/Qwen3-8B-4bit", ["tools", "reasoning"], []),
    ("Qwen3-Embedding-8B", [], ["tools", "reasoning", "vision"]),
    ("openai/gpt-oss-20b", ["tools", "reasoning"], []),
    ("zai-org/GLM-4.5V", ["vision", "tools", "reasoning"], []),
    ("mlx-community/GLM-4.7-Flash-4bit", ["tools", "reasoning"], ["vision"]),
    ("deepseek-ai/DeepSeek-R1-0528-Qwen3-8B", ["reasoning"], ["tools"]),
    ("meta-llama/Llama-3.3-70B-Instruct", ["tools"], ["vision"]),
    ("meta-llama/Llama-Guard-3-8B", [], ["tools"]),
    ("google/gemma-3-27b-it", ["vision"], ["tools"]),
    ("mistralai/Mistral-Small-3.2-24B-Instruct-2506", ["vision", "tools"], []),
    ("moonshotai/Kimi-K2-Instruct", ["tools"], ["reasoning"]),
    ("moonshotai/Kimi-K2-Thinking", ["tools", "reasoning"], []),
    ("MiniMaxAI/MiniMax-M2", ["tools", "reasoning"], []),
])
func builtInFamilyRulesSupplyPositiveClaimsOnly(
    modelID: String, supported: [String], unknown: [String]
) {
    let profile = KnownModelProfiles.profile(for: modelID)
    func claim(_ name: String) -> CapabilityClaim? {
        switch name {
        case "vision": profile?.capabilities.vision
        case "tools": profile?.capabilities.tools
        case "reasoning": profile?.capabilities.reasoning
        default: nil
        }
    }
    for name in supported {
        #expect(claim(name)?.support == .supported, "\(modelID) should claim \(name)")
        #expect(claim(name)?.evidence == [.modelFamily], "\(modelID) \(name) evidence")
    }
    for name in unknown {
        #expect((claim(name)?.support ?? .unknown) == .unknown, "\(modelID) must not claim \(name)")
    }
    if supported.isEmpty { #expect(profile == nil) }
}

@Test func builtInFamilyRulesDeclareContextOnlyWhereStable() {
    #expect(KnownModelProfiles.profile(for: "openai/gpt-oss-120b")?.contextLength == 131_072)
    #expect(KnownModelProfiles.profile(for: "meta-llama/Llama-3.1-8B-Instruct")?.contextLength == 131_072)
    #expect(KnownModelProfiles.profile(for: "mlx-community/Qwen3-8B-4bit")?.contextLength == nil)
    #expect(KnownModelProfiles.profile(for: "zai-org/GLM-4.6")?.contextLength == nil)
}

@Test func familyRulesCarryStaticInspectionFactsAndIDsCarryPackagingHints() {
    let muse = KnownModelProfiles.profile(for: "Muse-Glimmer-30B-4bit")
    #expect(muse?.inspection?.architecture == "Muse-Glimmer")
    #expect(muse?.inspection?.parameterCount == 30_000_000_000)

    let mlx = EngineCapabilityMetadataParser.inspectionHints(fromModelID: "mlx-community/Qwen3-8B-4bit")
    #expect(mlx?.format == "MLX")
    #expect(mlx?.quantization == "4-bit")
    let gguf = EngineCapabilityMetadataParser.inspectionHints(fromModelID: "qwen3-8b-Q4_K_M.gguf")
    #expect(gguf?.format == "GGUF")
    #expect(gguf?.quantization == "Q4_K_M")
    #expect(EngineCapabilityMetadataParser.inspectionHints(fromModelID: "gpt-oss-20b") == nil)
}

@Test func rulesRequireEveryMatchAllTerm() {
    let rule = ModelFamilyRule(
        id: "thinking-only", matchAny: ["family"], matchAll: ["thinking"], capabilities: ["reasoning"])
    #expect(rule.matches("vendor/Family-8B-Thinking"))
    #expect(!rule.matches("vendor/Family-8B-Instruct"))
}
