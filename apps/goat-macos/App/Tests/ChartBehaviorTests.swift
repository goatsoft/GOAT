import Foundation
import Testing

@testable import Bleet
@testable import GOAT
@testable import Inference

@Test func tachometerTracksRollingSpeedAndSettlesToZeroDuringAStall() {
    var meter = GenerationRateMeter()
    let start = Date(timeIntervalSinceReferenceDate: 100)
    meter.sample(tokens: 0, at: start)
    #expect(meter.rate == nil)
    for tick in 1...4 {
        meter.sample(tokens: tick * 25, at: start.addingTimeInterval(Double(tick) / 4))
        #expect(meter.rate == 100)
    }
    for tick in 5...8 {
        meter.sample(tokens: 100, at: start.addingTimeInterval(Double(tick) / 4))
    }
    #expect(meter.rate == 0)
}

@Test func tachometerRestartsItsBaselineAfterPausesAndCounterResets() {
    var meter = GenerationRateMeter()
    let start = Date(timeIntervalSinceReferenceDate: 100)
    meter.sample(tokens: 100, at: start)
    meter.sample(tokens: 125, at: start.addingTimeInterval(0.25))
    #expect(meter.rate == 100)
    meter.sample(tokens: 900, at: start.addingTimeInterval(20))
    #expect(meter.rate == nil)
    meter.sample(tokens: 925, at: start.addingTimeInterval(20.25))
    #expect(meter.rate == 100)
    meter.sample(tokens: 0, at: start.addingTimeInterval(20.5))
    #expect(meter.rate == nil)
    meter.sample(tokens: 25, at: start.addingTimeInterval(20.75))
    #expect(meter.rate == 100)
    meter.reset()
    #expect(meter.rate == nil)
}

@Test func tachometerIgnoresInvalidSamplesAndUsesReadableScaleSteps() {
    var meter = GenerationRateMeter()
    let start = Date(timeIntervalSinceReferenceDate: 100)
    meter.sample(tokens: 0, at: start)
    meter.sample(tokens: 100, at: start.addingTimeInterval(-1))
    meter.sample(tokens: -1, at: start.addingTimeInterval(0.1))
    meter.sample(tokens: 100, at: Date(timeIntervalSinceReferenceDate: .nan))
    meter.sample(tokens: 25, at: start.addingTimeInterval(0.25))
    #expect(meter.rate == 100)
    #expect(GenerationRateMeter.scale(containing: nil) == 100)
    #expect(GenerationRateMeter.scale(containing: .infinity) == 100)
    #expect(GenerationRateMeter.scale(containing: 101) == 250)
    #expect(GenerationRateMeter.scale(containing: 500) == 500)
    #expect(GenerationRateMeter.scale(containing: 501) == 1000)
    #expect(GenerationRateMeter.scale(containing: 500_001) == 1_000_000)
}

@Test func throughputSamplesShowStallsAndRemainBounded() {
    var series = GenerationRateSeries()
    let start = Date(timeIntervalSinceReferenceDate: 100)
    series.sample(tokens: 10, at: start)
    series.sample(tokens: 110, at: start.addingTimeInterval(1))
    series.sample(tokens: 110, at: start.addingTimeInterval(2))
    #expect(series.samples.map(\.rate) == [100, 0])
    for second in 3...1000 {
        series.sample(tokens: second * 100, at: start.addingTimeInterval(Double(second)))
    }
    #expect(series.samples.count == GenerationRateSeries.capacity)
    #expect(series.samples.last?.rate == 100)
}

@Test func throughputRejectsOutOfOrderSamplesAndResumesWithoutFalseStalls() {
    var series = GenerationRateSeries()
    let start = Date(timeIntervalSinceReferenceDate: 100)
    series.sample(tokens: 10, at: start)
    series.sample(tokens: 200, at: start.addingTimeInterval(-1))
    series.sample(tokens: 30, at: start.addingTimeInterval(1))
    #expect(series.samples.last?.rate == 20)
    series.pause()
    series.sample(tokens: 900, at: start.addingTimeInterval(100))
    #expect(series.samples.count == 1)
    series.sample(tokens: 940, at: start.addingTimeInterval(102))
    #expect(series.samples.last?.rate == 20)
    series.sample(tokens: 0, at: start.addingTimeInterval(103))
    #expect(series.samples.isEmpty)
}

@Test func throughputIgnoresInvalidAndTooFrequentSamples() {
    var series = GenerationRateSeries()
    let start = Date(timeIntervalSinceReferenceDate: 100)
    series.sample(tokens: 0, at: start)
    series.sample(tokens: -1, at: start.addingTimeInterval(1))
    series.sample(tokens: 100, at: Date(timeIntervalSinceReferenceDate: .nan))
    series.sample(tokens: 10, at: start.addingTimeInterval(0.1))
    series.sample(tokens: 100, at: start.addingTimeInterval(1))
    #expect(series.samples.map(\.rate) == [100])
}

