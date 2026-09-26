import AppKit
import Caprine
import CoreGraphics
import Foundation
import MarkdownUI
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
            let placeholder = host.fittingSize.height
            try await Task.sleep(for: .milliseconds(600))
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.height > placeholder * 4, "View-owned parts render without global retention")
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
            // First mount: nothing is prepared yet, so the first frame is the short placeholder.
            let (firstWindow, first) = mounted(parts())
            let placeholder = first.fittingSize.height
            try await Task.sleep(for: .milliseconds(400))
            first.layoutSubtreeIfNeeded()
            let prepared = first.fittingSize.height
            #expect(
                prepared > placeholder * 4,
                "Preparation must happen off the initializer (\(placeholder) -> \(prepared))")
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

/// Fence info strings with the language and filename they name (#60 A6).
private let fenceInfoCases: [(String?, String?, String?)] = [
    ("swift", "swift", nil), ("{.swift}", "swift", nil), ("ts:src/app.ts", "ts", "src/app.ts"),
    ("swift title=\"Foo Bar.swift\"", "swift", "Foo Bar.swift"), ("python filename=app.py", "python", "app.py"),
    ("python app.py", "python", "app.py"), ("swift linenos", "swift", nil),
    ("rust title='src/main.rs' highlight=3", "rust", "src/main.rs"), ("", nil, nil), (nil, nil, nil),
]

extension AppTests.Bleet {
    /// #60 A6: persistent code block chrome, info strings, collapse and remembered choices.
    @Suite(.serialized) struct CodeBlockChromeTests {
        @Test(arguments: fenceInfoCases)
        func fenceInfoStringsGiveALanguageAndAFilename(info: String?, language: String?, filename: String?) {
            let parsed = FenceInfo(info)
            #expect(parsed == FenceInfo(language: language, filename: filename), "\(info ?? "nil")")
        }

        @Test func collapsedCodeKeepsItsFirstLines() {
            let code = (1...50).map { "line \($0)" }.joined(separator: "\n") + "\n"
            let shown = CodeBlockView.prefix(of: code, lines: 40)
            #expect(shown.split(separator: "\n").count == 40 && shown.hasSuffix("line 40"))
            #expect(CodeBlockView.prefix(of: "short\n", lines: 40) == "short\n")
        }

        @MainActor private func height(_ source: String, scope: CodeBlockScope? = nil) async throws -> CGFloat {
            let content = scope?.content.value ?? MarkdownContent(source)
            let host = NSHostingView(
                rootView: Markdown(content).goatMarkdownStyle(fontSize: 14)
                    .environment(\.codeBlockScope, scope)
                    .frame(width: 600).environment(AppModel.shared))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer {
                window.contentView = nil
                window.close()
            }
            try await Task.sleep(for: .milliseconds(400))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }

        /// Blocks over the limit show their first lines; expanding is remembered when the block is
        /// recreated.
        @Test @MainActor func longBlocksCollapseAndAnExpansionSurvivesRecreation() async throws {
            let marker = UUID().uuidString
            let lines = (0..<60).map { "let value\($0) = \"\(marker)\"" }
            let fence = "```"
            let source = "\(fence)swift title=Values.swift\n" + lines.joined(separator: "\n") + "\n\(fence)"
            let short = "\(fence)swift\n" + lines.prefix(40).joined(separator: "\n") + "\n\(fence)"
            let collapsed = try await height(source)
            let exactlyAtLimit = try await height(short)
            // The collapsed block is the 40-line block plus one action row.
            #expect(collapsed > exactlyAtLimit && collapsed < exactlyAtLimit + 40, "\(collapsed) vs \(exactlyAtLimit)")

            let scope = Self.scope(source)
            let identity = try #require(
                CodeBlockPositions.shared.identity(of: lines.joined(separator: "\n") + "\n", occurrence: 0, in: scope))
            CodeBlockStateStore.shared.set(.init(wordWrap: nil, isExpanded: true), for: identity)
            let expanded = try await height(source, scope: scope)
            #expect(expanded > collapsed + 200, "The remembered expansion shows every line: \(expanded)")
        }

        private static func scope(_ source: String, messageID: UUID = UUID()) -> CodeBlockScope {
            CodeBlockScope(
                messageID: messageID, segment: 0,
                content: PreparedMarkdownContent(value: MarkdownSegmentCache.content(source)), preparationID: 1,
                isFencePiece: false)
        }

