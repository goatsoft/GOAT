import AppKit
import Caprine
import CoreGraphics
import Foundation
import Paddock
import Testing

@testable import Bleet
@testable import GOAT

extension AppTests.Paddock {
    @Suite struct PaddockShellCacheTests {
        @Test @MainActor func inlinePreviewSlotsPromoteWaitingArtifactsAndReleaseOnHide() {
            let budget = InlinePreviewBudget(limit: 2)
            let ids = (0..<4).map { _ in UUID() }
            for id in ids { budget.update(id, visible: true) }
            budget.update(ids[0], visible: true)
            #expect(budget.requested.count == 4)
            #expect(ids.filter(budget.admits) == Array(ids.prefix(2)))
            budget.update(ids[0], visible: false)
            #expect(ids.filter(budget.admits) == [ids[1], ids[2]])
            for id in ids { budget.update(id, visible: false) }
            #expect(budget.requested.isEmpty)
        }

        @Test @MainActor func inlineSnapshotsEnforceBothByteAndEntryLimits() {
            let cache = InlinePreviewSnapshots(maximumBytes: 3_200, maximumEntries: 2)
            let ids = (0..<3).map { _ in UUID() }
            let image = NSImage(size: NSSize(width: 10, height: 10))
            for id in ids { cache.store(image, for: id) }
            #expect(cache.image(for: ids[0]) == nil)
            #expect(cache.image(for: ids[1]) != nil)
            #expect(cache.bytes == 3_200)
            cache.store(NSImage(size: NSSize(width: 100, height: 100)), for: ids[2])
            #expect(cache.image(for: ids[2]) == nil)
            #expect(cache.bytes == 1_600)
            cache.remove(ids[1])
            #expect(cache.bytes == 0)
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
    }
}

extension AppTests.Paddock {
    @Suite struct ArtifactExportTests {

        @Test(arguments: [("vue", "vue"), ("tsx", "tsx"), ("jsx", "jsx"), (" TS ", "ts"), ("TypeScript", "ts")])
        func codeFenceExportsKeepTheirSourceExtension(language: String, fileExtension: String) {
            let artifact = PaddockArtifact(kind: .code(language: language), content: "source")
            #expect(artifact.suggestedFilename == "goat-artifact.\(fileExtension)")
        }
    }
}