@Test func generationBarsKeepReportedAndDerivedRatesDistinct() throws {
    let reported = try #require(
        GenerationChartValue(
            id: UUID(), ordinal: 1,
            stats: GenStats(ttft: 1, tokens: 100, duration: 5, tokensAreExact: true, generationTokensPerSecond: 80)))
    #expect(reported.rate == 80)
    #expect(reported.reported)
    let derived = try #require(
        GenerationChartValue(
            id: UUID(), ordinal: 2,
            stats: GenStats(ttft: 1, tokens: 100, duration: 5)))
    #expect(derived.rate == 25)
    #expect(!derived.reported)
    #expect(
        GenerationChartValue(
            id: UUID(), ordinal: 3,
            stats: GenStats(ttft: nil, tokens: 0, duration: 0)) == nil)
}

@Test func cameraZoomKeepsPointerAnchorStableAndClampsExtremes() {
    var camera = GraphCamera()
    let size = CGSize(width: 800, height: 400)
    let anchor = CGPoint(x: 500, y: 300)
    camera.scale(to: 2, anchor: anchor, size: size)
    #expect(camera.zoom == 2)
    #expect(camera.pan == CGSize(width: -100, height: -100))
    camera.scale(to: 1, anchor: anchor, size: size)
    #expect(camera.pan == .zero)
    camera.scale(to: 100, anchor: anchor, size: size)
    #expect(camera.zoom == GraphCamera.maximumZoom)
    camera.scale(to: -100, anchor: anchor, size: size)
    #expect(camera.zoom == GraphCamera.minimumZoom)
    camera.move(to: CGSize(width: 1e9, height: -1e9), size: size)
    #expect(camera.pan == CGSize(width: 3200, height: -1600))
}

@Test func cameraRejectsNonFiniteInputsAndBoundsRotation() {
    var camera = GraphCamera()
    let size = CGSize(width: 800, height: 400)
    camera.scale(to: .infinity, anchor: .zero, size: size)
    camera.scale(to: 2, anchor: .zero, size: .zero)
    camera.move(to: CGSize(width: CGFloat.nan, height: 1), size: size)
    camera.move(to: .zero, size: CGSize(width: CGFloat.infinity, height: 400))
    camera.orbit(horizontal: .nan, vertical: 0)
    #expect(camera == GraphCamera())
    camera.orbit(horizontal: .pi * 21, vertical: 0)
    #expect(abs(camera.yaw - .pi) < 0.00001)
}

@Test @MainActor func contextChartHandlesOverflowAndInvalidCapacity() throws {
    let session = ChatSession(effort: .trot, modelID: nil)
    session.lastContextTokens = Int.max
    session.lastContextWindow = 1000
    session.isStreaming = true
    let message = ChatMessage(role: .assistant)
    message.appendStream(text: "some output", thinking: "")
    session.messages = [message]
    let full = try #require(ContextStatus(session: session, models: [], defaultModelID: nil))
    #expect(full.used == Int.max)
    #expect(full.ratio == 1)
    session.lastContextPressureLimit = 0
    let invalid = try #require(ContextStatus(session: session, models: [], defaultModelID: nil))
    #expect(invalid.ratio == nil)
}

@Test func cameraWheelZoomIsGradualReversibleAndSupportsCloseInspection() {
    var camera = GraphCamera()
    let size = CGSize(width: 800, height: 400)
    let anchor = CGPoint(x: 780, y: 380)
    camera.scroll(delta: 20, precise: true, anchor: anchor, size: size)
    #expect(camera.zoom > 1 && camera.zoom < 1.07)
    camera.scroll(delta: -20, precise: true, anchor: anchor, size: size)
    #expect(abs(camera.zoom - 1) < 0.00001)
    #expect(abs(camera.pan.width) < 0.00001)
    camera.scroll(delta: 1e9, precise: false, anchor: anchor, size: size)
    #expect(camera.zoom < 1.23)
    camera = GraphCamera()
    camera.scale(to: 20, anchor: anchor, size: size)
    #expect(camera.zoom == 20)
    // Close zoom must preserve the pointer anchor beyond the old four-viewport pan limit.
    #expect(camera.pan == CGSize(width: -7220, height: -3420))
    camera.scale(to: 1, anchor: anchor, size: size)
    #expect(abs(camera.pan.width) < 0.00001)
    #expect(abs(camera.pan.height) < 0.00001)
    camera.scroll(delta: .infinity, precise: true, anchor: anchor, size: size)
    #expect(camera.zoom == 1)
}
