import AppKit
import Caprine
import CoreGraphics
import Foundation
import Paddock
import Persistence
import SwiftUI
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

@MainActor private func mounted<V: View>(_ view: V, width: CGFloat = 500) -> (NSWindow, NSHostingView<V>) {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: view)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    return (window, host)
}

extension AppTests.Bleet {
    @Suite(.serialized) struct SharedRenderingCacheTests {

        @Test @MainActor func partsCacheDeclinesSourcesAboveTheEntryCeiling() {
            let cache = TranscriptPartsCache(maximumEntries: 8, maximumTotalCost: 1_000, maximumEntryCost: 400)
            let small = String(repeating: "s", count: 150)  // cost 300
            let large = String(repeating: "l", count: 250)  // cost 500
            #expect(!cache.store([large], for: "a", source: large))
            #expect(cache.snapshot() == .init(entryCount: 0, totalCost: 0))
            #expect(cache.store([small], for: "a", source: small))
            #expect(cache.snapshot() == .init(entryCount: 1, totalCost: 300))
            // Declining a newer, oversized source also drops the stale entry for that owner.
            #expect(!cache.store([large], for: "a", source: large))
            #expect(cache.parts(for: "a", source: small) == nil)
            #expect(cache.snapshot() == .init(entryCount: 0, totalCost: 0))
        }

        @Test @MainActor func partsCacheAccountsReplacementAndEvictsLeastRecentlyUsed() {
            let cache = TranscriptPartsCache(maximumEntries: 8, maximumTotalCost: 1_000, maximumEntryCost: 400)
            let source = String(repeating: "x", count: 150)  // cost 300
            for key in ["a", "b", "c"] { cache.store([source], for: key, source: source) }
            #expect(cache.snapshot() == .init(entryCount: 3, totalCost: 900))
            _ = cache.parts(for: "a", source: source)  // a is now more recent than b
            cache.store([source], for: "d", source: source)
            #expect(cache.parts(for: "b", source: source) == nil, "The least recently used entry is evicted")
            #expect(cache.parts(for: "a", source: source) != nil)
            #expect(cache.snapshot() == .init(entryCount: 3, totalCost: 900))

            // Replacing an owner's source charges the new cost only.
            let shorter = String(repeating: "y", count: 100)  // cost 200
            cache.store([shorter], for: "a", source: shorter)
            #expect(cache.snapshot() == .init(entryCount: 3, totalCost: 800))

            // The entry count is bounded independently of cost.
            let counted = TranscriptPartsCache(maximumEntries: 2, maximumTotalCost: 1_000, maximumEntryCost: 400)
            for key in ["a", "b", "c"] { counted.store(["p"], for: key, source: "p") }
            #expect(counted.snapshot().entryCount == 2)
            #expect(counted.parts(for: "a", source: "p") == nil)
        }

        @Test @MainActor func oversizedPartsRenderFromTheViewAndEvictedPartsRebuild() async throws {
            let line = String(repeating: "x", count: 99) + "\n"
            let oversized = String(repeating: line, count: 600 * 1_024 / 100)  // cost above the 1 MiB ceiling
            let key = "test-oversized-\(UUID().uuidString)"
            let (window, host) = mounted(
                TranscriptTextPartsView(source: oversized, fontSize: 13, cacheKey: key)
                    .frame(width: 500).environment(AppModel.shared))
            // The first frame shows the latest text, never a placeholder. The source splits into whole
            // 8 KiB parts, so the last part is that same text, and preparation adds the part controls.
            let latest = host.fittingSize.height
            #expect(latest > 1_000, "The latest text shows before the parts are prepared (\(latest))")
            try await Task.sleep(for: .milliseconds(600))
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.height > latest, "View-owned parts render without global retention")
            #expect(TranscriptPartsCache.shared.parts(for: key, source: oversized) == nil)
            window.contentView = nil
            window.close()

            // After eviction a remounted view prepares and retains the parts again.
            let source = String(repeating: line, count: 16 * 1_024 / 100)
            let rebuildKey = "test-rebuild-\(UUID().uuidString)"
            TranscriptPartsCache.shared.store([source], for: rebuildKey, source: source)
            TranscriptPartsCache.shared.removeAll()
            let (again, _) = mounted(
                TranscriptTextPartsView(source: source, fontSize: 13, cacheKey: rebuildKey)
                    .frame(width: 500).environment(AppModel.shared))
            defer {
                again.contentView = nil
                again.close()
            }
            try await Task.sleep(for: .milliseconds(400))
            #expect(TranscriptPartsCache.shared.parts(for: rebuildKey, source: source)?.count == 2)
        }

        @Test @MainActor func partsViewNeverSplitsInItsInitializerAndRemountsFromCache() async throws {
            let line = String(repeating: "x", count: 99) + "\n"
            let source = String(repeating: line, count: 16 * 1_024 / 100)
            let key = "test-parts-\(UUID().uuidString)"
            func parts() -> some View {
                TranscriptTextPartsView(source: source, fontSize: 13, cacheKey: key)
                    .frame(width: 500).environment(AppModel.shared)
            }
            // First mount: nothing is prepared yet, so the first frame shows the latest text while the
            // parts are split off the main actor, and the initializer retains nothing.
            let (firstWindow, first) = mounted(parts())
            #expect(first.fittingSize.height > 1_000, "The latest text shows, never a placeholder")
            #expect(
                TranscriptPartsCache.shared.parts(for: key, source: source) == nil,
                "Preparation must happen off the initializer")
            try await Task.sleep(for: .milliseconds(400))
            first.layoutSubtreeIfNeeded()
            let prepared = first.fittingSize.height
            #expect(TranscriptPartsCache.shared.parts(for: key, source: source)?.count == 2)
            firstWindow.contentView = nil
            firstWindow.close()

