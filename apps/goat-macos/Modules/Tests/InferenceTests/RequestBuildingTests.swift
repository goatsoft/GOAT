import Foundation
import Testing

@testable import Inference

private func request(model: String, effort: Effort, turns: [ChatTurn]? = nil) -> GenerationRequest {
    GenerationRequest(
        model: model,
        turns: turns ?? [
            ChatTurn(role: .system, text: "You are GOAT."),
            ChatTurn(role: .user, text: "hi"),
        ],
        effort: effort
    )
}

private func encodeToJSON(_ r: GenerationRequest) throws -> [String: Any] {
    let data = try JSONEncoder().encode(OpenAICompatEngine.makeBody(for: r))
    return try JSONSerialization.jsonObject(with: data) as! [String: Any]
}

@Test func popularModelsReceiveGenericEffortWithoutProviderFields() throws {
    let modelIDs = [
        "deepseek-ai/DeepSeek-R1-Distill-Qwen3-32B",
        "deepseek-ai/DeepSeek-Coder-V2-Instruct",
        "Qwen/Qwen2.5-72B-Instruct",
        "Qwen/Qwen3-Coder-30B-A3B-Instruct",
        "Qwen/Qwen3.5-397B-A17B",
        "google/gemma-3-12b-it",
        "google/codegemma-7b-it",
        "meta-llama/Llama-4-Scout-17B-16E-Instruct",
        "meta-llama/CodeLlama-34b-Instruct-hf",
        "microsoft/Phi-4",
        "openai/gpt-oss-20b",
        "mistralai/Codestral-22B-v0.1",
        "mistralai/Mistral-Small-3.2-24B-Instruct",
        "nvidia/Llama-3.3-Nemotron-Super-49B-v1.5",
        "MiniMaxAI/MiniMax-M2.1",
        "moonshotai/Kimi-K2.5",
        "tencent/Hunyuan-A13B-Instruct",
        "inclusionAI/Ling-1T",
        "mistralai/Devstral-Small-2-24B-Instruct-2512",
        "bigcode/starcoder2-15b",
        "ibm-granite/granite-8b-code-instruct",
        "zai-org/GLM-4.7",
        "stepfun-ai/Step-3.5-Flash",
        "XiaomiMiMo/MiMo-V2-Flash",
    ]
    for modelID in modelIDs {
        for effort in Effort.allCases {
            let json = try encodeToJSON(request(model: modelID, effort: effort))
            let messages = json["messages"] as! [[String: Any]]
            let system = messages[0]["content"] as! String
            #expect(!system.contains("/no_think"), "unexpected name-derived control for \(modelID)")
            #expect(!system.hasSuffix("/think"), "unexpected name-derived control for \(modelID)")
            #expect(json["chat_template_kwargs"] == nil)
            #expect(json["reasoning_effort"] == nil)
            #expect(json["temperature"] as? Double == effort.temperature)
            #expect(json["max_tokens"] as? Int == effort.maxTokens)
        }
    }
}

@Test func nativeReasoningFieldRequiresExplicitCapabilitySnapshot() throws {
    let unknown = try encodeToJSON(request(model: "Qwen/Qwen3-Coder", effort: .summit))
    #expect(unknown["reasoning_effort"] == nil)

    let capabilities = ModelCapabilities(
        reasoning: .supported(by: .modelDetail),
        advertisedRequestParameters: ["reasoning_effort"],
        reasoningEffortValues: [.none, .low, .medium, .high])
    let explicit = GenerationRequest(
        model: "Qwen/Qwen3-Coder",
        turns: [ChatTurn(role: .user, text: "write code")],
        effort: .summit,
        modelCapabilities: capabilities)
    let encoded = try encodeToJSON(explicit)

    #expect(encoded["reasoning_effort"] as? String == "high")
}

@Test func qwenLocalTemplateMapsEffortAndReplaysReasoningSeparately() throws {
    let request = GenerationRequest(
        model: "Qwen/Qwen3.8-27B",
        turns: [
            ChatTurn(role: .user, text: "solve this"),
            ChatTurn(role: .assistant, text: "the answer", thinking: "first, inspect it"),
            ChatTurn(role: .user, text: "continue"),
        ],
        effort: .summit)
    let data = try JSONEncoder().encode(
        OpenAICompatEngine.makeBody(for: request, requestStyle: .qwenChatTemplate))
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

    #expect(json["temperature"] as? Double == 1.0)
    #expect(json["reasoning_effort"] == nil)
    let kwargs = json["chat_template_kwargs"] as? [String: Any]
    #expect(kwargs?["enable_thinking"] as? Bool == true)
    #expect(kwargs?["preserve_thinking"] as? Bool == true)
    #expect(kwargs?["reasoning_effort"] as? String == "xhigh")
    let messages = json["messages"] as! [[String: Any]]
    #expect(messages[1]["content"] as? String == "the answer")
    #expect(messages[1]["reasoning_content"] as? String == "first, inspect it")
}

