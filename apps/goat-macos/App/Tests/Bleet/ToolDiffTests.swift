import Foundation
import Testing

@testable import GOAT

@Suite struct ToolDiffTests {
    @Test func testParsePenEditFile() {
        let json = """
            {
                "path": "Sources/App.swift",
                "old_text": "func run() {\\n    print(\\"old\\")\\n}",
                "new_text": "func run() {\\n    print(\\"new\\")\\n    log()\\n}"
            }
            """

        let diff = ToolDiffParser.parse(tool: "pen_edit_file", arguments: json)
        #expect(diff != nil)
        guard let diff else { return }

        #expect(diff.path == "Sources/App.swift")
        #expect(diff.kind == .edit)
        #expect(diff.deletionsCount == 1)
        #expect(diff.additionsCount == 2)

        let deletions = diff.lines.filter { $0.kind == .deletion }
        #expect(deletions.count == 1)
        #expect(deletions.first?.text == "    print(\"old\")")
        #expect(deletions.first?.oldLineNumber == 2)
        #expect(deletions.first?.newLineNumber == nil)

        let additions = diff.lines.filter { $0.kind == .addition }
        #expect(additions.count == 2)
        #expect(additions[0].text == "    print(\"new\")")
        #expect(additions[1].text == "    log()")

        let contexts = diff.lines.filter { $0.kind == .context }
        #expect(contexts.count == 2)
        #expect(contexts[0].text == "func run() {")
        #expect(contexts[1].text == "}")
    }

    @Test func testParsePenWriteFile() {
        let json = """
            {
                "path": "README.md",
                "content": "# Project\\nWelcome to GOAT.\\n"
            }
            """

        let diff = ToolDiffParser.parse(tool: "pen_write_file", arguments: json)
        #expect(diff != nil)
        guard let diff else { return }

        #expect(diff.path == "README.md")
        #expect(diff.kind == .create)
        #expect(diff.deletionsCount == 0)
        #expect(diff.additionsCount == 3)
        #expect(diff.lines.allSatisfy { $0.kind == .addition })
        #expect(diff.lines[0].text == "# Project")
        #expect(diff.lines[0].newLineNumber == 1)
        #expect(diff.lines[1].text == "Welcome to GOAT.")
        #expect(diff.lines[1].newLineNumber == 2)
    }

    @Test func testNonFileToolsReturnNil() {
        let json = #"{"path":"test.txt"}"#
        #expect(ToolDiffParser.parse(tool: "pen_read_file", arguments: json) == nil)
        #expect(ToolDiffParser.parse(tool: "pen_run_command", arguments: #"{"command":"ls"}"#) == nil)
        #expect(ToolDiffParser.parse(tool: "pen_list_files", arguments: json) == nil)
    }

    @Test func testMalformedArgumentsReturnNil() {
        #expect(ToolDiffParser.parse(tool: "pen_edit_file", arguments: "not a json") == nil)
        #expect(ToolDiffParser.parse(tool: "pen_edit_file", arguments: "{}") == nil)
        #expect(ToolDiffParser.parse(tool: "pen_write_file", arguments: #"{"path":"a"}"#) == nil)
    }
}
