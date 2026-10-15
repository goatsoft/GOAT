import Bleet
import Foundation

/// Limits for preparing one reply's text (ADR-0104). Nothing here bounds what the reader sees: the
/// transcript lays every segment out as an item of its lazy stack. Replies through `richLimit` render as
/// rich Markdown segments; longer text is split into plain parts.
enum ReplyWindow {
    static let richLimit = 2 * 1_024 * 1_024
    /// Rendered bytes the latest segments of a reply are prepared within before any of its items has
    /// been shown (a streaming reply's tail). A single segment is always included.
    static let budget = 16 * 1_024
    static let capacity = 2

    /// The latest segments within `budget` and `capacity`.
    static func latest(count: Int, cost: (Int) -> Int) -> Range<Int> {
        let upper = max(0, count)
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
}