@Test func qwenLocalGrazeDisablesThinkingWithoutSendingAnInvalidEffort() throws {
    let data = try JSONEncoder().encode(
        OpenAICompatEngine.makeBody(
            for: request(model: "Qwen/Qwen3.8-27B", effort: .graze),
            requestStyle: .qwenChatTemplate))
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

    #expect(json["temperature"] as? Double == 0.7)
    #expect(json["reasoning_effort"] == nil)
    let kwargs = json["chat_template_kwargs"] as! [String: Any]
    #expect(kwargs["enable_thinking"] as? Bool == false)
    #expect(kwargs["preserve_thinking"] as? Bool == true)
    #expect(kwargs["reasoning_effort"] == nil)
}

@Test func genericRequestsNeverReplayThinkingOrUseQwenFields() throws {
    let data = try JSONEncoder().encode(
        OpenAICompatEngine.makeBody(
            for: GenerationRequest(
                model: "generic",
                turns: [
                    ChatTurn(role: .assistant, text: "answer", thinking: "private chain"),
                    ChatTurn(role: .user, text: "next"),
                ],
                effort: .trot)))
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let messages = json["messages"] as! [[String: Any]]

    #expect(json["chat_template_kwargs"] == nil)
    #expect(messages[0]["reasoning_content"] == nil)
}

@Test func imageTurnEncodesOpenAIContentArray() throws {
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    let r = request(
        model: "mlx-community/Qwen2.5-VL-7B-4bit",
        effort: .trot,
        turns: [ChatTurn(role: .user, text: "what is this?", images: [png])]
    )
    let json = try encodeToJSON(r)
    let messages = json["messages"] as! [[String: Any]]
    let content = messages[0]["content"] as! [[String: Any]]
    #expect(content.count == 2)
    #expect(content[0]["type"] as? String == "image_url")
    let imageURL = (content[0]["image_url"] as! [String: Any])["url"] as! String
    #expect(imageURL.hasPrefix("data:image/png;base64,"))
    #expect(content[1]["type"] as? String == "text")
    #expect(content[1]["text"] as? String == "what is this?")
}

@Test func textOnlyTurnStaysPlainString() throws {
    let json = try encodeToJSON(request(model: "any-model", effort: .trot))
    let messages = json["messages"] as! [[String: Any]]
    #expect(messages[1]["content"] is String)
}

@Test func visionHeuristicSpotsTheObviousOnes() {
    let visionIDs = [
        "mlx-community/Qwen2.5-VL-7B-Instruct-4bit",
        "Qwen/Qwen2.5-Omni-7B",
        "google/gemma-3-4b-it",
        "google/gemma-4-E2B-it",
        "meta-llama/Llama-3.2-11B-Vision-Instruct",
        "meta-llama/Llama-4-Scout-17B-16E-Instruct",
        "mistralai/Mistral-Small-3.2-24B-Instruct",
        "mistral-small-2506",
        "mistralai/Ministral-3-8B-Instruct-2512",
        "microsoft/Phi-4-multimodal-instruct",
        "moonshotai/Kimi-K2.5",
        "zai-org/GLM-4.5V",
        "mlx-community/llava-1.5-7b-4bit",
    ]
    for modelID in visionIDs {
        #expect(ModelRef(id: modelID).looksVisionCapable, "missed vision model \(modelID)")
    }

    let textOnlyIDs = [
        "mlx-community/Qwen3-30B-A3B-4bit",
        "google/gemma-3-1b-it",
        "meta-llama/Llama-3.2-3B-Instruct",
        "mistralai/Mistral-7B-Instruct-v0.3",
        "microsoft/Phi-4",
        "deepseek-ai/DeepSeek-R1",
        "openai/gpt-oss-20b",
    ]
    for modelID in textOnlyIDs {
        #expect(!ModelRef(id: modelID).looksVisionCapable, "false vision hint for \(modelID)")
    }
}
