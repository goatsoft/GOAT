import Caprine
import CoreGraphics
import Foundation
import Paddock
import Testing

@testable import Bleet
@testable import GOAT

private func renderTestImage(width: Int, height: Int) throws -> CGImage {
    let context = try #require(
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}
extension AppTests.Bleet {
    @Suite struct RenderingCacheTests {

        @Test func transcriptFollowThrottleCapsExplicitScrollCommands() {
            var throttle = TranscriptFollowThrottle(maximumUpdatesPerSecond: 10)
            #expect(throttle.delay(at: 4) == 0)
            throttle.recordFire(at: 4)
            #expect(abs(throttle.delay(at: 4.04) - 0.06) < 0.000_001)
            #expect(throttle.delay(at: 4.1) == 0)
            throttle.reset()
            #expect(throttle.delay(at: 4.01) == 0)
        }

        @Test func markdownCacheReusesParsesAndEvictsWithinBounds() async {
            let cache = MarkdownRenderCache(
                maximumEntries: 2,
                maximumSourceBytes: 16,
                maximumEntrySourceBytes: 8)
            let first = UUID()

            guard case .parsed = await cache.prepare(id: first, source: "**one**") else {
                Issue.record("Expected bounded Markdown to parse")
                return
            }
            _ = await cache.prepare(id: first, source: "**one**")
            #expect(await cache.snapshot().parseCount == 1)

            _ = await cache.prepare(id: UUID(), source: "two")
            _ = await cache.prepare(id: UUID(), source: "three")
            let bounded = await cache.snapshot()
            #expect(bounded.entryCount == 2)
            #expect(bounded.sourceBytes <= 16)
            #expect(bounded.parseCount == 3)

            guard case .plainText = await cache.prepare(id: UUID(), source: String(repeating: "x", count: 9)) else {
                Issue.record("Expected oversized Markdown to bypass rich parsing")
                return
            }
            #expect(await cache.snapshot().parseCount == 3)
        }

        @Test func decodedImageCacheEvictsLeastRecentlyUsedBitmap() throws {
            let first = try renderTestImage(width: 8, height: 8)
            let second = try renderTestImage(width: 12, height: 12)
            var cache = DecodedImageCache(maximumEntries: 1, maximumBytes: 4_096)

            cache.insert(first, for: "first")
            #expect(cache.image(for: "first") != nil)
            cache.insert(second, for: "second")

            #expect(cache.image(for: "first") == nil)
            #expect(cache.image(for: "second") != nil)
            #expect(cache.snapshot().entryCount == 1)
            #expect(cache.snapshot().byteCost <= 4_096)
            cache.removeAll()
            #expect(cache.snapshot().byteCost == 0)
            cache.insert(first, for: "first")
            #expect(cache.image(for: "first") != nil)
        }

        @Test func markdownCacheReplacesChangedSourceUnderSameMessageIdentity() async {
            let cache = MarkdownRenderCache()
            let id = UUID()
            _ = await cache.prepare(id: id, source: "Original")
            _ = await cache.prepare(id: id, source: "**Revised**")
            _ = await cache.prepare(id: id, source: "**Revised**")
            let snapshot = await cache.snapshot()
            #expect(snapshot.entryCount == 1)
            #expect(snapshot.parseCount == 2)
            #expect(snapshot.sourceBytes == "**Revised**".utf8.count)
            await cache.removeAll()
            #expect(await cache.snapshot().sourceBytes == 0)
            _ = await cache.prepare(id: id, source: "**Revised**")
            #expect(await cache.snapshot().parseCount == 3)
        }
    }
}
