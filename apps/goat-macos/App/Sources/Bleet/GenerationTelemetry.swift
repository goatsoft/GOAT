import Bleet
import Foundation
import Inference

/// A rolling one-second rate for the dial, refreshed at four samples per second.
/// The graph retains its separate one-second cadence. No per-token view updates.
struct GenerationRateMeter {
    private var points: [(date: Date, tokens: Int)] = []
    private(set) var rate: Double?

    mutating func sample(tokens: Int, at date: Date) {
        guard tokens >= 0, date.timeIntervalSinceReferenceDate.isFinite else { return }
        if let last = points.last {
            guard date > last.date else { return }
            if tokens < last.tokens || date.timeIntervalSince(last.date) > 2 {
                reset()
            }
        }
        points.append((date, tokens))
        while points.count > 2, date.timeIntervalSince(points[1].date) >= 1 { points.removeFirst() }
        if points.count > 5 { points.removeFirst(points.count - 5) }
        guard let first = points.first else { return }
        let elapsed = date.timeIntervalSince(first.date)
        guard elapsed >= 0.2 else { return }
        let measured = Double(tokens - first.tokens) / elapsed
        rate = measured.isFinite && measured <= 1_000_000 ? measured : nil
    }

    mutating func reset() {
        points.removeAll(keepingCapacity: true)
        rate = nil
    }

    static func scale(containing rate: Double?) -> Double {
        guard let rate, rate.isFinite, rate > 100 else { return 100 }
        let magnitude = pow(10, floor(log10(min(rate, 1_000_000))))
        return [1.0, 2.5, 5.0, 10.0].map { $0 * magnitude }.first { $0 >= rate } ?? 1_000_000
    }
}

/// A view-owned, bounded series. No transcript text, polling endpoint, or persistent telemetry.
struct GenerationRateSeries {
    struct Sample: Identifiable, Equatable {
        let id: Date
        let rate: Double
    }

    static let capacity = 60
    private(set) var samples: [Sample] = []
    private var previous: (date: Date, tokens: Int)?

    mutating func sample(tokens: Int, at date: Date) {
        guard tokens >= 0, date.timeIntervalSinceReferenceDate.isFinite else { return }
        guard let previous else {
            self.previous = (date, tokens)
            return
        }
        let elapsed = date.timeIntervalSince(previous.date)
        guard elapsed >= 0.5 else { return }
        self.previous = (date, tokens)
        guard tokens >= previous.tokens else {
            samples.removeAll(keepingCapacity: true)
            return
        }
        let rate = Double(tokens - previous.tokens) / elapsed
        guard rate.isFinite, rate <= 1_000_000 else { return }
        samples.append(Sample(id: date, rate: rate))
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }

    /// On resume, establish a fresh baseline so time spent hidden is not presented as a stall.
    mutating func pause() { previous = nil }
}

struct GenerationChartValue: Identifiable {
    let id: UUID
    let ordinal: Int
    let rate: Double
    let reported: Bool

    init?(id: UUID, ordinal: Int, stats: GenStats) {
        let rate = stats.toksPerSec
        guard stats.tokens > 0, rate.isFinite, rate > 0, rate <= 1_000_000 else { return nil }
        self.id = id
        self.ordinal = ordinal
        self.rate = rate
        self.reported = stats.speedIsServerReported
    }
}

/// An agent turn includes engine waiting and tool work as well as actual generation.
@MainActor struct GenerationDisplayState {
    enum Phase { case idle, waiting, generating, tools }
    let phase: Phase
    let message: ChatMessage?
    let stats: GenStats?

    init(session: ChatSession) {
        stats = session.messages.last(where: { $0.stats != nil })?.stats
        message = session.isStreaming ? session.messages.last(where: { $0.role == .assistant && !$0.complete }) : nil
        if !session.isStreaming {
            phase = .idle
        } else if let message, message.stats == nil {
            phase = message.liveMetrics.startedAt == nil ? .waiting : .generating
        } else {
            phase = .tools
        }
    }

    var caption: String {
        switch phase {
        case .waiting:
            return "Waiting for engine" + (stats == nil ? "; no output yet" : "; dial shows the last measured response")
        case .tools: return "Tool step; dial shows the last measured response"
        case .generating: return "Live response, including tool arguments"
        case .idle: return stats == nil ? "No response stats yet" : "Latest measured response"
        }
    }

    func throughput(at date: Date) -> String {
        if phase == .generating {
            guard let speed = message?.liveMetrics.tokensPerSecond(at: date), speed.isFinite else { return "… tok/s" }
            return "~\(Int(speed)) tok/s"
        }
        let measured = stats.flatMap { $0.toksPerSec.isFinite && $0.toksPerSec > 0 ? $0 : nil }
        let rate = measured.map { "\($0.speedIsServerReported ? "" : "~")\(Int($0.toksPerSec)) tok/s" }
        switch phase {
        case .waiting: return "Waiting" + (rate.map { " · last " + $0 } ?? " for engine")
        case .tools: return "Tool step" + (rate.map { " · last " + $0 } ?? "")
        default: return rate ?? "- tok/s"
        }
    }
}
