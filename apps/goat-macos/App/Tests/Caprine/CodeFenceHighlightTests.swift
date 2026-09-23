import AppKit
import HighlightKit
import SwiftUI
import Testing

@testable import GOAT
@testable import Paddock

extension AppTests.Caprine {
    @Suite struct CodeFenceHighlightTests {

        @Test(arguments: [false, true])
        func sharedCodeHighlightingPreservesWhitespaceAndColoursAcrossRepeatedRequests(dark: Bool) async throws {
            let renderer = CodeSyntaxHighlighter()
            let source = "\n  let goat = \"🐐\"\n\n"
            for _ in 0..<3 {
                let output = try await renderer.render(source, language: "swift", dark: dark)
                #expect(String(output.characters) == source)
                let keyword = try #require(output.range(of: "let"))
                #expect(output[keyword].runs.contains { $0.appKit.foregroundColor != nil })
            }
            let huge = String(repeating: "x", count: HighlightedCodeView.maximumHighlightedBytes + 1)
            let plain = try await renderer.render(huge, language: "swift", dark: dark)
            #expect(String(plain.characters) == huge)
            #expect(plain.runs.allSatisfy { $0.appKit.foregroundColor == nil })
        }

        @Test func vueSectionsRespectScriptLanguagesCommentsAndIncompleteStreams() {
            let source = """
                <!-- <script lang="ts">ignore this</script> -->
                <template><p>{{ name }}</p></template>
                <script setup lang="ts">
                const name: string = "GOAT";
                </script>
                <style scoped lang='scss'>
                p { color: red; }
                </style>
                <script lang=tsx>const view = <p>GOAT</p>;
                """
            let sections = VueSyntaxHighlighter.sections(in: source)
            #expect(sections.map(\.text).joined() == source)
            #expect(sections.map(\.language) == ["xml", "typescript", "xml", "scss", "xml", "typescript"])
            #expect(sections.first?.text.contains("ignore this") == true)
            #expect(sections.last?.text == "const view = <p>GOAT</p>;")
        }

        @Test(arguments: [false, true])
        func vueHighlightingPreservesExactSourceAndColoursEachSection(dark: Bool) async throws {
            let source = """

                <template><p title="goat > sheep">🐐 &amp; {{ name }}</p></template>
                <script setup lang="ts">
                  const name: string = "GOAT";
                </script>
                <style scoped>
                  p { color: red; }
                </style>

                """
            let output = try await VueSyntaxHighlighter.shared.render(source, dark: dark)
            #expect(String(output.characters) == source)
            let xmlTag = try #require(output.range(of: "<template>"))
            #expect(output[xmlTag].runs.contains { $0.appKit.foregroundColor != nil })
            let tsKeyword = try #require(output.range(of: "const"))
            #expect(output[tsKeyword].runs.contains { $0.appKit.foregroundColor != nil })
            let cssProp = try #require(output.range(of: "color"))
            #expect(output[cssProp].runs.contains { $0.appKit.foregroundColor != nil })
        }

        @Test func vueUnknownLanguagesAndOversizeSourceStayIntact() async throws {
            let unknown = "<script lang=\"madeup\">const z = 1;</script>"
            let renderedUnknown = try await VueSyntaxHighlighter.shared.render(unknown, dark: false)
            #expect(String(renderedUnknown.characters) == unknown)

            let oversized = "<template>" + String(repeating: " ", count: VueSyntaxHighlighter.maximumBytes + 1)
            let renderedOversized = try await VueSyntaxHighlighter.shared.render(oversized, dark: false)
            #expect(String(renderedOversized.characters) == oversized)
        }

        @Test func tsxHighlightsTypesAndJSXTags() async throws {
            let source = "type Goat = { id: string }; const view = <Badge>{id}</Badge>;"
            let output = try await CodeSyntaxHighlighter.shared.render(source, language: "tsx", dark: false)
            #expect(String(output.characters) == source)
            let keyword = try #require(output.range(of: "type"))
            #expect(output[keyword].runs.contains { $0.appKit.foregroundColor != nil })
            let tag = try #require(output.range(of: "Badge"))
            #expect(output[tag].runs.contains { $0.appKit.foregroundColor != nil })
        }

        @Test func vueExternalScriptDoesNotConsumeFollowingStyles() {
            let source = "<script src=\"./logic.ts\" lang=\"ts\" />\n<style>p { color: red; }</style>"
            let sections = VueSyntaxHighlighter.sections(in: source)
            #expect(sections.map(\.text).joined() == source)
            #expect(sections.map(\.language) == ["xml", "css", "xml"])
        }

