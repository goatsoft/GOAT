import Foundation
import Testing

@testable import GOAT
@testable import Memory

@Test func llmWikiGraphBuildsDirectProvenanceHubAndOrphanSignals() throws {
    let hub = page(id: "wiki:global:hub", title: "Hub", content: "[[alpha]] [[beta]]")
    let alpha = page(
        id: "wiki:global:alpha", title: "Alpha",
        content: "[[beta]] [[source-interview]] [[missing-page]]")
    let beta = page(id: "wiki:global:beta", title: "Beta", content: "[[hub]]")
    let lonely = page(id: "wiki:global:lonely", title: "Lonely", content: "No links.")
    let rawSource = source(id: "raw:source-interview", title: "Dog interview")
    let unused = source(id: "raw:source-unused", title: "Uncited")
    let material = LLMWikiGraphMaterial(
        pages: [hub, alpha, beta, lonely], sources: [rawSource, unused])

    let graph = MemoryGraphBuilder.build(from: material)
    let repeatGraph = MemoryGraphBuilder.build(from: material)

    #expect(graph == repeatGraph)
    #expect(graph.pages.count == 4)
    #expect(graph.sources.map(\.title) == ["Dog interview"])
    #expect(graph.edges.filter(\.directLink).count == 4)
    #expect(graph.edges.filter { !$0.directLink }.count == 1)

    let hubNode = try #require(graph.nodes.first { $0.id == hub.entry.id })
    #expect(hubNode.isHub)
    #expect(!hubNode.isOrphan)

    let alphaNode = try #require(graph.nodes.first { $0.id == alpha.entry.id })
    #expect(alphaNode.sourceCitationCount == 1)
    #expect(!alphaNode.isDisconnected)

    let lonelyNode = try #require(graph.nodes.first { $0.id == lonely.entry.id })
    #expect(lonelyNode.isOrphan)
    #expect(lonelyNode.isDisconnected)
    #expect(abs(lonelyNode.position.x) <= 1)
    #expect(abs(lonelyNode.position.y) <= 1)
}

@Test func memoryDocumentLinksStayInThePreviewAndResolveRelativeMarkdownTargets() throws {
    let pageID = MemoryEntryID(rawValue: "wiki:global:qwen-retrieval")
    let sourceID = MemoryEntryID(rawValue: "raw:source-interview")
    let targets = ["qwen-retrieval": pageID, "source-interview": sourceID]

    let rendered = MemoryDocumentLinks.renderedMarkdown(
        "Read [[qwen-retrieval]] and [[missing]].", linkTargets: targets)
    #expect(rendered.contains("[qwen-retrieval](goat-memory://entry/wiki:global:qwen-retrieval)"))
    #expect(rendered.contains("[[missing]]"))

    let generated = try #require(URL(string: "goat-memory://entry/wiki:global:qwen-retrieval"))
    #expect(MemoryDocumentLinks.target(for: generated, in: targets) == pageID)
    let relative = try #require(URL(string: "source-interview.md"))
    #expect(MemoryDocumentLinks.target(for: relative, in: targets) == sourceID)
    let external = try #require(URL(string: "https://example.com/wiki"))
    #expect(MemoryDocumentLinks.target(for: external, in: targets) == nil)
}

@Test func memoryDocumentLinksDoNotRewriteCodeExamples() {
    let pageID = MemoryEntryID(rawValue: "wiki:global:qwen-retrieval")
    let content = """
        See [[qwen-retrieval]].

        `[[qwen-retrieval]]`

        ```swift
        let example = "[[qwen-retrieval]]"
        ```
        """

    let rendered = MemoryDocumentLinks.renderedMarkdown(content, linkTargets: ["qwen-retrieval": pageID])

    #expect(rendered.contains("See [qwen-retrieval](goat-memory://entry/wiki:global:qwen-retrieval)."))
    #expect(rendered.contains("`[[qwen-retrieval]]`"))
    #expect(rendered.contains("let example = \"[[qwen-retrieval]]\""))
}

@Test func memoryGraphCarriesBoundedMaterialDisclosure() {
    let graph = MemoryGraphBuilder.build(
        from: LLMWikiGraphMaterial(
            pages: [page(id: "wiki:global:one", title: "One", content: "")],
            sources: [],
            isTruncated: true))

    #expect(graph.isTruncated)
}

private func page(id: String, title: String, content: String) -> LLMWikiGraphPage {
    let entry = MemoryBrowserEntry(
        id: MemoryEntryID(rawValue: id), title: title, summary: "\(title) summary", scope: .global,
        canEdit: true, canDelete: true)
    let name = id.split(separator: ":").last.map(String.init)!
    return LLMWikiGraphPage(entry: entry, name: name, content: content)
}

private func source(id: String, title: String) -> LLMWikiGraphSource {
    let entry = MemoryBrowserEntry(
        id: MemoryEntryID(rawValue: id), title: title, summary: "\(title) summary", scope: .global,
        canEdit: false, canDelete: false)
    let name = id.split(separator: ":").last.map(String.init)!
    return LLMWikiGraphSource(entry: entry, name: name)
}