        /// Review of #75: a choice made while a block is shorter than any prefix key survives the block
        /// growing and being recreated, because its identity is its position, not its text.
        @Test @MainActor func aChoiceMadeEarlyInAStreamingBlockSurvivesItsGrowth() async throws {
            let fence = "```"
            let messageID = UUID()
            let cache = MarkdownSegmentCache()
            let opening = "Intro.\n\n\(fence)swift\nlet a = 1\n"
            let early = try #require(await cache.prepare(id: messageID, source: opening, isComplete: false))
            let body = (0..<40).map { "let v\($0) = \($0)" }.joined(separator: "\n") + "\n"
            let grown = opening + body + "\(fence)\n\nDone."
            let later = try #require(await cache.prepare(id: messageID, source: grown, isComplete: true))
            func identity(_ document: PreparedMarkdownDocument, _ code: String) throws -> CodeBlockIdentity? {
                let segment = try #require(document.segments.first { $0.text.contains("let a = 1") })
                guard case .parsed(let content) = segment.preparation else { return nil }
                let scope = CodeBlockScope(
                    messageID: messageID, segment: segment.index, content: content,
                    preparationID: segment.preparationID, isFencePiece: false)
                return CodeBlockPositions.shared.identity(of: code, occurrence: 0, in: scope)
            }
            let before = try #require(try identity(early, "let a = 1\n"))
            CodeBlockStateStore.shared.set(.init(wordWrap: true, isExpanded: true), for: before)
            let after = try #require(try identity(later, "let a = 1\n" + body))
            #expect(after == before)
            #expect(CodeBlockStateStore.shared.state(for: after) == .init(wordWrap: true, isExpanded: true))
        }

        /// Blocks that share a long opening (a license header) keep independent choices within a reply and
        /// across replies.
        @Test @MainActor func blocksWithEqualOpeningsKeepIndependentChoices() throws {
            let fence = "```"
            let header = (0..<12).map { "// Licensed under the Example License, line \($0) of the header." }
                .joined(separator: "\n")
            #expect(header.utf8.count > 256)
            let first = header + "\nlet first = 1\n"
            let second = header + "\nlet second = 2\n"
            let source = "\(fence)swift\n\(first)\(fence)\n\nBetween.\n\n\(fence)swift\n\(second)\(fence)\n"
            let scope = Self.scope(source)
            let one = try #require(CodeBlockPositions.shared.identity(of: first, occurrence: 0, in: scope))
            let two = try #require(CodeBlockPositions.shared.identity(of: second, occurrence: 1, in: scope))
            #expect(one != two && one.position == 0 && two.position == 1)
            let elsewhere = try #require(
                CodeBlockPositions.shared.identity(of: first, occurrence: 0, in: Self.scope(source)))
            #expect(elsewhere != one, "Another reply's equal block has its own identity")
            // Without an occurrence tag, the literal's position still tells the two apart.
            let untagged = try #require(CodeBlockPositions.shared.identity(of: second, occurrence: nil, in: scope))
            #expect(untagged.position == 1 && !untagged.isOccurrence, "An untagged literal has its own namespace")

