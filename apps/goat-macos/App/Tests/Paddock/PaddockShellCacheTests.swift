import Caprine
import CoreGraphics
import Foundation
import Paddock
import Testing

@testable import Bleet
@testable import GOAT

extension AppTests.Paddock {
    @Suite struct PaddockShellCacheTests {

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
