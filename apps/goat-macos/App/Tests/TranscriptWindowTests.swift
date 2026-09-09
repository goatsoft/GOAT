import Testing

@testable import GOAT

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