            let store = CodeBlockStateStore()
            store.set(.init(wordWrap: true), for: one)
            #expect(store.state(for: two) == CodeBlockStateStore.State())
            #expect(store.state(for: elsewhere) == CodeBlockStateStore.State())
        }

        /// Review of #75: identical literals in one segment keep independent choices. Each fence carries its
        /// occurrence through the info string, and the code itself is unchanged.
        @Test @MainActor func identicalBlocksKeepIndependentChoices() async throws {
            let fence = "```"
            let code = (0..<60).map { "let same\($0) = \($0)" }.joined(separator: "\n") + "\n"
            let source = "\(fence)swift\n\(code)\(fence)\n\nAgain:\n\n\(fence)swift\n\(code)\(fence)\n"
            let tagged = try #require(CodeBlockTags.tagged(source))
            let infos = tagged.split(separator: "\n").filter { $0.hasPrefix(fence) && $0.count > 3 }
                .map { FenceInfo(String($0.dropFirst(3))) }
            #expect(infos.map(\.language) == ["swift", "swift"] && infos.map(\.occurrence) == [0, 1])
            #expect(
                CodeBlockPositions.codeBlocks(html: MarkdownContent(tagged).renderHTML())
                    == CodeBlockPositions.codeBlocks(html: MarkdownContent(source).renderHTML()),
                "Tags never reach the code")

            // Rendered: expanding the second block expands only it.
            let messageID = UUID()
            let scope = Self.scope(source, messageID: messageID)
            let neither = try await height(source, scope: scope)
            let second = CodeBlockIdentity(messageID: messageID, segment: 0, position: 1)
            CodeBlockStateStore.shared.set(.init(wordWrap: nil, isExpanded: true), for: second)
            let one = try await height(source, scope: scope)
            let first = CodeBlockIdentity(messageID: messageID, segment: 0, position: 0)
            CodeBlockStateStore.shared.set(.init(wordWrap: nil, isExpanded: true), for: first)
            let both = try await height(source, scope: scope)
            #expect(neither + 200 < one && one + 200 < both, "\(neither) < \(one) < \(both)")
        }

        /// A streaming duplicate keeps its occurrence as it grows past, and away from, the earlier block.
        @Test func aGrowingDuplicateKeepsItsOccurrence() throws {
            let fence = "```"
            let opening = "\(fence)swift\nlet a = 1\n\(fence)\n\nMore:\n\n\(fence)swift\nlet a = 1\n"
            for source in [opening, opening + "let b = 2\n", opening + "let b = 2\n\(fence)\n\nDone."] {
                let tagged = try #require(CodeBlockTags.tagged(source))
                let occurrences = tagged.split(separator: "\n").filter { $0.hasPrefix(fence) && $0.count > 3 }
                    .map { FenceInfo(String($0.dropFirst(3))).occurrence }
                #expect(occurrences == [0, 1], "\(source)")
            }
        }

        /// Where a fence-like line is not an opener (indented code) or an HTML block may hold one, the tags
        /// are not used, so no code or text ever shows them.
        @Test func tagsNeverReachCodeOrHTMLText() throws {
            let fence = "```"
            let indented = "Code:\n\n    \(fence)swift\n    let a = 1\n"
            #expect(!MarkdownSegmentCache.content(indented).renderHTML().contains(CodeBlockTags.key))
            #expect(CodeBlockTags.tagged("<div>\n\(fence)swift\nx\n\(fence)\n</div>\n") == nil)
            #expect(CodeBlockTags.tagged("No fences here.") == nil)
            for line in ["<div>", "</section>", "<!-- note -->", "<?xml", "<br/>", "<p class=\"x\">", "<table"] {
                #expect(CodeBlockTags.startsHTMLBlock(line[...]), "\(line)")
            }
            for line in ["<https://example.com>", "<mailto:goat@example.com>", "<3 goats", "< div>", "a <div>"] {
                #expect(!CodeBlockTags.startsHTMLBlock(line[...]), "\(line)")
            }
            let long = "\(fence)\(fence)swift\n\(fence)swift inner\n\(fence)\(fence)\n"
            let tagged = try #require(CodeBlockTags.tagged(long))
            #expect(tagged.components(separatedBy: CodeBlockTags.key).count == 2, "Only the outer fence opens")
        }

        /// Review of #75: duplicates stay distinct beside an autolink, which is not an HTML block. Where a
        /// segment may hold an HTML block and is left untagged, duplicate literals get no shared identity
        /// (their choices stay with their views), and a unique block keeps its identity when a streaming
        /// segment stops being tagged, including after remounting.
        @Test @MainActor func duplicatesBesideAutolinksAndHTMLBlocksNeverShareAnIdentity() throws {
            let fence = "```"
            let duplicate = "\(fence)swift\nlet a = 1\n\(fence)\n\n"
            let unique = "\(fence)swift\nlet c = 3\n\(fence)\n\n"
            let positions = CodeBlockPositions()
            func identities(_ source: String, messageID: UUID) -> [CodeBlockIdentity?] {
                let content = MarkdownSegmentCache.content(source)
                let scope = CodeBlockScope(
                    messageID: messageID, segment: 0, content: PreparedMarkdownContent(value: content),
                    preparationID: UInt64(source.utf8.count), isFencePiece: false)
                // The occurrences MarkdownUI hands each block: tags in the parsed source, if it was tagged.
                let parsed = CodeBlockTags.tagged(source).flatMap {
                    CodeBlockTags.leaked(html: MarkdownContent($0).renderHTML()) ? nil : $0
                }
                let occurrences: [Int?] =
                    parsed.map { text in
                        text.split(separator: "\n").filter { $0.hasPrefix(fence) && $0.count > 3 }
                            .map { FenceInfo(String($0.dropFirst(3))).occurrence }
                    } ?? [nil, nil, nil]
                return zip(["let a = 1\n", "let a = 1\n", "let c = 3\n"], occurrences).map {
                    positions.identity(of: $0, occurrence: $1, in: scope)
                }
            }
            let messageID = UUID()

            let autolink = duplicate + duplicate + unique + "<https://example.com>\n"
            #expect(CodeBlockTags.tagged(autolink) != nil, "An autolink is not an HTML block")
            let tagged = identities(autolink, messageID: messageID)
            #expect(tagged.map { $0?.position } == [0, 1, 2])

            // Streaming appends an HTML block: the segment is left untagged.
            let html = autolink + "\n<div>\nraw\n</div>\n"
            #expect(CodeBlockTags.tagged(html) == nil)
            let untagged = identities(html, messageID: messageID)
            #expect(untagged[0] == nil && untagged[1] == nil, "Identical untagged literals share no identity")
            #expect(untagged[2]?.position == 2 && untagged[2]?.isOccurrence == false)
            #expect(untagged[2] != tagged[2], "Losing tags resets a fence's choices; it never maps onto another")
            // Remounting resolves the same way.
            #expect(identities(html, messageID: messageID) == untagged)
        }

        /// Review of #75: indented and fenced blocks count differently (literals count every code block,
        /// occurrences only fences), so their identities live in separate namespaces and never collide,
        /// tagged or not, after appending an HTML block, and after remounting.
        @Test @MainActor func indentedAndFencedBlocksNeverShareAnIdentity() throws {
            let fence = "```"
            let source = "    let indented = 1\n\n\(fence)swift\nlet fenced = 2\n\(fence)\n\n"
            let positions = CodeBlockPositions()
            let messageID = UUID()
            func identities(_ source: String) -> [CodeBlockIdentity?] {
                let content = MarkdownSegmentCache.content(source)
                let scope = CodeBlockScope(
                    messageID: messageID, segment: 0, content: PreparedMarkdownContent(value: content),
                    preparationID: UInt64(source.utf8.count), isFencePiece: false)
                let occurrence = CodeBlockTags.tagged(source).flatMap { text in
                    text.split(separator: "\n").first { $0.hasPrefix(fence) && $0.count > 3 }
                        .flatMap { FenceInfo(String($0.dropFirst(3))).occurrence }
                }
                return [
                    positions.identity(of: "let indented = 1\n", occurrence: nil, in: scope),
                    positions.identity(of: "let fenced = 2\n", occurrence: occurrence, in: scope),
                ]
            }
            let tagged = identities(source)
            #expect(tagged[0]?.position == 0 && tagged[0]?.isOccurrence == false)
            #expect(tagged[1]?.position == 0 && tagged[1]?.isOccurrence == true)
            #expect(tagged[0] != nil && tagged[0] != tagged[1], "Same number, different namespace")

            let html = source + "<div>\nraw\n</div>\n"
            let untagged = identities(html)
            #expect(untagged.compactMap { $0?.position } == [0, 1])
            #expect(untagged.allSatisfy { $0?.isOccurrence == false })
            #expect(untagged[0] != untagged[1] && untagged[1] != tagged[1])
            #expect(identities(html) == untagged, "Remounting resolves the same way")
        }

        /// Every piece of an oversized fence keeps its choices by the fence's first piece.
        @Test @MainActor func piecesOfAnOversizedFenceShareTheirFirstPiecesIdentity() async throws {
            let fence = "```"
            let code = (0..<400).map { "let value\($0) = \($0)" }.joined(separator: "\n")
            let source = "Before.\n\n\(fence)swift\n\(code)\n\(fence)\n\nAfter."
            let cache = MarkdownSegmentCache(targetBytes: 256, maximumBytes: 1_024)
            let document = try #require(await cache.prepare(id: UUID(), source: source, isComplete: true))
            let pieces = document.segments.filter { $0.kind == .fencedCodePiece }.map(\.index)
            #expect(pieces.count > 3)
            let first = try #require(pieces.first)
            for piece in pieces {
                #expect(SegmentedMarkdownView.codeSegment(of: piece, in: document.segments) == first)
            }
            let after = try #require(document.segments.last?.index)
            #expect(SegmentedMarkdownView.codeSegment(of: after, in: document.segments) == after)
        }

        @Test func codeBlockLiteralsAreReadFromTheParse() {
            let escaped = "if a &lt; b &amp;&amp; c { print(&quot;&gt;&quot;) }\n"
            let html =
                "<p>x</p>\n<pre><code class=\"language-swift\">\(escaped)</code></pre>\n"
                + "<pre><code>plain\n</code></pre>\n"
            #expect(CodeBlockPositions.codeBlocks(html: html) == ["if a < b && c { print(\">\") }\n", "plain\n"])
        }

        @Test @MainActor func choicesAreBoundedAndDefaultToTheGlobalWrap() {
            let store = CodeBlockStateStore(limit: 2)
            let message = UUID()
            let a = CodeBlockIdentity(messageID: message, segment: 0, position: 0)
            let b = CodeBlockIdentity(messageID: message, segment: 0, position: 1)
            let c = CodeBlockIdentity(messageID: message, segment: 0, position: 2)
            #expect(store.state(for: a) == CodeBlockStateStore.State())
            #expect(store.state(for: a).wordWrap == nil, "Without a choice the global preference applies")
            store.set(.init(wordWrap: true), for: a)
            store.set(.init(isExpanded: true), for: b)
            store.set(.init(isExpanded: true), for: c)
            #expect(store.state(for: a) == CodeBlockStateStore.State())
            #expect(store.state(for: c).isExpanded)
        }
    }
}

