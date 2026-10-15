import Bleet
import Testing

@testable import GOAT

extension AppTests.Bleet {
    /// What remains of reply windows after ADR-0104: the segments a reply prepares before any of its
    /// items has been shown, and the windows the segment cache parses. Nothing here bounds what the
    /// reader sees.
    @Suite struct TranscriptWindowTests {
        @Test func latestSegmentsFitTheBudgetOrAreOneSegment() {
            let costs = [2_000, 16_384, 3_000, 3_000, 16_384, 16_384, 1_000, 1_000, 6_000, 6_000, 6_000, 500]
            let latest = ReplyWindow.latest(count: costs.count, cost: { costs[$0] })
            #expect(latest.upperBound == costs.count)
            #expect(latest.count <= ReplyWindow.capacity)
            #expect(latest.count == 1 || latest.reduce(0) { $0 + costs[$1] } <= ReplyWindow.budget)
            #expect(ReplyWindow.latest(count: 0, cost: { _ in 1 }).isEmpty)
            #expect(ReplyWindow.latest(count: 3, cost: { _ in ReplyWindow.budget * 2 }) == 2..<3)
        }

        @Test func segmentWindowsResolveAgainstTheReply() {
            let small = { (_: Int) in 1_000 }
            #expect(
                SegmentWindow.latest.resolve(count: 2, cost: small) == nil, "A reply that fits shows every segment")
            #expect(SegmentWindow.latest.resolve(count: 10, cost: small) == 8..<10)
            #expect(SegmentWindow.all.resolve(count: 100, cost: small) == nil)
            let large = { (_: Int) in 6_000 }
            #expect(SegmentWindow.latest.resolve(count: 10, cost: large) == 8..<10)
            #expect(SegmentWindow.segments(3..<5).resolve(count: 10, cost: large) == 3..<5)
            #expect(SegmentWindow.segments(8..<12).resolve(count: 10, cost: large) == 8..<10)
            #expect(
                SegmentWindow.segments(20..<22).resolve(count: 10, cost: large) == 8..<10,
                "A window past an edited reply's end shows its latest segments")
            #expect(SegmentWindow.latest.resolve(count: 0, cost: large) == nil)
        }
    }
}
