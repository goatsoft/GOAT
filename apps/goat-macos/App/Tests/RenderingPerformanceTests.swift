import Caprine
import CoreGraphics
import Foundation
import Paddock
import Testing

@testable import Bleet
@testable import GOAT

@MainActor
@Test func streamRevisionAndThinkingTailStayIncremental() {
    let message = ChatMessage(role: .assistant)

    message.appendStream(text: "", thinking: "first line")
    #expect(message.renderRevision == 1)
    #expect(message.thinkingTail == "first line")

    message.appendStream(text: "hello", thinking: " continued\nnewest line")
    #expect(message.renderRevision == 2)
    #expect(message.thinkingTail == "newest line")

    message.appendStream(text: " world", thinking: String(repeating: "x", count: 120))
    #expect(message.renderRevision == 3)
    #expect(message.thinkingTail.count == 90)
    #expect(message.text == "hello world")

    let continued = ChatMessage(role: .assistant)
    continued.appendStream(text: "", thinking: "split")
    continued.appendStream(text: "", thinking: " line\n")
    #expect(continued.thinkingTail == "split line")
}

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

@Test func paddockShellCacheReusesWorkTracksThemeAndBoundsAdmission() async throws {
    let cache = PaddockDocumentCache(maximumEntries: 1, maximumBytes: 16_384)
    let artifact = PaddockArtifact(kind: .mermaid, content: "graph TD; A-->B")
    let first = await cache.prepare(artifact, theme: ThemeCatalog.light, dark: false)
    #expect(first != nil)
    #expect(await cache.prepare(artifact, theme: ThemeCatalog.light, dark: false) == first)
    #expect(await cache.snapshot().preparations == 1)
    #expect(await cache.prepare(artifact, theme: ThemeCatalog.midnight, dark: true) != first)
    #expect(await cache.snapshot().preparations == 2)
    _ = await cache.prepare(
        PaddockArtifact(kind: .html, content: "<p>hello</p>"), theme: ThemeCatalog.light, dark: false)
    #expect(await cache.snapshot().entries == 1)
    #expect(await cache.snapshot().bytes <= 16_384)
    let oversized = PaddockArtifact(kind: .mermaid, content: String(repeating: "x", count: 100_001))
    #expect(await cache.prepare(oversized, theme: ThemeCatalog.light, dark: false) == nil)
    #expect(await cache.snapshot().preparations == 3)
    await cache.removeAll()
    #expect(await cache.snapshot().entries == 0)
}
