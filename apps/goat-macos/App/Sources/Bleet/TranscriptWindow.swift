/// Bounds expensive rich-text layout while keeping all messages available for navigation.
/// Paging overlaps half the window so the current edge remains a stable scroll target.
enum TranscriptWindow {
    static let capacity = 40
    static let step = capacity / 2

    static func range(count: Int, end: Int?) -> Range<Int> {
        let upper = min(max(0, count), max(0, end ?? count))
        return max(0, upper - capacity)..<upper
    }
}
