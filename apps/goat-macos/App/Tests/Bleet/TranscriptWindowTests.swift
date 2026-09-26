import Bleet
import Testing

@testable import GOAT

extension AppTests.Bleet {
    @Suite struct TranscriptWindowTests {

        @Test(arguments: [0, 1, 39, 40, 41, 80, 10_000])
        func transcriptWindowBoundsLayoutAndKeepsEveryEarlierMessageReachable(count: Int) {
            var range = TranscriptWindow.range(count: count, end: nil)
            #expect(range.upperBound == count)
            var seen = Set(range)
            while range.lowerBound > 0 {
                let previous = range
                range = TranscriptWindow.range(count: count, end: range.lowerBound + TranscriptWindow.step)
                #expect(range.count <= TranscriptWindow.capacity)
                #expect(range.lowerBound < previous.lowerBound)
                #expect(range.contains(previous.lowerBound))
                seen.formUnion(range)
            }
            #expect(seen == Set(0..<count))
        }

        @Test func transcriptWindowClampsStaleBoundsWithoutDroppingModelHistory() {
            #expect(TranscriptWindow.range(count: 12, end: 80) == 0..<12)
            #expect(TranscriptWindow.range(count: 80, end: 60) == 20..<60)
            #expect(TranscriptWindow.range(count: 80, end: nil) == 40..<80)
            #expect(TranscriptWindow.range(count: 0, end: 40).isEmpty)
            #expect(TranscriptWindow.range(count: 80, end: -1).isEmpty)
        }

        @Test func contentBudgetKeepsUnevenAndOversizedMessagesReachableInBothDirections() {
            let costs = (0..<125).map { index in
                index.isMultiple(of: 7) ? 100_000 : (index.isMultiple(of: 3) ? 7_000 : 100)
            }
            var range = TranscriptWindow.range(count: costs.count, end: nil, cost: { costs[$0] })
            var seen = Set(range)
            while range.lowerBound > 0 {
                let previous = range
                range = TranscriptWindow.earlier(range, count: costs.count, cost: { costs[$0] })
                #expect(range.lowerBound < previous.lowerBound)
                #expect(range.upperBound >= previous.lowerBound)
                #expect(range.count <= TranscriptWindow.capacity)
                #expect(range.count == 1 || range.reduce(0) { $0 + costs[$1] } <= TranscriptWindow.sourceBudget)
                seen.formUnion(range)
            }
            #expect(seen == Set(costs.indices))
            seen = Set(range)
            while range.upperBound < costs.count {
                let previous = range
                range = TranscriptWindow.later(range, count: costs.count, cost: { costs[$0] })
                #expect(range.upperBound > previous.upperBound)
                #expect(range.lowerBound <= previous.upperBound)
                #expect(range.count == 1 || range.reduce(0) { $0 + costs[$1] } <= TranscriptWindow.sourceBudget)
                seen.formUnion(range)
            }
            #expect(seen == Set(costs.indices))
        }

        @Test func heldTranscriptWindowSurvivesGrowthAndClampsDeletion() {
            let held = TranscriptWindow.range(count: 80, end: nil, cost: { _ in 5_000 })
            #expect(held == 77..<80)
            #expect(TranscriptWindow.clamped(held, count: 120) == held)
            #expect(TranscriptWindow.clamped(held, count: 79) == 77..<79)
            #expect(TranscriptWindow.clamped(held, count: 10, cost: { _ in 5_000 }) == 7..<10)
            #expect(TranscriptWindow.clamped(held, count: 0).isEmpty)
        }

        @Test func compactionKeepsASurvivingReaderAnchorWhenIndicesShift() {
            let held = 40..<43
            let restored = TranscriptWindow.clamped(held, count: 60, anchor: 20, cost: { _ in 5_000 })
            #expect(restored == 20..<23)
            #expect(TranscriptWindow.clamped(held, count: 60, anchor: 41, cost: { _ in 5_000 }) == held)
        }

