import Foundation
import Testing

@testable import Bleet

@Test func liveMetricsCountBytesRatherThanStreamChunks() {
    let start = Date(timeIntervalSinceReferenceDate: 100)
    var batched = LiveGenerationMetrics()
    batched.append(bytes: 300, at: start)
    var split = LiveGenerationMetrics()
    for _ in 0..<100 { split.append(bytes: 3, at: start) }
    #expect(batched.estimatedTokens == split.estimatedTokens)
    #expect(batched.tokensPerSecond(at: start) == nil)
    #expect(batched.tokensPerSecond(at: start.addingTimeInterval(2)) == 50)
    #expect(split.tokensPerSecond(at: start.addingTimeInterval(2)) == 50)
    #expect(batched.tokensPerSecond(at: start.addingTimeInterval(4)) == 25)
}
