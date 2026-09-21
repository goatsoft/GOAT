import Foundation

/// Bounded, session-local measurements for one request. Contains no prompt or response content.
/// Server decode speed and client delivery speed describe different intervals.
public struct GenerationDeliveryMetrics: Sendable, Equatable {
    public var firstEventSeconds: TimeInterval?
    public var lastEventSeconds: TimeInterval?
    public var eventCount = 0
    public var maximumEventGap: TimeInterval = 0
    public var serverPromptSeconds: TimeInterval?
    public var serverModelLoadSeconds: TimeInterval?
    public var firstOutputSeconds: TimeInterval?
    public var lastOutputSeconds: TimeInterval?
    public var outputBytes = 0
    public var outputEvents = 0
    public var maximumOutputGap: TimeInterval = 0
    public var publicationCount = 0
    public var maximumPublicationSeconds: TimeInterval = 0

    public init() {}

    public mutating func receiveEvent(elapsed: TimeInterval) {
        guard elapsed.isFinite, elapsed >= 0 else { return }
        if let lastEventSeconds {
            guard elapsed >= lastEventSeconds else { return }
            maximumEventGap = max(maximumEventGap, elapsed - lastEventSeconds)
        }
        if firstEventSeconds == nil { firstEventSeconds = elapsed }
        lastEventSeconds = elapsed
        eventCount += 1
    }

    public mutating func receive(bytes: Int, elapsed: TimeInterval) {
        guard bytes > 0, elapsed.isFinite, elapsed >= 0 else { return }
        if let lastOutputSeconds {
            guard elapsed >= lastOutputSeconds else { return }
            maximumOutputGap = max(maximumOutputGap, elapsed - lastOutputSeconds)
        }
        if firstOutputSeconds == nil { firstOutputSeconds = elapsed }
        lastOutputSeconds = elapsed
        outputBytes += bytes
        outputEvents += 1
    }

    public mutating func published(seconds: TimeInterval) {
        guard seconds.isFinite, seconds >= 0 else { return }
        publicationCount += 1
        maximumPublicationSeconds = max(maximumPublicationSeconds, seconds)
    }

    /// Received UTF-8 bytes per second, with no tokenizer assumption. A single buffered burst
    /// has no measurable delivery interval and must not be displayed as a decode speed.
    public var receivedBytesPerSecond: Double? {
        guard let firstOutputSeconds, let lastOutputSeconds,
            lastOutputSeconds - firstOutputSeconds >= 0.25
        else { return nil }
        return Double(outputBytes) / (lastOutputSeconds - firstOutputSeconds)
    }
}