            // Remount: the exact cached parts render on the first frame.
            let (window, again) = mounted(parts())
            defer {
                window.contentView = nil
                window.close()
            }
            #expect(again.fittingSize.height == prepared)
            #expect(
                TranscriptPartsCache.shared.parts(for: key, source: source + "y") == nil, "A changed source never hits")
        }

        @Test @MainActor func highlightFirstFrameUsesTheEnvironmentSchemeAndSkipsPreparation() async throws {
            let code = "let marker = \"\(UUID().uuidString)\""
            let dark = try await CodeSyntaxHighlighter.shared.render(code, language: "swift", dark: true)
            HighlightCache.shared.set(code: code, language: "swift", dark: true, text: dark, lineCount: 1)
            let warmed = await CodeSyntaxHighlighter.shared.preparations(of: code)

            // The app prefers dark while the system appearance is light.
            let previous = NSApp.appearance
            NSApp.appearance = NSAppearance(named: .aqua)
            defer { NSApp.appearance = previous }
            #expect(
                PreparedCodeText.displayText(
                    code: code, language: "swift", dark: true, isStreaming: false, rendered: nil, renderedKey: nil)
                    == dark)

            let (window, _) = mounted(
                PreparedCodeText(code: code, language: "swift").environment(\.colorScheme, .dark))
            try await Task.sleep(for: .milliseconds(300))
            #expect(
                await CodeSyntaxHighlighter.shared.preparations(of: code) == warmed,
                "A resident entry is not prepared again")
            window.contentView = nil
            window.close()

            // After eviction the consumer prepares again rather than assuming the entry is resident.
            HighlightCache.shared.removeAll()
            let (evictedWindow, _) = mounted(
                PreparedCodeText(code: code, language: "swift").environment(\.colorScheme, .dark))
            defer {
                evictedWindow.contentView = nil
                evictedWindow.close()
            }
            try await Task.sleep(for: .milliseconds(500))
            #expect(await CodeSyntaxHighlighter.shared.preparations(of: code) > warmed)
        }

        @Test @MainActor func highlightCacheRequiresTheExactKey() {
            let text = AttributedString("x")
            HighlightCache.shared.set(code: "let a = 1", language: "swift", dark: false, text: text, lineCount: 1)
            #expect(HighlightCache.shared.peek(code: "let a = 1", language: "swift", dark: false)?.text == text)
            #expect(HighlightCache.shared.peek(code: "let a = 2", language: "swift", dark: false) == nil)
            #expect(HighlightCache.shared.peek(code: "let a = 1", language: "swift", dark: true) == nil)
            #expect(HighlightCache.shared.peek(code: "let a = 1", language: "python", dark: false) == nil)
        }

        @Test func toolPresentationCacheKeysEveryOutputAffectingInput() {
            let id = "presentation-\(UUID().uuidString)"
            let external = ToolEventSnapshot(id: id, server: "Files", tool: "lookup", arguments: #"{"q":"a"}"#)
            let memory = ToolEventSnapshot(id: id, server: "Memory", tool: "lookup", arguments: #"{"q":"a"}"#)
            #expect(
                ToolActivityLabel.presentation(for: external).title != ToolActivityLabel.presentation(for: memory).title
            )

            let emptyArguments = ToolEventSnapshot(
                id: id, server: "Files", tool: "lookup", arguments: "{}", result: "{}")
            let valuedResult = ToolEventSnapshot(
                id: id, server: "Files", tool: "lookup", arguments: "{}", result: #"{"hits":1}"#)
            #expect(!ToolActivityLabel.presentation(for: emptyArguments).hasDetails)
            #expect(ToolActivityLabel.presentation(for: valuedResult).hasDetails)
        }

        @Test @MainActor func clearingEmptiesEveryOwnedLayerBeforeReturning() async throws {
            let id = UUID()
            let source = "**clear** \(id.uuidString)"
            let cache = MarkdownRenderCache(maximumEntries: 4, maximumSourceBytes: 4_096)
            guard case .parsed(let content) = await cache.prepare(id: id, source: source) else {
                Issue.record("Markdown did not parse")
                return
            }
            MarkdownContentCache.shared.set(id: id, source: source, content: content)
            HighlightCache.shared.set(
                code: source, language: nil, dark: false, text: AttributedString(source), lineCount: 1)
            TranscriptPartsCache.shared.store([source], for: "clear-\(id)", source: source)
            JSONValueCache.shared.set(source, value: .string(source))

            await RenderingCaches.clear()
            await cache.removeAll()

            #expect(MarkdownContentCache.shared.peek(id: id, source: source) == nil)
            #expect(HighlightCache.shared.peek(code: source, language: nil, dark: false) == nil)
            #expect(TranscriptPartsCache.shared.parts(for: "clear-\(id)", source: source) == nil)
            #expect(JSONValueCache.shared.peek(source) == nil)
            #expect(await cache.snapshot().entryCount == 0)
        }
    }
}
