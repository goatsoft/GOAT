import Testing

@testable import Inference

@Test func plainTextPassesThrough() {
    var p = ThinkTagParser()
    #expect(p.feed("hello world") == [.text("hello world")])
    #expect(p.flush() == [])
}

@Test func thinkSpanIsRouted() {
    var p = ThinkTagParser()
    let pieces = p.feed("<think>pondering</think>answer")
    #expect(pieces == [.thinking("pondering"), .text("answer")])
}

@Test func tagSplitAcrossChunksIsHandled() {
    var p = ThinkTagParser()
    var out: [ThinkTagParser.Piece] = []
    for chunk in ["<th", "ink>deep ", "thought</thi", "nk>result"] {
        out += p.feed(chunk)
    }
    out += p.flush()
    let thinking = out.compactMap { if case .thinking(let s) = $0 { s } else { nil } }.joined()
    let text = out.compactMap { if case .text(let s) = $0 { s } else { nil } }.joined()
    #expect(thinking == "deep thought")
    #expect(text == "result")
}

@Test func angleBracketInMathIsNotEaten() {
    var p = ThinkTagParser()
    var out = p.feed("x < y and 2<3")
    out += p.flush()
    let text = out.compactMap { if case .text(let s) = $0 { s } else { nil } }.joined()
    #expect(text == "x < y and 2<3")
}

@Test func unterminatedThinkFlushesAsThinking() {
    var p = ThinkTagParser()
    var out = p.feed("<think>never closed")
    out += p.flush()
    #expect(out == [.thinking("never closed")])
}

@Test func streamingNeverReordersOutput() {
    var p = ThinkTagParser()
    var out: [ThinkTagParser.Piece] = []
    for c in "abc<think>xyz</think>def" { out += p.feed(String(c)) }
    out += p.flush()
    let text = out.compactMap { if case .text(let s) = $0 { s } else { nil } }.joined()
    let thinking = out.compactMap { if case .thinking(let s) = $0 { s } else { nil } }.joined()
    #expect(text == "abcdef")
    #expect(thinking == "xyz")
}
