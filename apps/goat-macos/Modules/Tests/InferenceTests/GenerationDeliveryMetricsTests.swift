import Foundation
import Testing

@testable import Inference

@Test func deliveryDistinguishesBufferedOutputFromServerSpeed() {
    var delivery = GenerationDeliveryMetrics()
    delivery.receive(bytes: 1200, elapsed: 40)
    #expect(delivery.firstOutputSeconds == 40)
    #expect(delivery.receivedBytesPerSecond == nil)
    delivery.receive(bytes: 300, elapsed: 42)
    #expect(delivery.maximumOutputGap == 2)
    #expect(delivery.receivedBytesPerSecond == 750)
    delivery.published(seconds: 0.004)
    delivery.published(seconds: 0.080)
    #expect(delivery.publicationCount == 2)
    #expect(delivery.maximumPublicationSeconds == 0.080)
    var stats = GenStats(ttft: 1, tokens: 100, duration: 42, generationTokensPerSecond: 37)
    stats.delivery = delivery
    #expect(stats.toksPerSec == 37)
}

@Test func deliveryIgnoresInvalidAndEmptyMeasurements() {
    var delivery = GenerationDeliveryMetrics()
    delivery.receive(bytes: 0, elapsed: 1)
    delivery.receive(bytes: 20, elapsed: .nan)
    #expect(delivery.firstOutputSeconds == nil)
    delivery.receive(bytes: 30, elapsed: 2)
    delivery.receive(bytes: 50, elapsed: 1)
    delivery.published(seconds: -.infinity)
    #expect(delivery.outputBytes == 30)
    #expect(delivery.outputEvents == 1)
    #expect(delivery.publicationCount == 0)
}