        @Test func streamingPartialCodeHighlightsProgressively() async throws {
            let renderer = CodeSyntaxHighlighter()
            let partial = "func processStream() {\n    let partialToken = 42\n"
            let output = try await renderer.render(partial, language: "swift", dark: false)
            #expect(String(output.characters) == partial)
            let funcRange = try #require(output.range(of: "func"))
            #expect(output[funcRange].runs.contains { $0.appKit.foregroundColor != nil })
            let letRange = try #require(output.range(of: "let"))
            #expect(output[letRange].runs.contains { $0.appKit.foregroundColor != nil })

            let extended = partial + "    return true\n}"
            let extendedOutput = try await renderer.render(extended, language: "swift", dark: false)
            #expect(String(extendedOutput.characters) == extended)
            let returnRange = try #require(extendedOutput.range(of: "return"))
            #expect(extendedOutput[returnRange].runs.contains { $0.appKit.foregroundColor != nil })
        }

        @Test func fallbackResolvesToSourceOnCodeReplacementAndTruncation() {
            let initialCode = "let alpha = 1\nlet beta = 2"
            let initialRendered = AttributedString("rendered alpha and beta")
            let initialKey = PreparedCodeText.CacheKey(code: initialCode, language: "swift", dark: false)

            // Exact match returns cached rendered
            let exact = PreparedCodeText.resolveText(
                code: initialCode,
                language: "swift",
                dark: false,
                rendered: initialRendered,
                renderedKey: initialKey
            )
            #expect(exact == initialRendered)

            // Streaming prefix extension appends suffix
            let extendedCode = initialCode + "\nlet gamma = 3"
            let extended = PreparedCodeText.resolveText(
                code: extendedCode,
                language: "swift",
                dark: false,
                rendered: initialRendered,
                renderedKey: initialKey
            )
            #expect(String(extended.characters) == "rendered alpha and beta\nlet gamma = 3")

            // Truncation immediately resolves to the new source code, not stale rendered text
            let truncatedCode = "let alpha = 1"
            let truncated = PreparedCodeText.resolveText(
                code: truncatedCode,
                language: "swift",
                dark: false,
                rendered: initialRendered,
                renderedKey: initialKey
            )
            #expect(String(truncated.characters) == truncatedCode)

            // Complete replacement immediately resolves to new source code, not stale rendered text
            let replacedCode = "func other() { return }"
            let replaced = PreparedCodeText.resolveText(
                code: replacedCode,
                language: "swift",
                dark: false,
                rendered: initialRendered,
                renderedKey: initialKey
            )
            #expect(String(replaced.characters) == replacedCode)
        }

        @Test @MainActor func highlightedCodeViewHidesScrollIndicatorsByDefault() {
            let view = HighlightedCodeView(code: "let x = 1").environment(AppModel.shared)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
            host.layoutSubtreeIfNeeded()
            func findScrollView(_ view: NSView) -> NSScrollView? {
                if let sv = view as? NSScrollView { return sv }
                return view.subviews.lazy.compactMap(findScrollView).first
            }
            if let sv = findScrollView(host) {
                #expect(sv.hasHorizontalScroller == false || sv.horizontalScroller?.isHidden == true)
            }
        }

        @Test @MainActor func highlightedCodeViewSupportsWordWrapToggle() {
            let wrapped = HighlightedCodeView(code: "let x = 1", wordWrap: true).environment(AppModel.shared)
            let hostWrapped = NSHostingView(rootView: wrapped)
            hostWrapped.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
            hostWrapped.layoutSubtreeIfNeeded()

            func findScrollView(_ view: NSView) -> NSScrollView? {
                if let sv = view as? NSScrollView { return sv }
                return view.subviews.lazy.compactMap(findScrollView).first
            }
            #expect(findScrollView(hostWrapped) == nil)

            let unwrapped = HighlightedCodeView(code: "let x = 1", wordWrap: false).environment(AppModel.shared)
            let hostUnwrapped = NSHostingView(rootView: unwrapped)
            hostUnwrapped.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
            hostUnwrapped.layoutSubtreeIfNeeded()
            #expect(findScrollView(hostUnwrapped) != nil)
        }

        @Test @MainActor func highlightedCodeViewSuppressesGutterWhenWrappedAtNarrowWidth() {
            let longLine = "let extremelyLongLineThatWrapsManyTimes = Array(repeating: \"goat\", count: 80).joined()"
            let longCode = "\(longLine)\nlet shortLine = 1\nlet secondShortLine = 2"
            let view = HighlightedCodeView(
                code: longCode,
                showLineNumbers: true,
                wordWrap: true
            ).environment(AppModel.shared)

            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 180, height: 300)
            host.layoutSubtreeIfNeeded()

            // When wrapped, horizontal scroll view is absent
            func findScrollView(_ view: NSView) -> NSScrollView? {
                if let sv = view as? NSScrollView { return sv }
                return view.subviews.lazy.compactMap(findScrollView).first
            }
            #expect(findScrollView(host) == nil)
        }
    }
}
