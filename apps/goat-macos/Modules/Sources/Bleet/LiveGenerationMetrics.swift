import Foundation

/// Incremental estimate, updated only when the coalesced stream is published. Never counts
/// transport chunks as tokens or rescans the full transcript. Final stats remain authoritative.
public struct LiveGenerationMetrics {
    public init() {}

    public private(set) var bytes = 0
    public private(set) var startedAt: Date?
    public var estimatedTokens: Int { (bytes + 2) / 3 }

    public mutating func append(bytes count: Int, at date: Date) {
        guard count > 0 else { return }
        if startedAt == nil { startedAt = date }
        bytes += count
    }

    public func tokensPerSecond(at date: Date) -> Double? {
        guard let startedAt else { return nil }
        let elapsed = date.timeIntervalSince(startedAt)
        guard elapsed >= 0.25 else { return nil }
        return Double(estimatedTokens) / elapsed
    }
}
