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
            for token in ["template", "const", "string", "color"] {
                let range = try #require(output.range(of: token))
                #expect(output[range].runs.contains { $0.appKit.foregroundColor != nil })
            }
        }

        @Test func vueUnknownLanguagesAndOversizeSourceStayIntact() async throws {
            let source = "<script lang='unknown'>\n  custom syntax  \n</script>\n"
            #expect(VueSyntaxHighlighter.sections(in: source).contains { $0.language == "plaintext" })
            let output = try await VueSyntaxHighlighter.shared.render(source, dark: false)
            #expect(String(output.characters) == source)
            let huge = String(repeating: "x", count: VueSyntaxHighlighter.maximumBytes + 1)
            let plain = try await VueSyntaxHighlighter.shared.render(huge, dark: true)
            #expect(String(plain.characters) == huge)
            #expect(plain.runs.allSatisfy { $0.appKit.foregroundColor == nil })
        }

        @Test func tsxHighlightsTypesAndJSXTags() async throws {
            let source = "const Card = (props: { title: string }) => <section>{props.title}</section>;"
            let renderer = CodeSyntaxHighlighter()
            let output = try await renderer.render(source, language: "tsx", dark: false)
            #expect(String(output.characters) == source)
            for token in ["const", "string", "section"] {
                let range = try #require(output.range(of: token))
                #expect(output[range].runs.contains { $0.appKit.foregroundColor != nil })
            }
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
    }
}
