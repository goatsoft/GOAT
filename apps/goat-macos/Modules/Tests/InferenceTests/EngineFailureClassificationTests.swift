import Testing

@testable import Inference

struct EngineFailureClassificationTests {
    @Test func classifiesOnlyTheKnownUnsupportedArchitecturePayload() {
        let error = EngineError.httpDetail(409, "model glm_moe_dsa_mtp is not supported", retryAfter: nil)
        #expect(error.classification == .unsupportedModelArchitecture)
        #expect(error.userFacingFailureDescription.contains("cannot load this model architecture"))
    }

    @Test func doesNotTreatEveryConflictAsUnsupportedArchitecture() {
        #expect(EngineError.http(409).classification == .unknown)
        #expect(EngineError.httpDetail(409, "another model is busy", retryAfter: nil).classification == .unknown)
    }

    @Test func classifiesAuthenticationAndUnavailableModels() {
        #expect(EngineError.http(401).classification == .authentication)
        #expect(EngineError.http(404).classification == .modelUnavailable)
    }
}
