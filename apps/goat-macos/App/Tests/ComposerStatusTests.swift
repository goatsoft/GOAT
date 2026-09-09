import Foundation
import Testing

@testable import Bleet
@testable import GOAT
@testable import Inference

@Test func liveMetricsCountBytesRatherThanStreamChunks() {
    let start = Date(timeIntervalSinceReferenceDate: 100)
    var batched = LiveGenerationMetrics()
    batched.append(bytes: 300, at: start)
    var split = LiveGenerationMetrics()
    for _ in 0..<100 { split.append(bytes: 3, at: start) }
    #expect(batched.estimatedTokens == split.estimatedTokens)
    #expect(batched.tokensPerSecond(at: start) == nil)
    #expect(batched.tokensPerSecond(at: start.addingTimeInterval(2)) == 50)
    #expect(split.tokensPerSecond(at: start.addingTimeInterval(2)) == 50)
    #expect(batched.tokensPerSecond(at: start.addingTimeInterval(4)) == 25)
}

@Test @MainActor func contextMeterIsAvailableBeforeTheFirstMessage() throws {
    let session = ChatSession(effort: .trot, modelID: "test")
    let status = try #require(
        ContextStatus(session: session, models: [ModelRef(id: "test", contextLength: 32000)], defaultModelID: nil))
    #expect(status.used == 0)
    #expect(status.window == 32000)
    #expect(status.ratio == 0)
}

@Test @MainActor func liveContextIncludesReasoningAndStopsAddingItAfterCompletion() throws {
    let session = ChatSession(effort: .trot, modelID: "test")
    session.lastContextTokens = 100
    session.isStreaming = true
    let assistant = ChatMessage(role: .assistant)
    session.messages = [assistant]
    assistant.appendStream(text: "abc", thinking: "defghi")
    let live = try #require(ContextStatus(session: session, models: [], defaultModelID: nil))
    #expect(live.used == 103)
    #expect(!live.exact)
    assistant.complete = true
    session.lastContextTokens = 105
    session.contextIsExact = true
    let final = try #require(ContextStatus(session: session, models: [], defaultModelID: nil))
    #expect(final.used == 105)
    #expect(final.exact)
}

@Test @MainActor func savedChatsUseReportedContextAndDoNotPretendUnknownUsageIsZero() throws {
    let session = ChatSession(effort: .trot, modelID: "test")
    let assistant = ChatMessage(role: .assistant)
    assistant.complete = true
    session.messages = [assistant]
    let unknown = try #require(ContextStatus(session: session, models: [], defaultModelID: nil))
    #expect(!unknown.usageKnown)
    #expect(unknown.label == "? ctx")
    assistant.stats = GenStats(ttft: nil, tokens: 200, duration: 2, promptTokens: 1200, tokensAreExact: true)
    let restored = try #require(ContextStatus(session: session, models: [], defaultModelID: nil))
    #expect(restored.usageKnown)
    #expect(restored.used == 1400)
    #expect(restored.exact)
}

@Test @MainActor func codingTelemetryDistinguishesEngineWaitingToolArgumentsAndToolWork() {
    let session = ChatSession(effort: .trot, modelID: "coder")
    let previous = ChatMessage(role: .assistant)
    previous.complete = true
    previous.stats = GenStats(ttft: 40, tokens: 100, duration: 43, generationTokensPerSecond: 35)
    let message = ChatMessage(role: .assistant)
    session.messages = [previous, message]
    session.isStreaming = true
    let waiting = GenerationDisplayState(session: session)
    #expect(waiting.phase == .waiting)
    #expect(waiting.throughput(at: .now) == "Waiting · last 35 tok/s")
    message.appendStream(text: "", thinking: "", toolInputBytes: 300)
    let generating = GenerationDisplayState(session: session)
    #expect(generating.phase == .generating)
    #expect(generating.throughput(at: Date.now.addingTimeInterval(2)).hasPrefix("~"))
    message.stats = previous.stats
    message.complete = true
    #expect(GenerationDisplayState(session: session).phase == .tools)
    #expect(GenerationDisplayState(session: session).throughput(at: .now) == "Tool step · last 35 tok/s")
    session.isStreaming = false
    #expect(GenerationDisplayState(session: session).throughput(at: .now) == "35 tok/s")
}
