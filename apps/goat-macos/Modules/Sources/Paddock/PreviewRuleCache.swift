import Foundation
import JUDAS
import WebKit
import os.signpost

/// Compiled policy is immutable and contains no artifact content or authority grants. Requests
/// for the same rules share one compilation, including overlapping preview creation (ADR-0056).
@MainActor
final class PreviewRuleCache {
    static let shared = PreviewRuleCache()
    private static let log = OSLog(subsystem: "dev.leet.goat", category: .pointsOfInterest)
    private enum CompilationError: Error { case unavailable }
    private struct Entry {
        let id: UUID
        let task: Task<WKContentRuleList, Error>
    }
    private var entries: [String: Entry] = [:]
    private(set) var compilationCount = 0

    func rule(mode: JudasMode, offGrid: Bool) async throws -> WKContentRuleList? {
        guard let rules = Judas.previewRules(mode: mode, offGrid: offGrid) else { return nil }
        if let entry = entries[rules] { return try await entry.task.value }
        // Only two rule documents exist: loopback resources allowed, or all network blocked.
        // Key by the exact document so future policy changes cannot reuse stale compiled rules.
        let id = UUID()
        compilationCount += 1
        let task = Task { @MainActor in
            let signpost = OSSignpostID(log: Self.log)
            os_signpost(.begin, log: Self.log, name: "PreviewRuleCompile", signpostID: signpost)
            defer { os_signpost(.end, log: Self.log, name: "PreviewRuleCompile", signpostID: signpost) }
            guard
                let list = try await WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: "goat.judas.cached.\(mode == .blocked ? "blocked" : "loopback")",
                    encodedContentRuleList: rules)
            else { throw CompilationError.unavailable }
            return list
        }
        entries[rules] = Entry(id: id, task: task)
        do {
            return try await task.value
        } catch {
            if entries[rules]?.id == id { entries.removeValue(forKey: rules) }
            throw error
        }
    }
}
