import Foundation
import Testing

@testable import Inference

/// Explicit opt-in only. Uses the saved active profile and synthetic prompts, never chat history.
@Test(.enabled(if: ProcessInfo.processInfo.environment["GOAT_OMLX_LIVE_QUALIFICATION"] == "1"))
func omlxLiveOutputLimitContinuationAndCancellation() async throws {
    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".goat/config")
    let file = try #require(try EngineStore.load(from: directory.appendingPathComponent("engines.json")))
    let profile = try #require(file.engines.first { $0.id == file.active })
    #expect(profile.presetID == "omlx")
    let credentials = try JSONDecoder().decode(
        [String: String].self,
        from: Data(contentsOf: directory.appendingPathComponent("credentials.json")))
    let endpoint = try #require(URL(string: profile.url))
    let engine = OpenAICompatEngine(
        config: EngineConfig(
            baseURL: endpoint, apiKey: credentials["engine.\(profile.id).apiKey"], metadataDialect: .omlx))
    let initial = try #require(await engine.runtimeStatus())
    try #require(initial.activeRequests == 0 && initial.waitingRequests == 0, "Requires an idle engine")
    let modelID = ProcessInfo.processInfo.environment["GOAT_OMLX_LIVE_MODEL"] ?? "Qwen3.8-27B-MLX-4bit"
    let health = await engine.health()
    let model = try #require(health.models.first { $0.id == modelID })
    let family = ModelFamilyRegistry.profile(for: modelID)
    let compatibility = ModelCompatibilityResolver.resolve(
        identity: ModelIdentity(engineProfileID: profile.id, modelID: modelID), familyProfile: family,
        generationSettingsOwner: .engineManaged)
    var request = GenerationRequest(
        model: modelID,
        turns: [ChatTurn(role: .user, text: "Count from 1 through 1000, one number per line. Start now.")],
        effort: .graze, maxTokens: 32, modelCapabilities: model.capabilities, compatibility: compatibility)
    request = try PromptBudgeter().plan(request, model: model).request
    var emitted = ""
    var final: GenStats?
    for try await event in await engine.stream(request) {
        switch event {
        case .token(let text), .thinking(let text): emitted += text
        case .done(let stats): final = stats
        default: break
        }
    }
    #expect(!emitted.isEmpty)
    #expect(final?.finishReason == "length")
    request.turns.append(ChatTurn(role: .assistant, text: emitted))
    request.turns.append(ChatTurn(role: .user, text: "Continue counting from where you stopped."))
    var continuationBytes = 0
    for try await event in await engine.stream(request) {
        if case .token(let text) = event { continuationBytes += text.utf8.count }
        if case .thinking(let text) = event { continuationBytes += text.utf8.count }
    }
    #expect(continuationBytes > 0)

    request.maxTokens = 4096
    let cancellingRequest = request
    let started = LiveStreamStart()
    let consuming = Task {
        for try await event in await engine.stream(cancellingRequest) {
            switch event {
            case .token, .thinking: await started.mark()
            default: break
            }
        }
    }
    for _ in 0..<120 {
        if await started.value { break }
        try await Task.sleep(for: .milliseconds(250))
    }
    let didStart = await started.value
    consuming.cancel()
    _ = try? await consuming.value
    #expect(didStart)
    var released = false
    for _ in 0..<60 {
        let status = await engine.runtimeStatus()
        if status?.activeRequests == 0 && status?.waitingRequests == 0 {
            released = true
            break
        }
        try await Task.sleep(for: .milliseconds(250))
    }
    #expect(released, "Server must return to idle after closing the stream")
    print(
        "OMLX_LIVE model=\(modelID) version=\(initial.version ?? "unknown") context=\(model.contextLength ?? 0) server_output=\(model.serverOutputLimit ?? 0) request_output=32 finish=\(final?.finishReason ?? "unknown") continuation=\(continuationBytes > 0) cancellation_idle=\(released)"
    )
}

private actor LiveStreamStart {
    var value = false
    func mark() { value = true }
}
