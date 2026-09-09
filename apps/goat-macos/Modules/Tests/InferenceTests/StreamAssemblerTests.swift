import Foundation
import Testing

@testable import Inference

// StreamAssembler is the normalization seam (ADR-0016): raw OpenAI-dialect chunks in,
// canonical GenerationEvents out. These tests feed wire-shaped JSON, not hand-built types.

private func chunk(_ json: String) throws -> StreamChunk {
    try JSONDecoder().decode(StreamChunk.self, from: Data(json.utf8))
}

private func doneStats(_ events: [GenerationEvent]) -> GenStats? {
    for event in events { if case .done(let s) = event { return s } }
    return nil
}

@Test func serverUsageBeatsChunkCounting() throws {
    var a = StreamAssembler()
    _ = a.feed(try chunk(#"{"choices":[{"delta":{"content":"Hello "}}]}"#))
    _ = a.feed(try chunk(#"{"choices":[{"delta":{"content":"world"}}]}"#))
    _ = a.feed(try chunk(#"{"choices":[],"usage":{"prompt_tokens":120,"completion_tokens":42}}"#))
    let stats = doneStats(a.finish())
    #expect(stats?.tokens == 42)
    #expect(stats?.promptTokens == 120)
    #expect(stats?.tokensAreExact == true)
}

@Test func serverGenerationTimingBeatsEndToEndTiming() throws {
    var assembler = StreamAssembler()
    _ = assembler.feed(try chunk(#"{"choices":[{"delta":{"content":"answer"}}]}"#))
    _ = assembler.feed(
        try chunk(
            #"{"choices":[],"usage":{"prompt_tokens":13042,"completion_tokens":38,"time_to_first_token":15.89,"generation_duration":0.83,"generation_tokens_per_second":46.04}}"#
        ))

    let stats = try #require(doneStats(assembler.finish()))
    #expect(stats.ttft == 15.89)
    #expect(stats.generationTokensPerSecond == 46.04)
    #expect(stats.toksPerSec == 46.04)
    #expect(stats.speedIsServerReported)
}

@Test func llamaCppGenerationTimingIsNormalized() throws {
    var assembler = StreamAssembler()
    _ = assembler.feed(try chunk(#"{"choices":[{"delta":{"content":"answer"}}]}"#))
    _ = assembler.feed(
        try chunk(
            #"{"choices":[],"usage":{"prompt_tokens":20,"completion_tokens":11},"timings":{"predicted_ms":44.285,"predicted_per_second":248.391}}"#
        ))

    let stats = try #require(doneStats(assembler.finish()))
    #expect(stats.generationTokensPerSecond == 248.391)
    #expect(stats.toksPerSec == 248.391)
    #expect(stats.speedIsServerReported)
}

@Test func clientTimingExcludesTimeToFirstTokenFromDecodeRate() {
    let stats = GenStats(ttft: 2, tokens: 40, duration: 3, tokensAreExact: true)

    #expect(stats.toksPerSec == 40)
    #expect(!stats.speedIsServerReported)
}

@Test func chunkCountIsTheHonestFallback() throws {
    var a = StreamAssembler()
    _ = a.feed(try chunk(#"{"choices":[{"delta":{"content":"one"}}]}"#))
    _ = a.feed(try chunk(#"{"choices":[{"delta":{"content":"two"}}]}"#))
    _ = a.feed(try chunk(#"{"choices":[{"delta":{"content":"three"}}]}"#))
    let stats = doneStats(a.finish())
    #expect(stats?.tokens == 3)
    #expect(stats?.promptTokens == nil)
    #expect(stats?.tokensAreExact == false)
}

@Test func reasoningContentDeltasBecomeThinking() throws {
    var a = StreamAssembler()
    let events = a.feed(try chunk(#"{"choices":[{"delta":{"reasoning_content":"hmm"}}]}"#))
    guard case .thinking(let t) = events.first else {
        Issue.record("expected .thinking, got \(events)")
        return
    }
    #expect(t == "hmm")
}

@Test func reasoningAndThinkingAliasesBecomeThinking() throws {
    for (key, expected) in [("reasoning", "vLLM"), ("thinking", "thinking alias")] {
        var assembler = StreamAssembler()
        let events = assembler.feed(
            try chunk(#"{"choices":[{"delta":{"\#(key)":"\#(expected)"}}]}"#))
        guard case .thinking(let text) = events.first else {
            Issue.record("expected .thinking for \(key), got \(events)")
            continue
        }
        #expect(text == expected)
    }
}

@Test func reasoningAliasesAndTypedPartsDoNotDuplicateThinking() throws {
    var assembler = StreamAssembler()
    let events = assembler.feed(
        try chunk(
            #"{"choices":[{"delta":{"reasoning_content":"same","reasoning":"same","thinking":"same","content":[{"type":"thinking","text":"same"},{"type":"text","text":"answer"}]}}]}"#
        ))

    let thoughts = events.compactMap { event -> String? in
        if case .thinking(let text) = event { return text }
        return nil
    }
    #expect(thoughts == ["same"])
    #expect(
        events.contains { event in
            if case .token("answer") = event { return true }
            return false
        })
}

@Test func mistralContentPartArraysPreserveTextAndThinkingOrder() throws {
    var assembler = StreamAssembler()
    let events = assembler.feed(
        try chunk(
            #"{"choices":[{"delta":{"content":[{"type":"thinking","thinking":[{"type":"text","text":"reason "},{"type":"text","text":"more"}]},{"type":"text","text":"answer"}]}}]}"#
        ))

    #expect(events.count == 2)
    if events.count == 2 {
        guard case .thinking(let reasoning) = events[0] else {
            Issue.record("expected first content part to be thinking")
            return
        }
        guard case .token(let answer) = events[1] else {
            Issue.record("expected second content part to be text")
            return
        }
        #expect(reasoning == "reason more")
        #expect(answer == "answer")
    }
}

@Test func unknownContentPartsAndNonStringReasoningDoNotDiscardText() throws {
    var assembler = StreamAssembler()
    let events = assembler.feed(
        try chunk(
            #"{"choices":[{"delta":{"reasoning":{"unexpected":true},"content":[{"type":"citation","url":"https://example.test"},{"type":"text","text":"kept"}]}}]}"#
        ))
    guard case .token(let text) = events.first else {
        Issue.record("expected supported text part to survive unknown fields")
        return
    }
    #expect(events.count == 1)
    #expect(text == "kept")
}

@Test func thinkTagsSplitAcrossChunksStillRoute() throws {
    var a = StreamAssembler()
    var out: [GenerationEvent] = []
    out += a.feed(try chunk(#"{"choices":[{"delta":{"content":"<thi"}}]}"#))
    out += a.feed(try chunk(#"{"choices":[{"delta":{"content":"nk>secret</think>plain"}}]}"#))
    out += a.finish()
    var thinking = ""
    var text = ""
    for event in out {
        if case .thinking(let t) = event { thinking += t }
        if case .token(let t) = event { text += t }
    }
    #expect(thinking == "secret")
    #expect(text == "plain")
}

@Test func fragmentedToolCallsAssembleOnFinish() throws {
    var a = StreamAssembler()
    _ = a.feed(
        try chunk(
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_","arguments":"{\"pa"}}]}}]}"#
        ))
    _ = a.feed(
        try chunk(
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"file","arguments":"th\":1}"}}]}}]}"#))
    let events = a.finish()
    var calls: [ToolCallEvent] = []
    for event in events { if case .toolCalls(let c) = event { calls = c } }
    #expect(calls.count == 1)
    #expect(calls.first?.id == "call_1")
    #expect(calls.first?.name == "read_file")
    #expect(calls.first?.argumentsJSON == #"{"pa"# + #"th":1}"#)
}

@Test func ttftIsMarkedOnFirstDeltaOfAnyKind() throws {
    var a = StreamAssembler()
    _ = a.feed(try chunk(#"{"choices":[{"delta":{"reasoning_content":"…"}}]}"#))
    let stats = doneStats(a.finish())
    #expect(stats?.ttft != nil)
}

@Test func emptyKeepaliveDeltasDoNotCountAsGeneratedTokens() throws {
    var assembler = StreamAssembler()
    _ = assembler.feed(
        try chunk(#"{"choices":[{"delta":{"role":"assistant","content":""}}]}"#))
    let stats = try #require(doneStats(assembler.finish()))

    #expect(stats.ttft == nil)
    #expect(stats.tokens == 0)
}

@Test func finishReasonSurvivesUsageOnlyChunksAndMissingDelta() throws {
    var assembler = StreamAssembler()
    _ = assembler.feed(try chunk(#"{"choices":[{"finish_reason":"length"}]}"#))
    _ = assembler.feed(try chunk(#"{"choices":[],"usage":{"completion_tokens":1024}}"#))
    #expect(doneStats(assembler.finish())?.finishReason == "length")
}

@Test func toolArgumentStreamingReportsBytesBeforeExecutableCallsAndKeepsServerStats() throws {
    var assembler = StreamAssembler()
    let events = assembler.feed(
        try chunk(
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"pen_edit_file","arguments":"abc"}}]}}]}"#
        ))
    let next = assembler.feed(
        try chunk(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"🐐"}}]}}]}"#))
    var bytes = 0
    for event in events + next {
        if case .toolInput(let count) = event { bytes += count }
        if case .toolCalls = event { Issue.record("Partial arguments must never become executable calls") }
    }
    #expect(bytes == "pen_edit_fileabc🐐".utf8.count)
    _ = assembler.feed(try chunk(#"{"choices":[],"usage":{"completion_tokens":99,"generation_tokens_per_second":35}}"#))
    let final = assembler.finish()
    #expect(doneStats(final)?.tokens == 99)
    #expect(doneStats(final)?.toksPerSec == 35)
    #expect(
        !final.contains {
            if case .toolInput = $0 { return true }
            return false
        })
}
