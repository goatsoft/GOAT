import Foundation

/// Streaming state machine that routes `<think>…</think>` spans (Qwen3-style) out of
/// content and into thinking events - resilient to tags split across SSE chunks.
public struct ThinkTagParser: Sendable {
    public enum Piece: Equatable, Sendable {
        case text(String)
        case thinking(String)
    }

    private var inThink = false
    private var pending = ""
    private let open = "<think>"
    private let close = "</think>"

    public init() {}

    public mutating func feed(_ chunk: String) -> [Piece] {
        pending += chunk
        var out: [Piece] = []
        while true {
            let target = inThink ? close : open
            if let range = pending.range(of: target) {
                let before = String(pending[..<range.lowerBound])
                append(before, to: &out)
                pending = String(pending[range.upperBound...])
                inThink.toggle()
            } else {
                let keep = partialSuffixLength(of: pending, target: target)
                let emit = String(pending.dropLast(keep))
                append(emit, to: &out)
                pending = String(pending.suffix(keep))
                break
            }
        }
        return out
    }

    /// Call at end of stream to release any held partial tag as literal output.
    public mutating func flush() -> [Piece] {
        defer { pending = "" }
        guard !pending.isEmpty else { return [] }
        return [inThink ? .thinking(pending) : .text(pending)]
    }

    private func append(_ s: String, to out: inout [Piece]) {
        guard !s.isEmpty else { return }
        out.append(inThink ? .thinking(s) : .text(s))
    }

    /// Longest suffix of `s` that is a proper prefix of `target` (a possibly-split tag).
    private func partialSuffixLength(of s: String, target: String) -> Int {
        let maxCheck = min(s.count, target.count - 1)
        guard maxCheck > 0 else { return 0 }
        for len in stride(from: maxCheck, through: 1, by: -1) {
            if target.hasPrefix(String(s.suffix(len))) { return len }
        }
        return 0
    }
}
