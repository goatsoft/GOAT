import Foundation
import Testing

@testable import Inference

@Test func omlxStatusKeepsMissingTelemetryDistinctFromZero() throws {
    let status = try #require(
        OMLXStatusDecoder.decode(
            server: Data(#"{"version":"0.6.4","model_memory_used":0,"active_requests":0}"#.utf8), models: nil))
    #expect(status.version == "0.6.4")
    #expect(status.modelMemoryUsed == 0)
    #expect(status.activeRequests == 0)
    #expect(status.modelMemoryMaximum == nil)
    #expect(status.waitingRequests == nil)
    #expect(status.models == nil)
}

@Test func omlxStatusPreservesExactModelIDsAndConfiguredLimits() throws {
    let status = try #require(
        OMLXStatusDecoder.decode(
            server: nil,
            models: Data(
                #"{"models":[{"id":"org/Model","loaded":true,"is_loading":false,"max_context_window":262144,"model_context_length":131072,"max_tokens":32768},{"id":"org/model","loaded":false}]}"#
                    .utf8)))
    let models = try #require(status.models)
    #expect(models.map(\.id) == ["org/Model", "org/model"])
    #expect(models[0].contextWindow == 262_144)
    #expect(models[0].configuredOutputLimit == 32_768)
    #expect(models[0].loaded == true)
    #expect(models[1].configuredOutputLimit == nil)
}

@Test func omlxStatusRejectsInvalidNumbersAndOversizedResponses() throws {
    let status = try #require(
        OMLXStatusDecoder.decode(
            server: Data(#"{"active_requests":-1,"model_memory_max":0}"#.utf8),
            models: Data(#"{"models":[{"id":"m","max_tokens":-2,"max_context_window":0}]}"#.utf8)))
    #expect(status.activeRequests == nil)
    #expect(status.modelMemoryMaximum == nil)
    #expect(status.models?.first?.configuredOutputLimit == nil)
    #expect(status.models?.first?.contextWindow == nil)
    #expect(OMLXStatusDecoder.decode(server: Data(repeating: 32, count: 262_145), models: nil) == nil)
    #expect(OMLXStatusDecoder.decode(server: Data("invalid".utf8), models: nil) == nil)
}

@Test func genericEngineHasNoOptionalOMLXStatus() async throws {
    let url = try #require(URL(string: "http://127.0.0.1:1"))
    let engine = OpenAICompatEngine(config: EngineConfig(baseURL: url))
    #expect(await engine.runtimeStatus() == nil)
    #expect(EnginePreset.with(id: "omlx").metadataDialect == .omlx)
    #expect(EnginePreset.custom.metadataDialect == .generic)
}
