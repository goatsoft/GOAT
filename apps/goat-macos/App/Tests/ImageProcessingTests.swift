import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import GOAT

@Test func imagePreparationBoundsTheLongDimensionAndEmitsPNG() async throws {
    let source = try testPNG(width: 640, height: 320)
    let prepared = try #require(
        await ImageFileWorker().prepare(source, maxDimension: 128))

    #expect(prepared.preview.width == 128)
    #expect(prepared.preview.height == 64)
    let pngSource = try #require(CGImageSourceCreateWithData(prepared.pngData as CFData, nil))
    #expect(CGImageSourceGetCount(pngSource) == 1)
}

@Test func imagePreparationRejectsNonImageData() async {
    let prepared = await ImageFileWorker().prepare(Data("not an image".utf8))
    #expect(prepared == nil)
}

@Test func cancelledImagePreparationDoesNotPublishAResult() async throws {
    let source = try testPNG(width: 32, height: 32)
    let task = Task { await ImageFileWorker().prepare(source) }
    task.cancel()

    #expect(await task.value == nil)
}

private func testPNG(width: Int, height: Int) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let output = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
}