extension AppTests.Bleet {
    /// #60 D3: a 68ch reading measure from the chat font, a shared centred column and bounded bubbles.
    @Suite(.serialized) struct ReadingMeasureTests {
        @Test @MainActor func theMeasureFollowsTheChatFontAndSize() {
            let font = ReadingFonts.nsFont("system", size: 14, role: .chat)
            let zero = ("0" as NSString).size(withAttributes: [.font: font]).width
            let measure = ReadingMeasure.prose(fontID: "system", size: 14)
            #expect(abs(measure - zero * 68) <= 1)
            #expect(ReadingMeasure.prose(fontID: "system", size: 24) > measure * 1.6)
            #expect(ReadingMeasure.prose(fontID: "monospaced", size: 14) != measure)
            let column = ReadingMeasure.column(fontID: "system", size: 14, presentation: false)
            #expect(column >= Caprine.Code.maxWidth + Caprine.Activity.assistantGutter)
        }

        @Test @MainActor func userBubblesTakeAtMostThreeQuartersOfTheColumn() async throws {
            final class Box { var frame = CGRect.zero }
            let box = Box()
            let host = NSHostingView(
                rootView: FractionalWidthLayout(fraction: Caprine.Reading.userBubbleFraction) {
                    Color.clear.frame(maxWidth: .infinity, minHeight: 10, maxHeight: 10)
                        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { box.frame = $0 }
                }
                .frame(width: 800))
            host.frame = NSRect(x: 0, y: 0, width: 800, height: 40)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            #expect(box.frame.width == 600, "A bubble may fill three quarters of 800 pt: \(box.frame)")
            #expect(box.frame.maxX == 800, "Bubbles sit at the trailing edge: \(box.frame)")
        }