        @Test @MainActor func displayCostChargesExpandedAndMultibyteReasoningInBytes() {
            let heavy = ChatMessage(role: .assistant)
            heavy.text = String(repeating: "a", count: 8 * 1_024)
            heavy.thinking = String(repeating: "b", count: 8 * 1_024)
            #expect(TranscriptWindow.displayCost(heavy) == 16 * 1_024)

            // 1,400 characters of two-byte reasoning are 2,800 source bytes, not 1,400.
            let unicode = ChatMessage(role: .assistant)
            unicode.thinking = String(repeating: "\u{E9}", count: 1_400)
            #expect(TranscriptWindow.displayCost(unicode) == 2_800)

            // An 8 KiB answer with expanded 8 KiB reasoning fills the budget; a 6 KiB row cannot join it.
            let light = ChatMessage(role: .assistant)
            light.text = String(repeating: "c", count: 6 * 1_024)
            let rows = [heavy, light]
            #expect(
                TranscriptWindow.range(count: 2, startingAt: 0, cost: { TranscriptWindow.displayCost(rows[$0]) })
                    == 0..<1)
        }

        @Test func rangeStartingPastTheEndIsEmpty() {
            #expect(TranscriptWindow.range(count: 5, startingAt: 5, cost: { _ in 0 }).isEmpty)
            #expect(TranscriptWindow.range(count: 0, startingAt: 0, cost: { _ in 0 }).isEmpty)
        }

        @Test func oversizedStartIsAdmittedAlone() {
            let budget = TranscriptWindow.sourceBudget
            #expect(TranscriptWindow.range(count: 5, startingAt: 2, cost: { _ in budget }) == 2..<3)
        }

        @Test func rangeFillsBackwardUntilTheBudget() {
            let quarter = TranscriptWindow.sourceBudget / 4
            // Forward admits 8 and 9 (half the budget); backward admits 7 and 6, then 5 would exceed it.
            #expect(TranscriptWindow.range(count: 10, startingAt: 8, cost: { _ in quarter }) == 6..<10)
        }

        /// #60 A1 step 3: paging a long reply's segments keeps the reader's segment shown, always
        /// progresses and reaches every segment, and lays out at most the reply budget, or two segments
        /// when one alone fills it.
        @Test func replyPagingKeepsTheReadersSegmentAndReachesEverySegment() {
            let costs = [2_000, 16_384, 3_000, 3_000, 16_384, 16_384, 1_000, 1_000, 6_000, 6_000, 6_000, 500]
            let cost = { (index: Int) in costs[index] }
            let count = costs.count
            func fits(_ window: Range<Int>) -> Bool {
                window.count <= 2 || window.reduce(0) { $0 + cost($1) } <= ReplyWindow.budget
            }
            var window = ReplyWindow.latest(count: count, cost: cost)
            #expect(window.upperBound == count && fits(window))
            var seen = Set(window)
            while window.lowerBound > 0 {
                let earlier = ReplyWindow.earlier(window, count: count, cost: cost)
                #expect(earlier.contains(window.lowerBound), "\(window) -> \(earlier)")
                #expect(earlier.lowerBound < window.lowerBound && fits(earlier))
                #expect(earlier.count <= ReplyWindow.capacity)
                seen.formUnion(earlier)
                window = earlier
            }
            #expect(seen == Set(0..<count))
            while window.upperBound < count {
                let later = ReplyWindow.later(window, count: count, cost: cost)
                #expect(later.contains(window.upperBound - 1), "\(window) -> \(later)")
                #expect(later.upperBound > window.upperBound && fits(later))
                #expect(later.count <= ReplyWindow.capacity)
                window = later
            }
        }

        @Test func segmentWindowsResolveAgainstTheReply() {
            let small = { (_: Int) in 1_000 }
            #expect(
                SegmentWindow.latest.resolve(count: 10, cost: small) == nil, "A reply that fits shows every segment")
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
