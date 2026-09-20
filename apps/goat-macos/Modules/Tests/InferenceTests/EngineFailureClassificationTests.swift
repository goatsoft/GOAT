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

    @Test func classifiesContextOverflowFromTheEngineMessage() {
        #expect(
            EngineError.httpDetail(
                400, "This model's maximum context length is 8192 tokens", retryAfter: nil
            )
            .classification == .contextOverflow)
        #expect(
            EngineError.httpDetail(413, "The prompt is too long for this model", retryAfter: nil)
                .classification == .contextOverflow)
        // A different 400 stays a malformed-request classification, not an overflow.
        #expect(
            EngineError.httpDetail(400, "invalid 'messages': missing role", retryAfter: nil)
                .classification == .malformedResponse)
    }
}
