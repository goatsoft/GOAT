import Foundation
import Testing

@testable import Inference

private func fixture(_ json: String) -> Data { Data(json.utf8) }

@Test func openAIModelCatalogDecodesContextAndExplicitCapabilities() throws {
    let models = try EngineCapabilityMetadataParser.openAIModelList(
        fixture(
            #"{"data":[{"id":"org/coder","max_model_len":131072,"supported_parameters":["tools","reasoning_effort"],"capabilities":{"vision":false,"tools":true,"reasoning":{"allowed_options":["low","medium","high","xhigh"]}}},{"id":"plain"}]}"#
        ))

    #expect(models.map(\.id) == ["org/coder", "plain"])
    let coder = try #require(models.first)
    #expect(coder.contextLength == 131_072)
    #expect(coder.capabilities.vision.support == .unsupported)
    #expect(coder.capabilities.tools.support == .supported)
    #expect(coder.capabilities.reasoning.support == .supported)
    #expect(coder.capabilities.nativeReasoningEffort(for: .summit) == "xhigh")
    #expect(models[1].capabilities == .unknown)
}

@Test func modelDetailURLTreatsTheWholeModelIDAsOneComponent() throws {
    let base = try #require(URL(string: "http://127.0.0.1:8000/root"))
    let url = try #require(
        EngineMetadataEndpoint.modelDetail(
            baseURL: base, modelID: "org/Qwen Coder/unsafe?value"))

    #expect(
        url.absoluteString
            == "http://127.0.0.1:8000/root/v1/models/org%2FQwen%20Coder%2Funsafe%3Fvalue")
}

@Test func dotOnlyModelIDsRemainOpaquePathComponents() throws {
    let base = try #require(URL(string: "http://127.0.0.1:8000"))

    #expect(
        EngineMetadataEndpoint.modelDetail(baseURL: base, modelID: ".")?.absoluteString
            == "http://127.0.0.1:8000/v1/models/%2E")
    #expect(
        EngineMetadataEndpoint.modelDetail(baseURL: base, modelID: "..")?.absoluteString
            == "http://127.0.0.1:8000/v1/models/%2E%2E")
}