        /// In a wide window a long paragraph wraps at the measure, not the window.
        @Test @MainActor func proseWrapsAtTheMeasureInAWideWindow() async throws {
            let message = ChatMessage(role: .assistant)
            message.text = String(repeating: "Words of a long paragraph that should wrap at the measure. ", count: 30)
            message.complete = true
            let width: CGFloat = 1_600
            let host = NSHostingView(
                rootView: MessageView(message: message, isLast: false, projectID: nil)
                    .frame(width: width).background(Color.white).environment(AppModel.shared)
                    .environment(\.colorScheme, .light))
            host.appearance = NSAppearance(named: .aqua)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 600), styleMask: [.titled], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer {
                window.contentView = nil
                window.close()
            }
            try await Task.sleep(for: .milliseconds(500))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
            var rightmost = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                for x in stride(from: bitmap.pixelsWide - 1, to: rightmost, by: -2) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.redComponent < 0.5 {
                        rightmost = x
                        break
                    }
                }
            }
            let model = AppModel.shared
            let measure = ReadingMeasure.prose(fontID: model.effectiveChatFontID, size: model.chatFontSize)
            let limit = Caprine.Activity.presentationAvatarWidth + Caprine.Activity.assistantGutter + measure + 4
            #expect(CGFloat(rightmost) / scale <= limit, "Prose ends at \(CGFloat(rightmost) / scale) pt")
            #expect(CGFloat(rightmost) / scale > measure * 0.8, "Prose fills the measure")
        }
    }
}
