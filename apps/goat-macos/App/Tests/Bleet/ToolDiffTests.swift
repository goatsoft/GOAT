import Bleet
import Foundation
import Inference
import Persistence
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
        @Test func testPresentationOrder() {
            let json = """
                {
                    "zebra": "z",
                    "content": "bulky content",
                    "path": "Sources/App.swift",
                    "alpha": "a",
                    "command": "swift build",
                    "stdout": "output",
                    "beta": "b"
                }
                """
            guard let value = JSONValue.parse(json), case .object(let dict) = value else {
                Issue.record("Failed to parse JSON")
                return
            }
            let sortedPairs = JSONPresentationOrder.sortedPairs(from: dict)
            let keys = sortedPairs.map(\.key)

            // Identity keys first: ["path", "command"] (in defined rank order)
            // Alphabetical keys middle: ["alpha", "beta", "zebra"]
            // Bulky keys last: ["content", "stdout"] (in defined rank order)
            #expect(keys == ["path", "command", "alpha", "beta", "zebra", "content", "stdout"])
        }

        @Test func testFormatNumberBoundaries() {
            #expect(formatNumber(12.5) == "12.5")
            #expect(formatNumber(12.0) == "12")
            #expect(formatNumber(Double.nan) == "nan")
            #expect(formatNumber(1e19) == "1e+19")
            #expect(formatNumber(9223372036854775808.0) == "9.223372036854776e+18")
            #expect(formatNumber(-9223372036854775809.0) == "-9223372036854775808")

            let u64Json = """
                { "u64_max": 9223372036854775808 }
                """
            guard let val = JSONValue.parse(u64Json), case .object(let dict) = val, let item = dict["u64_max"] else {
                Issue.record("Failed to parse u64 JSON")
                return
            }
            if case .number(let d) = item {
                #expect(formatNumber(d) == "9.223372036854776e+18")
            } else {
                Issue.record("Expected u64 past Int64.max to be parsed as .number")
            }
        }

        @Test func testInt64MaxHandlingInJSONValue() {
            let json = """
                {
                    "max": 9223372036854775807,
                    "min": -9223372036854775808,
                    "regular": 42
                }
                """
            guard let value = JSONValue.parse(json), case .object(let dict) = value else {
                Issue.record("Failed to parse JSON with Int64 values")
                return
            }
            #expect(dict["max"] == .integer(Int64.max))
            #expect(dict["min"] == .integer(Int64.min))
            #expect(dict["regular"] == .integer(42))
        }

        @Test func testToolCallPayloadContainsValue() {
            #expect(!ToolCallPayload.containsValue(nil))
            #expect(!ToolCallPayload.containsValue(""))
            #expect(!ToolCallPayload.containsValue("   \n\t  "))
            #expect(!ToolCallPayload.containsValue("null"))
            #expect(!ToolCallPayload.containsValue("{}"))
            #expect(!ToolCallPayload.containsValue("{   }"))
            #expect(!ToolCallPayload.containsValue("[]"))
            #expect(!ToolCallPayload.containsValue("[   ]"))

            #expect(ToolCallPayload.containsValue("{\"key\": \"value\"}"))
            #expect(ToolCallPayload.containsValue("[1, 2, 3]"))
            #expect(ToolCallPayload.containsValue("non-json plain text"))
        }

        @Test func testPresentationTitlesAndRootNaming() {
            let globWithPattern = ToolEventSnapshot(
                id: "1", server: "Pens", tool: "pen_glob",
                arguments: #"{"pattern": "**/*.swift"}"#,
                result: nil, isError: false, denied: false
            )
            let pres1 = ToolActivityLabel.presentation(for: globWithPattern, rootName: "App")
            #expect(pres1.title == "Find files · **/*.swift")

            let globWithPathFallback = ToolEventSnapshot(
                id: "2", server: "Pens", tool: "pen_glob",
                arguments: #"{"path": "Sources"}"#,
                result: nil, isError: false, denied: false
            )
            let pres2 = ToolActivityLabel.presentation(for: globWithPathFallback, rootName: "App")
            #expect(pres2.title == "Find files · Sources")

            let listWithDot = ToolEventSnapshot(
                id: "3", server: "Pens", tool: "pen_list_files",
                arguments: #"{"path": "."}"#,
                result: nil, isError: false, denied: false
            )
            let pres3 = ToolActivityLabel.presentation(for: listWithDot, rootName: "MyProject")
            #expect(pres3.title == "List files · MyProject")

            let listWithEmptyRoot = ToolEventSnapshot(
                id: "4", server: "Pens", tool: "pen_list_files",
                arguments: #"{"path": "."}"#,
                result: nil, isError: false, denied: false
            )
            let pres4 = ToolActivityLabel.presentation(for: listWithEmptyRoot, rootName: nil)
            #expect(pres4.title == "List files · workspace")
        }
    }
}
