import Bleet
import Foundation

/// Bounds rich-text layout by both message count and visible source cost.
/// An oversized message is always admitted and its text is presented in bounded parts.
enum TranscriptWindow {
    static let capacity = 40
    static let step = capacity / 2
    static let sourceBudget = 16 * 1_024

    static func range(count: Int, end: Int?, cost: (Int) -> Int = { _ in 0 }) -> Range<Int> {
        let upper = min(max(0, count), max(0, end ?? count))
        var lower = upper
        var bytes = 0
        while lower > 0, upper - lower < capacity {
            let next = min(sourceBudget, max(0, cost(lower - 1)))
            if lower < upper, bytes + next > sourceBudget { break }
            bytes += next
            lower -= 1
        }
        return lower..<upper
    }

    static func range(count: Int, startingAt start: Int, cost: (Int) -> Int = { _ in 0 }) -> Range<Int> {
        guard count > 0, (0..<count).contains(start) else { return 0..<0 }
        var lower = start
        var upper = start + 1
        var bytes = min(sourceBudget, max(0, cost(start)))
        while upper < count, upper - lower < capacity {
            let next = min(sourceBudget, max(0, cost(upper)))
            if bytes + next > sourceBudget { break }
            bytes += next
            upper += 1
        }
        while lower > 0, upper - lower < capacity {
            let next = min(sourceBudget, max(0, cost(lower - 1)))
            if bytes + next > sourceBudget { break }
            bytes += next
            lower -= 1
        }
        return lower..<upper
    }

    static func earlier(_ current: Range<Int>, count: Int, cost: (Int) -> Int) -> Range<Int> {
        let candidate = range(count: count, end: current.lowerBound + current.count / 2, cost: cost)
        return candidate.lowerBound < current.lowerBound
            ? candidate : range(count: count, end: current.lowerBound, cost: cost)
    }

    static func later(_ current: Range<Int>, count: Int, cost: (Int) -> Int) -> Range<Int> {
        let candidate = range(count: count, startingAt: current.upperBound - current.count / 2, cost: cost)
        return candidate.upperBound > current.upperBound
            ? candidate : range(count: count, startingAt: min(max(0, count - 1), current.upperBound), cost: cost)
    }

    static func clamped(
        _ held: Range<Int>,
        count: Int,
        anchor: Int? = nil,
        cost: (Int) -> Int = { _ in 0 }
    ) -> Range<Int> {
        let upper = min(max(0, count), held.upperBound)
        let lower = min(held.lowerBound, upper)
        // Compaction can remove the held window or shift a surviving reader anchor.
        let surviving =
            lower == upper && upper > 0
            ? range(count: count, end: upper, cost: cost) : lower..<upper
        if let anchor, (0..<max(0, count)).contains(anchor), !surviving.contains(anchor) {
            return range(count: count, startingAt: anchor, cost: cost)
        }
        return surviving
    }

    @MainActor static func displayCost(_ message: ChatMessage) -> Int {
        // Do not scan tool payloads or all reasoning merely to decide which rows to admit.
        // Answer and reasoning each render at most one parts page. Reasoning is charged at its expanded
        // size (not the character-based preview) because the reader can show all of it in place.
        answerCost(message)
            + min(TranscriptTextParts.maximumBytes, message.thinking.utf8.count)
            + min(capacity, message.toolEvents.count) * 256
    }

    /// A segmented reply is charged the bytes its segments render (rebuilt syntax, artifacts and each
    /// segment's definition suffix) once prepared, and its source bytes until then. Above the parts
    /// threshold it renders one parts page.
    @MainActor private static func answerCost(_ message: ChatMessage) -> Int {
        let bytes = message.text.utf8.count
        guard bytes <= TranscriptTextParts.maximumBytes, message.role == .assistant else {
            return min(TranscriptTextParts.maximumBytes, bytes)
        }
        return PreparedMarkdownDocumentCache.shared.renderedBytes(for: message.id, source: message.text) ?? bytes
    }
}
