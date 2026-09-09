import Foundation
import ImageIO
import Testing

@testable import GOAT

@Test(arguments: ["spinner-light", "spinner-dark"])
func bundledLoadingAnimationsDecodeCompositedFrames(name: String) throws {
    let url = try #require(Bundle.main.url(forResource: name, withExtension: "png"))
    let animation = try #require(LoadingAnimation.decode(url: url))
    #expect(animation.frames.count == 12)
    #expect(animation.delays.count == animation.frames.count)
    #expect(abs(animation.duration - 0.996) < 0.001)
    for frame in animation.frames {
        // The APNG stores partial rectangles. Image I/O must reconstruct full canvases.
        #expect(frame.width == 384 && frame.height == 384)
        #expect(frame.alphaInfo != .none && frame.alphaInfo != .noneSkipFirst && frame.alphaInfo != .noneSkipLast)
    }
    let first = try #require(animation.frames[0].dataProvider?.data)
    let next = try #require(animation.frames[1].dataProvider?.data)
    #expect((first as Data) != (next as Data))
    #expect(animation.frameIndex(at: 0) == 0)
    #expect(animation.frameIndex(at: 0.09) == 1)
    #expect(animation.frameIndex(at: animation.duration + 0.09) == 1)
    #expect(animation.frameIndex(at: .infinity) == 0)
}

@Test func loadingAnimationRejectsMissingData() {
    #expect(LoadingAnimation.decode(url: URL(fileURLWithPath: "/nonexistent/goat-spinner.png")) == nil)
}

@Test func loadingAnimationCacheReusesDecodedFrames() async throws {
    let first = try #require(await LoadingAnimationStore.shared.animation(dark: true))
    let second = try #require(await LoadingAnimationStore.shared.animation(dark: true))
    #expect(first.frames[0] === second.frames[0])
}
