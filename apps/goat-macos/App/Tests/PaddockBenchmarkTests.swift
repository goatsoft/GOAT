import Caprine
import Foundation
import XCTest

@testable import Paddock

/// Synthetic local measurements, not hardware-independent speed assertions or a UI frame trace.
@MainActor
final class PaddockBenchmarkTests: XCTestCase {
    func testReportColdAndCachedPreviewPreparation() async throws {
        var cold: [Double] = []
        var warm: [Double] = []
        for _ in 0..<5 {
            let cache = PreviewRuleCache()
            let start = ContinuousClock.now
            _ = try await cache.rule(mode: .blocked, offGrid: true)
            cold.append(Self.milliseconds(start.duration(to: .now)))
            for _ in 0..<10 {
                let start = ContinuousClock.now
                _ = try await cache.rule(mode: .blocked, offGrid: true)
                warm.append(Self.milliseconds(start.duration(to: .now)))
            }
            XCTAssertEqual(cache.compilationCount, 1)
        }
        print(
            "GOAT_BENCH rules first-use median_ms=\(Self.median(cold)) cached median_ms=\(Self.median(warm)) samples=5/50"
        )

        let artifact = PaddockArtifact(
            kind: .mermaid, content: String(repeating: "graph TD; A[<node>] --> B[&node];\n", count: 2000))
        let cache = PaddockDocumentCache()
        var first: [Double] = []
        var reused: [Double] = []
        for _ in 0..<20 {
            await cache.removeAll()
            let start = ContinuousClock.now
            let html = await cache.prepare(artifact, theme: ThemeCatalog.light, dark: false)
            first.append(Self.milliseconds(start.duration(to: .now)))
            XCTAssertNotNil(html)
            let warmStart = ContinuousClock.now
            let again = await cache.prepare(artifact, theme: ThemeCatalog.light, dark: false)
            reused.append(Self.milliseconds(warmStart.duration(to: .now)))
            XCTAssertEqual(html, again)
        }
        print(
            "GOAT_BENCH shell bytes=\(artifact.content.utf8.count) first-use median_ms=\(Self.median(first)) cached median_ms=\(Self.median(reused)) samples=20/20"
        )
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }
    private static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
}
