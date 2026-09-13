import Foundation
import Persistence
import Testing

@Suite("Generation provenance")
struct GenerationProvenanceTests {
    @Test("all neutral provenance fields round trip")
    func roundTrips() throws {
        let source = GenerationProvenanceRecord(
            engineProfileID: "engine",
            engineDisplayName: "Local",
            requestedModelID: "Org/model",
            responseModelID: "Org/model-v2",
            requestStartedAt: Date(timeIntervalSince1970: 100),
            appVersion: "1.0",
            appBuild: "10",
            resolvedRequestStyle: "genericOpenAI",
            resolutionSource: "explicitOverride",
            selectedEffort: "trot",
            actualTemperature: 0.7,
            effectiveOutputTokenCap: 512,
            reasoningHistoryReplayed: false,
            lifecycle: .completed,
            finishReason: "stop")
        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(GenerationProvenanceRecord.self, from: data)
        #expect(decoded == source)
    }

    @Test("message records default new provenance columns to nil")
    func messageRecordDefaultsStayCompatible() {
        let record = MessageRecord(
            id: "message", chatId: "chat", role: "assistant", text: "text", thinking: "",
            error: nil, statsTtft: nil, statsTokens: nil, statsDuration: nil,
            complete: true, position: 0, createdAt: .now)
        #expect(record.generationProvenanceJson == nil)
        #expect(record.statsFinishReason == nil)
    }
}
