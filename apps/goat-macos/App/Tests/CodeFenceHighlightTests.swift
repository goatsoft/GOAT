import AppKit
import HighlightSwift
import Testing

@testable import GOAT
@testable import Paddock

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
    let output = try await Highlight().attributedText(source, language: "tsx")
    #expect(String(output.characters) == source)
    for token in ["const", "string", "section"] {
        let range = try #require(output.range(of: token))
        #expect(output[range].runs.contains { $0.appKit.foregroundColor != nil })
    }
}

@Test(arguments: [("vue", "vue"), ("tsx", "tsx"), ("jsx", "jsx"), (" TS ", "ts"), ("TypeScript", "ts")])
func codeFenceExportsKeepTheirSourceExtension(language: String, fileExtension: String) {
    let artifact = PaddockArtifact(kind: .code(language: language), content: "source")
    #expect(artifact.suggestedFilename == "goat-artifact.\(fileExtension)")
}

@Test func vueExternalScriptDoesNotConsumeFollowingStyles() {
    let source = "<script src=\"./logic.ts\" lang=\"ts\" />\n<style>p { color: red; }</style>"
    let sections = VueSyntaxHighlighter.sections(in: source)
    #expect(sections.map(\.text).joined() == source)
    #expect(sections.map(\.language) == ["xml", "css", "xml"])
}
