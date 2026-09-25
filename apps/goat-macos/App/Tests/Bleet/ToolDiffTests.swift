import Foundation
import Testing

@testable import GOAT

extension AppTests.Bleet {
    @MainActor @Suite struct ToolDiffTests {
        @Test func testParsePenEditFile() {
            let json = """
                {
                    "path": "Sources/App.swift",
                    "old_text": "func run() {\\n    print(\\\"old\\\")\\n}",
                    "new_text": "func run() {\\n    print(\\\"new\\\")\\n    log()\\n}"
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
            #expect(!diff.isTruncated)
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
            #expect(!diff.isTruncated)
        }

        @Test func testDiffBoundingAndTruncationOnLargeFileCreation() throws {
            let lines = (1...650).map { "Line \($0)" }.joined(separator: "\n")
            let payload: [String: Any] = [
                "path": "bigfile.txt",
                "content": lines,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let json = String(decoding: data, as: UTF8.self)

            let diff = ToolDiffParser.parse(tool: "pen_write_file", arguments: json)
            #expect(diff != nil)
            guard let diff else { return }

            #expect(diff.lines.count == ToolDiffParser.maxDiffLines)
            #expect(diff.isTruncated == true)
            #expect(diff.totalLinesCount == 650)
            #expect(diff.additionsCount == 650)
        }

        @Test func testDiffBoundingAndTruncationOnLargeFileEdit() throws {
            let oldLines = (1...600).map { "Old \($0)" }.joined(separator: "\n")
            let newLines = (1...600).map { "New \($0)" }.joined(separator: "\n")
            let payload: [String: Any] = [
                "path": "bigedit.txt",
                "old_text": oldLines,
                "new_text": newLines,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let json = String(decoding: data, as: UTF8.self)

            let diff = ToolDiffParser.parse(tool: "pen_edit_file", arguments: json)
            #expect(diff != nil)
            guard let diff else { return }

            #expect(diff.lines.count == ToolDiffParser.maxDiffLines)
            #expect(diff.isTruncated == true)
            #expect(diff.totalLinesCount == 1200)
        }

        @Test func testToolDiffParserCaching() {
            let json = """
                {
                    "path": "cached.txt",
                    "content": "Line 1\\nLine 2"
                }
                """

            let diff1 = ToolDiffParser.parse(tool: "pen_write_file", arguments: json)
            let diff2 = ToolDiffParser.parse(tool: "pen_write_file", arguments: json)
            #expect(diff1 != nil)
            #expect(diff1 == diff2)
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

    @MainActor @Suite struct JSONTreeViewTests {
        @Test func testOrderedKeyPreservation() {
            let json = """
            {
                "path": "Sources/App.swift",
                "old_text": "let x = 1",
                "new_text": "let x = 2",
                "context": "test"
            }
            """
            guard let node = JSONNode.parse(json) else {
                Issue.record("Failed to parse JSON")
                return
            }
            if case .object(let pairs) = node {
                let keys = pairs.map(\.key)
                #expect(keys == ["path", "old_text", "new_text", "context"])
            } else {
                Issue.record("Node is not an object")
            }
        }

        @Test func testLargeNumberFormattingDoesNotTrap() {
            let huge = Double(1e25)
            let formattedHuge = JSONNode.formatNumber(huge)
            #expect(!formattedHuge.isEmpty)

            let maxInt64 = Double(Int64.max)
            let formattedMaxInt = JSONNode.formatNumber(maxInt64)
            #expect(formattedMaxInt == "9223372036854775807")

            let minInt64 = Double(Int64.min)
            let formattedMinInt = JSONNode.formatNumber(minInt64)
            #expect(formattedMinInt == "-9223372036854775808")

            let nan = Double.nan
            #expect(JSONNode.formatNumber(nan) == "NaN")

            let posInf = Double.infinity
            #expect(JSONNode.formatNumber(posInf) == "Infinity")

            let negInf = -Double.infinity
            #expect(JSONNode.formatNumber(negInf) == "-Infinity")
        }

        @Test func testParseLargeNumberPayload() {
            let json = """
            {
                "id": 9223372036854775807,
                "big": 1e20,
                "decimal": 42.5,
                "zero": 0
            }
            """
            guard let node = JSONNode.parse(json) else {
                Issue.record("Failed to parse large numbers JSON")
                return
            }
            if case .object(let pairs) = node {
                #expect(pairs.count == 4)
                #expect(pairs[0].key == "id")
                #expect(pairs[1].key == "big")
                #expect(pairs[2].key == "decimal")
                #expect(pairs[3].key == "zero")
            } else {
                Issue.record("Node is not an object")
            }
        }

        @Test func testEscapedStringsInOrderedParser() {
            let json = """
            {
                "string": "Line 1\\nLine 2\\tTabbed \\\"quoted\\\" \\\\backslash",
                "unicode": "\\u0041\\u0042\\u0043"
            }
            """
            guard let node = JSONNode.parse(json) else {
                Issue.record("Failed to parse escaped strings")
                return
            }
            if case .object(let pairs) = node {
                #expect(pairs.count == 2)
                #expect(pairs[0].value.stringValue == "Line 1\nLine 2\tTabbed \"quoted\" \\backslash")
                #expect(pairs[1].value.stringValue == "ABC")
            } else {
                Issue.record("Node is not an object")
            }
        }
    }
}