@Test func genericCapabilityArraysProvidePositiveEvidenceOnly() throws {
    let metadata = try EngineCapabilityMetadataParser.openAIModelDetail(
        fixture(#"{"id":"coder","capabilities":["completion"]}"#))

    #expect(metadata.capabilities.vision.support == .unknown)
    #expect(metadata.capabilities.tools.support == .unknown)
    #expect(metadata.capabilities.reasoning.support == .unknown)
}

@Test func lmStudioMetadataIsInformativeButDoesNotGuessCompatReasoningField() throws {
    let metadata = try EngineCapabilityMetadataParser.lmStudioModel(
        fixture(
            #"{"models":[{"type":"llm","key":"mistralai/devstral","max_context_length":131072,"capabilities":{"vision":false,"trained_for_tool_use":true,"reasoning":{"allowed_options":["off","low","medium","high"],"default":"medium"}},"loaded_instances":[{"config":{"context_length":65536}}]}]}"#
        ),
        modelID: "mistralai/devstral")

    #expect(metadata.contextLength == 65_536)
    #expect(metadata.capabilities.vision.support == .unsupported)
    #expect(metadata.capabilities.tools.support == .supported)
    #expect(metadata.capabilities.reasoning.support == .supported)
    #expect(!metadata.capabilities.advertisesRequestParameter("reasoning_effort"))
    #expect(metadata.capabilities.nativeReasoningEffort(for: .climb) == nil)
}

@Test func lmStudioNegativeTrainingHintDoesNotDisableToolWire() throws {
    let metadata = try EngineCapabilityMetadataParser.lmStudioModel(
        fixture(
            #"{"models":[{"type":"llm","key":"plain","capabilities":{"vision":false,"trained_for_tool_use":false}}]}"#
        ),
        modelID: "plain")

    #expect(metadata.capabilities.tools.support == .unknown)
}

@Test func lmStudioReasoningFalseStaysUnsupportedAndContextIsConservative() throws {
    let metadata = try EngineCapabilityMetadataParser.lmStudioModel(
        fixture(
            #"{"models":[{"key":"plain","capabilities":{"reasoning":false},"loaded_instances":[{"config":{"context_length":65536}},{"config":{"context_length":16384}}]}]}"#
        ),
        modelID: "plain")

    #expect(metadata.contextLength == 16_384)
    #expect(metadata.capabilities.reasoning.support == .unsupported)
    #expect(metadata.capabilities.nativeReasoningEffort(for: .summit) == nil)
}

@Test func ollamaThinkingCapabilityEnablesOnlyDocumentedEffortValues() throws {
    let metadata = try EngineCapabilityMetadataParser.ollamaShow(
        fixture(
            #"{"capabilities":["completion","tools","thinking"],"model_info":{"qwen3.context_length":32768,"future.field":true}}"#
        ))

    #expect(metadata.contextLength == 32_768)
    #expect(metadata.capabilities.vision.support == .unsupported)
    #expect(metadata.capabilities.tools.support == .supported)
    #expect(metadata.capabilities.reasoning.support == .supported)
    #expect(metadata.capabilities.nativeReasoningEffort(for: .graze) == "none")
    #expect(metadata.capabilities.nativeReasoningEffort(for: .summit) == "max")
}

@Test func ollamaLoadedContextOverridesDeclaredContextWhenMerged() throws {
    let declared = try EngineCapabilityMetadataParser.ollamaShow(
        fixture(
            #"{"capabilities":["completion"],"model_info":{"llama.context_length":131072}}"#
        ))
    let running = try EngineCapabilityMetadataParser.ollamaRunningContext(
        fixture(#"{"models":[{"name":"code:latest","context_length":16384}]}"#),
        modelID: "code:latest")

    let effective = declared.merged(
        with: ProbedModelMetadata(contextLength: running, capabilities: .unknown))
    #expect(effective.contextLength == 16_384)
}

@Test func llamaPropertiesRequireCompleteToolTemplateAndGateReasoning() throws {
    let supported = try EngineCapabilityMetadataParser.llamaProperties(
        fixture(
            #"{"default_generation_settings":{"n_ctx":65536},"modalities":{"vision":true},"chat_template_caps":{"supports_tools":true,"supports_tool_calls":true,"supports_reasoning_effort":true},"chat_template":"must not be retained","model_path":"/private/model.gguf"}"#
        ))
    #expect(supported.contextLength == 65_536)
    #expect(supported.capabilities.vision.support == .supported)
    #expect(supported.capabilities.tools.support == .supported)
    #expect(supported.capabilities.nativeReasoningEffort(for: .trot) == "medium")

    let incomplete = try EngineCapabilityMetadataParser.llamaProperties(
        fixture(
            #"{"chat_template_caps":{"supports_tools":true,"supports_tool_calls":false}}"#
        ))
    #expect(incomplete.capabilities.tools.support == .unsupported)
    #expect(incomplete.capabilities.nativeReasoningEffort(for: .summit) == nil)
}

@Test func malformedMetadataFailsClosedInsteadOfInventingCapabilities() {
    #expect(throws: (any Error).self) {
        try EngineCapabilityMetadataParser.openAIModelList(fixture(#"{"data":"wrong"}"#))
    }
}

@Test func catalogBoundsAndSanitizesModelIdentifiers() throws {
    let duplicateAndControl = try EngineCapabilityMetadataParser.openAIModelList(
        fixture(#"{"data":[{"id":"coder"},{"id":"coder"},{"id":"bad\nmodel"}]}"#))
    #expect(duplicateAndControl.map(\.id) == ["coder"])

    let entries = (0...EngineCapabilityMetadataParser.maximumCatalogModels)
        .map { #"{"id":"model-\#($0)"}"# }
        .joined(separator: ",")
    #expect(throws: (any Error).self) {
        try EngineCapabilityMetadataParser.openAIModelList(
            fixture(#"{"data":[\#(entries)]}"#))
    }
}

@Test func engineOriginsNormalizeDefaultPortsAndRejectCredentialBearingRoots() throws {
    let implicit = try #require(EngineHTTPOrigin(url: URL(string: "http://localhost")!))
    let explicit = try #require(EngineHTTPOrigin(url: URL(string: "http://LOCALHOST:80")!))
    #expect(implicit == explicit)
    #expect(!implicit.contains(URL(string: "https://localhost")!))
    #expect(!implicit.contains(URL(string: "http://localhost:81")!))
    #expect(!implicit.contains(URL(string: "http://other:80")!))

    #expect(EngineConfig(baseURL: URL(string: "http://localhost:8000/root")!).isValidEndpoint)
    #expect(!EngineConfig(baseURL: URL(string: "ftp://localhost/model")!).isValidEndpoint)
    #expect(!EngineConfig(baseURL: URL(string: "http://user:secret@localhost")!).isValidEndpoint)
    #expect(!EngineConfig(baseURL: URL(string: "http://localhost?token=secret")!).isValidEndpoint)
    #expect(!EngineConfig(baseURL: URL(string: "http://localhost#secret")!).isValidEndpoint)
    #expect(
        EngineConfig(baseURL: URL(string: "http://user:secret@localhost:8000")!)
            .redactedEndpointDescription == "invalid endpoint")
}

@Test func remoteEngineMetadataGetsABroaderNetworkBudget() throws {
    let local = try #require(URL(string: "http://127.0.0.1:8000"))
    let studio = try #require(URL(string: "http://10.1.1.158:8001"))

    #expect(EngineConfig(baseURL: local).metadataProbeRequestTimeout == 2.5)
    #expect(EngineConfig(baseURL: studio).metadataProbeRequestTimeout == 8)
}

@Test func metadataProbeErrorsAreHumanReadable() {
    #expect(MetadataProbeError.timedOut.errorDescription == "Timed out waiting for the engine")
}

@Test func providerDiscoveryPortsDoNotCrossMetadataDialects() {
    #expect(EnginePreset.with(id: "ollama").conventionalDiscoveryURLs == ["http://127.0.0.1:11434"])
    #expect(EnginePreset.with(id: "lmstudio").conventionalDiscoveryURLs == ["http://127.0.0.1:1234"])
    #expect(EnginePreset.with(id: "llamacpp").conventionalDiscoveryURLs == ["http://127.0.0.1:8080"])
    #expect(!EnginePreset.with(id: "omlx").conventionalDiscoveryURLs.contains("http://127.0.0.1:11434"))
}

@Test func mtplxPresetUsesTheOpenAICompatibleLoopbackServer() {
    let preset = EnginePreset.with(id: "mtplx")
    #expect(preset.name == "MTPLX")
    #expect(preset.url == "http://127.0.0.1:8000")
    #expect(preset.metadataDialect == .generic)
    #expect(preset.conventionalDiscoveryURLs == ["http://127.0.0.1:8000"])
    guard case .mtplx(let bundlePath) = preset.management else {
        Issue.record("MTPLX needs its local native-app management contract.")
        return
    }
    #expect(bundlePath == "/Applications/MTPLX.app")
}

@Test func metadataDeadlineCancelsASlowOperation() async {
    do {
        _ = try await MetadataDeadline.run(after: .milliseconds(10)) {
            try await Task.sleep(for: .seconds(10))
            return true
        }
        Issue.record("Expected the hard metadata deadline to fire")
    } catch let error as MetadataProbeError {
        if case .timedOut = error {
            // Expected.
        } else {
            Issue.record("Unexpected metadata error: \(error)")
        }
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test func metadataSessionHasNoAmbientCacheCookiesOrCredentials() {
    let configuration = BoundedMetadataClient.isolatedConfiguration(requestTimeout: 2)

    #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    #expect(configuration.urlCache == nil)
    #expect(configuration.httpCookieStorage == nil)
    #expect(configuration.urlCredentialStorage == nil)
    #expect(!configuration.httpShouldSetCookies)
    #expect(configuration.timeoutIntervalForResource == 2)
}
