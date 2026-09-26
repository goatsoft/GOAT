import Bleet
import MarkdownUI
import Testing

@testable import GOAT

extension AppTests.Bleet {
    @Suite struct TranscriptTextPartsTests {

        @Test func transcriptPartsPreserveEveryScalarAndBoundPathologicalGraphemes() throws {
            let fixtures = [
                "", "\r\n\n  ```swift\nlet goat = \"🐐\"\n```  \n",
                String(repeating: "👩🏽‍💻 café\r\n", count: 3_000),
                "a" + String(repeating: "\u{0301}", count: 30_000),
            ]
            for source in fixtures {
                let parts = try TranscriptTextParts.split(source)
                #expect(parts.allSatisfy { $0.utf8.count <= TranscriptTextParts.maximumBytes })
                #expect(parts.joined().unicodeScalars.elementsEqual(source.unicodeScalars))
            }
        }

        @Test func appendingTextPreservesCompletedPartsForReaders() throws {
            let source = String(repeating: "let goat = \"🐐\"\n", count: 2_000)
            let before = try TranscriptTextParts.split(source)
            let after = try TranscriptTextParts.split(source + String(repeating: "more\n", count: 2_000))
            #expect(Array(before.dropLast()) == Array(after.prefix(before.count - 1)))
        }
    }
}

extension AppTests.Bleet {
    /// Segments rendered by MarkdownUI (the transcript's renderer) mean what the whole reply means
    /// (#60 A1, ADR-0091). Whole-block segments produce exactly the whole reply's HTML; pieces of
    /// oversized blocks keep every code line, table row and word.
    @Suite struct MarkdownSegmentRenderingTests {
        private static let fence = "```"

        private static func html(_ markdown: String) -> String {
            MarkdownContent(GOATMarkdownSyntax.normalized(markdown)).renderHTML()
        }

        private static func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }

        private static func code(_ lines: Int) -> String {
            (0..<lines).map { "let value\($0) = \"<\($0)>\" && true" }.joined(separator: "\n") + "\n"
        }

        private static let wholeBlockReplies: [String] = [
            [
                "# Report", "Intro with *emphasis*, `code` and a [reference][guide].",
                "- loose first\n\n  continued in the first item\n\n- loose second\n\n- loose third",
                "1. ordered\n\n2. ordered again", "* tight\n* list",
                "- item with code\n\n  \(fence)swift\n  let a = 1\n\n  let b = 2\n  \(fence)",
                "\(fence)swift\nlet x = 1\n\nlet y = 2\n\(fence)", "| Name | Value |\n| --- | ---: |\n| a | 1 |",
                "> quoted line\n>\n> quoted again\n\n> second quote", "<!-- note\n\nstill a comment\n-->",
                "$$\nx = 1\n\ny = 2\n$$", "---", "Closing paragraph\nwith a soft break.",
                "[guide]: https://example.com/guide",
            ].joined(separator: "\n\n") + "\n",
            "Text\n[a]: https://a.example\n\n- a\n\n- b\n\nAfter [a].\n",
            "> [!NOTE]\n> An alert.\n\nPlain.\n\n~~~\ninner ``` fence\n~~~\n",
        ]

        @Test func wholeBlockSegmentsRenderExactlyTheWholeReply() {
            for reply in Self.wholeBlockReplies {
                let segmentation = MarkdownSegmenter.segment(
                    reply, isComplete: true, targetBytes: 1, maximumBytes: 4_096)
                #expect(segmentation.count > 2)
                #expect(segmentation.allSatisfy { $0.kind == .blocks })
                #expect(segmentation.map { Self.html($0.text) }.joined() == Self.html(reply), "\(reply.prefix(40))")
            }
        }

        @Test func oversizedFencePiecesKeepEveryCodeLine() {
            let body = Self.code(300)
            for (reply, info) in [
                ("\(Self.fence)swift\n\(body)\(Self.fence)\n", "swift"),
                (
                    "- item\n\n  \(Self.fence)swift\n"
                        + body.split(separator: "\n").map { "  " + $0 }.joined(separator: "\n")
                        + "\n  \(Self.fence)\n", "swift"
                ),
                ("\(Self.fence)swift \(String(repeating: "i", count: 600))\n\(body)\(Self.fence)\n", "swift"),
            ] {
                let segmentation = MarkdownSegmenter.segment(
                    reply, isComplete: true, targetBytes: 256, maximumBytes: 1_024)
                let pieces = segmentation.filter { $0.kind == .fencedCodePiece }
                #expect(pieces.count > 5)
                let open = "<pre><code class=\"language-\(info)\">"
                var recovered = ""
                for piece in pieces {
                    let rendered = Self.html(piece.text)
                    #expect(rendered.hasPrefix(open) && rendered.hasSuffix("</code></pre>\n"), "\(rendered.prefix(80))")
                    #expect(rendered.components(separatedBy: "<pre>").count == 2, "One code block per piece")
                    recovered += rendered.dropFirst(open.count).dropLast("</code></pre>\n".count)
                }
                #expect(recovered == Self.escaped(body))
            }
        }

        @Test func oversizedTablePiecesKeepEveryRowUnderTheHeader() {
            let rows = (0..<200).map { "| row \($0) | \(String(repeating: "v", count: 20)) |" }
            let reply = "| Name | Value |\n| --- | --- |\n" + rows.joined(separator: "\n") + "\n"
            let segmentation = MarkdownSegmenter.segment(reply, isComplete: true, targetBytes: 256, maximumBytes: 1_024)
            #expect(segmentation.count > 5)
            var bodyRows = 0
            for piece in segmentation {
                #expect(piece.kind == .tablePiece)
                let rendered = Self.html(piece.text)
                #expect(rendered.components(separatedBy: "<table>").count == 2)
                let head = rendered.components(separatedBy: "</thead>").first ?? ""
                #expect(head.contains("<thead>") && head.contains("Name") && head.contains("Value"))
                bodyRows += rendered.components(separatedBy: "<tr>").count - 2
            }
            #expect(bodyRows == rows.count)
        }

        @Test func oversizedParagraphPiecesKeepEveryWord() {
            let words = (0..<2_000).map { "word\($0)" }
            let reply = words.joined(separator: " ") + "\n"
            let segmentation = MarkdownSegmenter.segment(reply, isComplete: true, targetBytes: 256, maximumBytes: 1_024)
            #expect(segmentation.count > 5)
            var recovered: [Substring] = []
            for piece in segmentation {
                #expect(piece.kind == .blockPiece)
                let rendered = Self.html(piece.text)
                #expect(rendered.hasPrefix("<p>") && rendered.hasSuffix("</p>\n"))
                recovered += rendered.dropFirst(3).dropLast(5).split(separator: " ")
            }
            #expect(recovered.map(String.init) == words)
        }
    }
}
