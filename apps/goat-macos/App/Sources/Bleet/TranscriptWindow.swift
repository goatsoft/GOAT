import Bleet
import Foundation

/// Bounds rich-text layout by both message count and visible source cost.
/// An oversized message is always admitted and its text is presented in bounded parts.
enum TranscriptWindow {
    static let capacity = 40
    static let step = capacity / 2
    static let sourceBudget = 16 * 1_024

    static func range(
        count: Int, end: Int?, capacity: Int = TranscriptWindow.capacity,
        budget: Int = TranscriptWindow.sourceBudget, cost: (Int) -> Int = { _ in 0 }
    ) -> Range<Int> {
        let upper = min(max(0, count), max(0, end ?? count))
        var lower = upper
        var bytes = 0
        while lower > 0, upper - lower < capacity {
            let next = min(budget, max(0, cost(lower - 1)))
            if lower < upper, bytes + next > budget { break }
            bytes += next
            lower -= 1
        }
        return lower..<upper
    }

    static func range(
        count: Int, startingAt start: Int, capacity: Int = TranscriptWindow.capacity,
        budget: Int = TranscriptWindow.sourceBudget, cost: (Int) -> Int = { _ in 0 }
    ) -> Range<Int> {
        guard count > 0, (0..<count).contains(start) else { return 0..<0 }
        var lower = start
        var upper = start + 1
        var bytes = min(budget, max(0, cost(start)))
        while upper < count, upper - lower < capacity {
            let next = min(budget, max(0, cost(upper)))
            if bytes + next > budget { break }
            bytes += next
            upper += 1
        }
        while lower > 0, upper - lower < capacity {
            let next = min(budget, max(0, cost(lower - 1)))
            if bytes + next > budget { break }
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
        // Reasoning renders at most one parts page, and is charged at its expanded size (not the
        // character-based preview) because the reader can show all of it in place.
        answerCost(message)
            + min(TranscriptTextParts.maximumBytes, message.thinking.utf8.count)
            + min(capacity, message.toolEvents.count) * 256
    }

    /// A segmented reply is charged the bytes its shown segments render (rebuilt syntax, artifacts and
    /// each segment's definition suffix) once prepared, and at most its reply window until then. Above
    /// the rich limit, and for other roles above the parts threshold, it renders one parts page.
    @MainActor private static func answerCost(_ message: ChatMessage) -> Int {
        let bytes = message.textRevision.utf8Count
        guard message.role == .assistant, bytes <= ReplyWindow.richLimit else {
            return min(TranscriptTextParts.maximumBytes, bytes)
        }
        let cache = PreparedMarkdownDocumentCache.shared
        return cache.shownBytes(for: message.id, revision: message.textRevision) ?? min(ReplyWindow.budget, bytes)
    }
}

/// The segments one long reply lays out (#60 A1 step 3, ADR-0091). Replies through `richLimit`
/// render as rich Markdown segments; the reply window bounds how many of them are laid out at once,
/// by count and by rendered bytes, independently of the reply's length. Longer text keeps bounded
/// selectable parts. The navigation owner holds a window a reader pages to; otherwise a reply shows
/// its latest segments.
enum ReplyWindow {
    static let richLimit = 2 * 1_024 * 1_024
    /// Rendered bytes laid out for one reply: the message window's budget, so a long reply fills at
    /// most one window. A single segment is always shown.
    static let budget = TranscriptWindow.sourceBudget
    static let capacity = 32

    static func latest(count: Int, cost: (Int) -> Int) -> Range<Int> {
        TranscriptWindow.range(count: count, end: nil, capacity: capacity, budget: budget, cost: cost)
    }

    /// An earlier window that still shows `current`'s first segment, so the reader's place stays on
    /// screen. When that segment alone fills the budget, it is shown with the one before it.
    static func earlier(_ current: Range<Int>, count: Int, cost: (Int) -> Int) -> Range<Int> {
        let kept = current.lowerBound
        let window = TranscriptWindow.range(
            count: count, end: kept + max(1, current.count / 2), capacity: capacity, budget: budget, cost: cost)
        return window.lowerBound < kept ? window : max(0, kept - 1)..<min(count, kept + 1)
    }

    /// A later window that still shows `current`'s last segment. When that segment alone fills the
    /// budget, it is shown with the one after it.
    static func later(_ current: Range<Int>, count: Int, cost: (Int) -> Int) -> Range<Int> {
        let kept = current.upperBound - 1
        let window = TranscriptWindow.range(
            count: count, startingAt: current.upperBound - max(1, current.count / 2), capacity: capacity,
            budget: budget, cost: cost)
        return window.upperBound > current.upperBound && window.lowerBound <= kept
            ? window : kept..<min(count, kept + 2)
    }
}
