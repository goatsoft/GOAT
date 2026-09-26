import AppKit
import Caprine
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

        // MARK: Theme palettes (#60 A5)

        private static func theme(_ id: String) throws -> ThemeSpec {
            try #require(ThemeCatalog.builtins.first { $0.id == id })
        }

        private static func foreground(of word: String, in text: AttributedString) throws -> UInt32? {
            let range = try #require(text.range(of: word))
            guard let color = text[range].runs.first?.appKit.foregroundColor?.usingColorSpace(.sRGB) else { return nil }
            func channel(_ value: CGFloat) -> UInt32 { UInt32((value * 255).rounded()) }
            return channel(color.redComponent) << 16 | channel(color.greenComponent) << 8 | channel(color.blueComponent)
        }

        /// Every built-in theme, in each appearance System resolves to, derives AA-readable syntax colours
        /// from its own tokens.
        @Test(arguments: ThemeCatalog.builtins.map(\.id), [false, true])
        func syntaxPaletteDerivesReadableColoursFromTheTheme(id: String, dark: Bool) throws {
            let theme = try Self.theme(id).resolved(dark: dark)
            let palette = SyntaxPalette(theme: theme)
            let background = try #require(SyntaxPalette.rgb(theme.bg))
            for colour in [palette.keyword, palette.string, palette.number, palette.comment, palette.type] {
                #expect(
                    SyntaxPalette.contrast(colour, background) >= SyntaxPalette.minimumContrast,
                    "\(id): \(String(colour, radix: 16)) on \(theme.bg)")
            }
            // A token already readable on the background is used as the theme defines it.
            let accent = try #require(SyntaxPalette.rgb(theme.accent))
            if SyntaxPalette.contrast(accent, background) >= SyntaxPalette.minimumContrast {
                #expect(palette.keyword == accent)
            }
        }

        /// Independent WCAG 2.1 reference values, so the shared utilities are never checked only against
        /// themselves: #767676 is the lightest grey that passes AA on white, #777777 just misses.
        @Test func contrastMatchesWCAGReferenceValuesAtTheAABoundary() {
            let passing = SyntaxPalette.contrast(0x767676, 0xFFFFFF)
            let failing = SyntaxPalette.contrast(0x777777, 0xFFFFFF)
            #expect(abs(passing - 4.542) < 0.01 && passing >= SyntaxPalette.minimumContrast)
            #expect(abs(failing - 4.478) < 0.01 && failing < SyntaxPalette.minimumContrast)
            #expect(abs(SyntaxPalette.contrast(0x000000, 0xFFFFFF) - 21) < 0.01)
            // A colour already at AA is kept; one just below it moves one step toward the ink.
            let white = SyntaxPalette.value(0xFFFFFF)
            #expect(SyntaxPalette.readable(0x767676, on: white, toward: 0x000000) == 0x767676)
            #expect(SyntaxPalette.readable(0x777777, on: white, toward: 0x000000) == 0x6B6B6B)
        }

        /// Moving toward the ink reaches AA only when the ink does: with a low-contrast custom ink, a
        /// colour that never reaches 4.5:1 ends at the ink, as readable as the theme's own text.
        @Test func lowContrastCustomInkEndsAtTheInk() {
            var theme = ThemeCatalog.light
            theme.bg = "#808080"
            theme.ink = "#909090"
            theme.accent = "#858585"
            #expect(SyntaxPalette.contrast(0x909090, 0x808080) < SyntaxPalette.minimumContrast)
            let palette = SyntaxPalette(theme: theme)
            #expect(palette.keyword == 0x909090)
        }

        /// System has placeholder colours: in light mode its palette is Light's, never one derived from its
        /// black placeholder background, and in dark mode Midnight's.
        @Test func systemUsesThePaletteOfTheThemeItResolvesTo() throws {
            let system = try Self.theme("system")
            #expect(SyntaxPalette(theme: system.resolved(dark: false)) == SyntaxPalette(theme: ThemeCatalog.light))
            #expect(SyntaxPalette(theme: system.resolved(dark: true)) == SyntaxPalette(theme: ThemeCatalog.midnight))
            let light = SyntaxPalette(theme: ThemeCatalog.light)
            let background = try #require(SyntaxPalette.rgb(ThemeCatalog.light.bg))
            #expect(SyntaxPalette.contrast(light.keyword, background) >= SyntaxPalette.minimumContrast)
        }

        /// Themes highlight the same code in their own colours.
        @Test func themesHighlightCodeInTheirOwnColours() async throws {
            let light = SyntaxPalette(theme: try Self.theme("light"))
            let pasture = SyntaxPalette(theme: try Self.theme("pasture"))
            #expect(light != pasture && light.key != pasture.key)
            let code = "let value = \"text\" // note"
            let renderer = CodeSyntaxHighlighter.shared
            let lightText = try await renderer.render(code, language: "swift", dark: false, palette: light)
            let pastureText = try await renderer.render(code, language: "swift", dark: false, palette: pasture)
            #expect(try Self.foreground(of: "let", in: lightText) == light.keyword)
            #expect(try Self.foreground(of: "let", in: pastureText) == pasture.keyword)
            #expect(try Self.foreground(of: "// note", in: pastureText) == pasture.comment)
            #expect(String(pastureText.characters) == code, "Highlighting never changes the code")
        }

        /// The cache keys on the palette; a theme change keeps the previous colours on the first frame
        /// until the new ones are ready, and an evicted entry falls back to source.
        @Test @MainActor func highlightCacheSeparatesPalettesAndReusesTheFirstFrame() throws {
            let light = SyntaxPalette(theme: try Self.theme("light"))
            let pasture = SyntaxPalette(theme: try Self.theme("pasture"))
            let code = "let palette = \"\(UUID().uuidString)\""
            let lightText = AttributedString("light rendering")
            HighlightCache.shared.set(
                code: code, language: "swift", dark: false, palette: light, text: lightText, lineCount: 1)
            let resident = HighlightCache.shared.peek(code: code, language: "swift", dark: false, palette: light)
            #expect(resident?.text == lightText)
            #expect(HighlightCache.shared.peek(code: code, language: "swift", dark: false, palette: pasture) == nil)
            #expect(HighlightCache.shared.peek(code: code, language: "swift", dark: false) == nil)

            // First frame under the cached palette.
            #expect(
                PreparedCodeText.displayText(
                    code: code, language: "swift", dark: false, palette: light, isStreaming: false, rendered: nil,
                    renderedKey: nil) == lightText)
            // A live theme change shows the previous colours, not plain source, until re-highlighted.
            let previous = PreparedCodeText.CacheKey(code: code, language: "swift", dark: false, palette: light)
            #expect(
                PreparedCodeText.displayText(
                    code: code, language: "swift", dark: false, palette: pasture, isStreaming: false,
                    rendered: lightText, renderedKey: previous) == lightText)
            // Evicted: nothing resident, so the consumer shows source and prepares again.
            HighlightCache.shared.removeAll()
            #expect(
                String(
                    PreparedCodeText.displayText(
                        code: code, language: "swift", dark: false, palette: pasture, isStreaming: false,
                        rendered: nil, renderedKey: nil
                    ).characters) == code)
        }

        /// A mounted code view re-highlights when the theme changes and caches under the new palette.
        @Test @MainActor func liveThemeChangesRehighlightMountedCode() async throws {
            let light = SyntaxPalette(theme: try Self.theme("light"))
            let pasture = SyntaxPalette(theme: try Self.theme("pasture"))
            let code = "let live = \"\(UUID().uuidString)\""
            let host = NSHostingView(
                rootView: AnyView(PreparedCodeText(code: code, language: "swift").environment(\.syntaxPalette, light)))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.titled], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer {
                window.contentView = nil
                window.close()
            }
            for palette in [light, pasture] {
                host.rootView = AnyView(
                    PreparedCodeText(code: code, language: "swift").environment(\.syntaxPalette, palette))
                var cached: HighlightCache.Entry?
                for _ in 0..<50 where cached == nil {
                    try await Task.sleep(for: .milliseconds(20))
                    cached = HighlightCache.shared.peek(code: code, language: "swift", dark: false, palette: palette)
                }
                let entry = try #require(cached, "Prepared under palette \(palette.key)")
                #expect(try Self.foreground(of: "let", in: entry.text) == palette.keyword)
            }
        }
    }
}
