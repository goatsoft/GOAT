import Foundation
import Pens
import Testing

private func penFileArguments(_ args: [String: String]) throws -> String {
    String(decoding: try JSONEncoder().encode(args), as: UTF8.self)
}

private func penReadHeader(_ result: String) -> String {
    String(result[result.startIndex..<(result.firstIndex(of: "\n") ?? result.endIndex)])
}

private func penReadBody(_ result: String) -> String {
    guard let newline = result.firstIndex(of: "\n") else { return "" }
    return String(result[result.index(after: newline)...])
}

private func penNextStartLine(_ result: String) -> Int? {
    let header = penReadHeader(result)
    guard let range = header.range(of: "next_start_line ") else { return nil }
    return Int(header[range.upperBound...].prefix { $0.isNumber })
}

private func penSearchHeader(_ result: String) -> String {
    String(result.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
}

private func penSearchMatches(_ result: String) -> [String] {
    Array(result.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().map(String.init))
}

private func temporaryPen() throws -> URL {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("pen-files-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func penFilesCreateReadEditAndRepeatedListPreserveExactContent() async throws {
    let root = try temporaryPen()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try PenFileTools(workspace: root)
    let content = "<script setup lang=\"ts\">\nconst taco = '🌮';\n</script>\n"
    let prepared = try await files.prepare(
        tool: "pen_write_file",
        argumentsJSON: penFileArguments([
            "path": "src/App.vue", "content": content,
        ]))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("src").path))
    #expect(prepared.previewJSON.contains(root.path))
    _ = try await files.commit(prepared)
    #expect(try String(contentsOf: root.appendingPathComponent("src/App.vue"), encoding: .utf8) == content)
    for _ in 0..<3 {
        let listed = try await files.read(tool: "pen_list_files", argumentsJSON: #"{"path":"."}"#)
        #expect(listed.content.contains("src/"))
    }
    let read = try await files.read(tool: "pen_read_file", argumentsJSON: #"{"path":"src/App.vue"}"#)
    #expect(read.content.hasPrefix("src/App.vue, lines 1-"))
    #expect(penReadBody(read.content) == content)
    let edit = try await files.prepare(
        tool: "pen_edit_file",
        argumentsJSON: penFileArguments([
            "path": "src/App.vue", "old_text": "const taco", "new_text": "const tacos",
        ]))
    _ = try await files.commit(edit)
    #expect(
        try String(contentsOf: root.appendingPathComponent("src/App.vue"), encoding: .utf8)
            == content.replacingOccurrences(of: "const taco", with: "const tacos"))
    await #expect(throws: (any Error).self) { _ = try await files.commit(prepared) }
}

@Test func penFilesRejectEscapesSymlinksHardlinksAndSpecialFiles() async throws {
    let root = try temporaryPen()
    let outside = try temporaryPen()
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }
    let secret = outside.appendingPathComponent("secret")
    try "outside".write(to: secret, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("file-link"), withDestinationURL: secret)
    try FileManager.default.linkItem(at: secret, to: root.appendingPathComponent("hard-link"))
    let files = try PenFileTools(workspace: root)
    for path in [
        "../secret", secret.path, "link/secret", "file-link", "hard-link", ".git/config", "a/../b", "a//b", "bad\0path",
    ] {
        await #expect(throws: (any Error).self) {
            _ = try await files.read(tool: "pen_read_file", argumentsJSON: penFileArguments(["path": path]))
        }
    }
    for path in [".git/config", ".GIT/config"] {
        await #expect(throws: (any Error).self) {
            _ = try await files.prepare(
                tool: "pen_write_file", argumentsJSON: penFileArguments(["path": path, "content": "no"]))
        }
    }
    let write = try await files.prepare(
        tool: "pen_write_file", argumentsJSON: penFileArguments(["path": "link/new", "content": "no"]))
    await #expect(throws: (any Error).self) { _ = try await files.commit(write) }
    #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("new").path))
    #expect(try String(contentsOf: secret, encoding: .utf8) == "outside")
    #expect(throws: (any Error).self) { _ = try PenFileTools(workspace: URL(fileURLWithPath: "/")) }
}

@Test func penFilesRejectStaleApprovalAndCrossWorkspacePreparedWrites() async throws {
    let root = try temporaryPen()
    let other = try temporaryPen()
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: other)
    }
    let file = root.appendingPathComponent("test.txt")
    try "before".write(to: file, atomically: true, encoding: .utf8)
    let files = try PenFileTools(workspace: root)
    let elsewhere = try PenFileTools(workspace: other)
    let prepared = try await files.prepare(
        tool: "pen_edit_file",
        argumentsJSON: penFileArguments([
            "path": "test.txt", "old_text": "before", "new_text": "after",
        ]))
    await #expect(throws: (any Error).self) { _ = try await elsewhere.commit(prepared) }
    try "user edit".write(to: file, atomically: true, encoding: .utf8)
    await #expect(throws: (any Error).self) { _ = try await files.commit(prepared) }
    #expect(try String(contentsOf: file, encoding: .utf8) == "user edit")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other.appendingPathComponent("test.txt"))
    await #expect(throws: (any Error).self) { _ = try await files.commit(prepared) }
}

@Test func penFilesBoundReadsRejectAmbiguousEditsAndReplacedRoots() async throws {
    let root = try temporaryPen()
    let moved = root.appendingPathExtension("moved")
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: moved)
    }
    let files = try PenFileTools(workspace: root)
    try Data(repeating: 65, count: PenFileTools.maximumFileBytes + 1).write(to: root.appendingPathComponent("large"))
    await #expect(throws: (any Error).self) {
        _ = try await files.read(tool: "pen_read_file", argumentsJSON: #"{"path":"large"}"#)
    }
    try "repeat repeat".write(to: root.appendingPathComponent("text"), atomically: true, encoding: .utf8)
    await #expect(throws: (any Error).self) {
        _ = try await files.prepare(
            tool: "pen_edit_file", argumentsJSON: #"{"path":"text","old_text":"repeat","new_text":"once"}"#)
    }
    try FileManager.default.moveItem(at: root, to: moved)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    await #expect(throws: (any Error).self) {
        _ = try await files.read(tool: "pen_list_files", argumentsJSON: #"{"path":"."}"#)
    }
}

@Test func unchangedEditsFailBeforeApprovalWithoutRewritingTheFile() async throws {
    let root = try temporaryPen()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("example.ts")
    let content = "export const value = 'same';\n"
    try content.write(to: file, atomically: true, encoding: .utf8)
    let before = try FileManager.default.attributesOfItem(atPath: file.path)
    let files = try PenFileTools(workspace: root)
    do {
        _ = try await files.prepare(
            tool: "pen_edit_file",
            argumentsJSON: penFileArguments([
                "path": "example.ts", "old_text": content, "new_text": content,
            ]))
        Issue.record("An unchanged edit must not reach approval or report saved")
    } catch {
        #expect(error.localizedDescription.contains("No change"))
        #expect(error.localizedDescription.contains("Nothing was written"))
    }
    let after = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
    #expect(before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber)
    #expect(try String(contentsOf: file, encoding: .utf8) == content)
}

@Test func failedEditsExplainMissingAndAmbiguousMatchesAndExistingFiles() async throws {
    let root = try temporaryPen()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("text")
    try "repeat repeat".write(to: file, atomically: true, encoding: .utf8)
    let files = try PenFileTools(workspace: root)
    for (old, explanation) in [("guessed", "not found"), ("repeat", "more than once")] {
        do {
            _ = try await files.prepare(
                tool: "pen_edit_file",
                argumentsJSON: penFileArguments([
                    "path": "text", "old_text": old, "new_text": "changed",
                ]))
            Issue.record("Invalid match should fail")
        } catch {
            #expect(error.localizedDescription.contains(explanation))
            #expect(error.localizedDescription.contains("Nothing was written"))
        }
    }
    let write = try await files.prepare(
        tool: "pen_write_file",
        argumentsJSON: penFileArguments([
            "path": "text", "content": "replacement",
        ]))
    do {
        _ = try await files.commit(write)
        Issue.record("Existing file should not be overwritten")
    } catch {
        #expect(error.localizedDescription.contains("pen_read_file"))
        #expect(error.localizedDescription.contains("pen_edit_file"))
    }
    #expect(try String(contentsOf: file, encoding: .utf8) == "repeat repeat")
}

private func navigationObject(_ content: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
}

@Test func paginatedPenListingReachesEveryEntryInStableOrder() async throws {
    let root = try temporaryPen()
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 0..<425 {
        try Data().write(to: root.appendingPathComponent(String(format: "file-%03d", index)))
    }
    let files = try PenFileTools(workspace: root)
    var all: [String] = []
    var cursor: String?
    for _ in 0..<3 {
        var args = ["path": "."]
        args["after"] = cursor
        let result = try await files.read(tool: "pen_list_files", argumentsJSON: penFileArguments(args))
        let object = try navigationObject(result.content)
        let entries = try #require(object["entries"] as? [String])
        #expect(entries.count <= 200)
        all += entries
        cursor = object["next_after"] as? String
        #expect(object["truncated"] as? Bool == (cursor != nil))
    }
    #expect(cursor == nil)
    #expect(all.count == 425)
    #expect(Set(all).count == 425)
    #expect(all == all.sorted())
}

@Test func rangedPenReadsPreserveExactCRLFUnicodeAndFinalNewlines() async throws {
    let root = try temporaryPen()
    defer { try? FileManager.default.removeItem(at: root) }
    let content = (1...450).map { "line \($0): 🐐 e\u{301}\r\n" }.joined() + "last line without newline"
    try content.write(to: root.appendingPathComponent("text"), atomically: true, encoding: .utf8)
    let files = try PenFileTools(workspace: root)
    var start = 1
    var recovered = ""
    var pages = 0
    while true {
        let result = try await files.read(
            tool: "pen_read_file", argumentsJSON: "{\"path\":\"text\",\"start_line\":\(start),\"line_count\":200}")
        #expect(result.content.hasPrefix("text, lines "))
        #expect(result.content.contains("of 451"))
        recovered += penReadBody(result.content)
        pages += 1
        guard let next = penNextStartLine(result.content) else { break }
        start = next
    }
    #expect(pages == 3)
    #expect(Array(recovered.utf8) == Array(content.utf8))
    for args in [
        #"{"path":"text","start_line":true}"#, #"{"path":"text","line_count":1.5}"#,
        #"{"path":"text","start_line":452}"#, #"{"path":"text","line_count":2001}"#,
        #"{"path":"text","line_numbers":1}"#,
    ] {
        await #expect(throws: (any Error).self) { _ = try await files.read(tool: "pen_read_file", argumentsJSON: args) }
    }
}

@Test func boundedReadsSupportLargeSourceFilesAndRejectOversizedSingleLines() async throws {
    let root = try temporaryPen()
    defer { try? FileManager.default.removeItem(at: root) }
    let line = String(repeating: "a", count: 1_023) + "\n"
    try (String(repeating: line, count: 500) + "unique tail\n").write(
        to: root.appendingPathComponent("source"), atomically: true, encoding: .utf8)
    try String(repeating: "a", count: 49 * 1_024).write(
        to: root.appendingPathComponent("minified"), atomically: true, encoding: .utf8)
    let files = try PenFileTools(workspace: root)
    let source = try await files.read(tool: "pen_read_file", argumentsJSON: #"{"path":"source"}"#).content
    #expect(penReadBody(source).utf8.count == 48 * 1_024)
    #expect(penNextStartLine(source) == 49)
    let edit = try await files.prepare(
        tool: "pen_edit_file",
        argumentsJSON: penFileArguments([
            "path": "source", "old_text": "unique tail", "new_text": "changed tail",
        ]))
    _ = try await files.commit(edit)
    #expect(try String(contentsOf: root.appendingPathComponent("source"), encoding: .utf8).hasSuffix("changed tail\n"))
    await #expect(throws: (any Error).self) {
        _ = try await files.read(tool: "pen_read_file", argumentsJSON: #"{"path":"minified"}"#)
    }
}

@Test func penSearchFindsLiteralLinesAndSkipsDependenciesAndEscapingLinks() async throws {
    let root = try temporaryPen()
    let outside = try temporaryPen()
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }
    for directory in ["src", "node_modules", ".git"] {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
    }
    for path in ["src/App.vue", "node_modules/ignored.vue", ".git/ignored.vue"] {
        try "first\r\nNeedle[a]\r\nneedle[a]\r\n".write(
            to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }
    let secret = outside.appendingPathComponent("secret.vue")
    try "Needle[a]".write(to: secret, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("escape.vue"), withDestinationURL: secret)
    try FileManager.default.linkItem(at: secret, to: root.appendingPathComponent("hard.vue"))
    let files = try PenFileTools(workspace: root)
    let literal =
        try await files.read(
            tool: "pen_search", argumentsJSON: #"{"path":".","query":"Needle[a]","file_glob":"*.vue"}"#
        ).content
    let matchLines = penSearchMatches(literal)
    #expect(matchLines.count == 1)
    #expect(matchLines.first?.hasPrefix("src/App.vue:2: ") == true)
    #expect(!penSearchHeader(literal).contains("truncated"))
    let limited =
        try await files.read(
            tool: "pen_search",
            argumentsJSON: #"{"path":".","query":"Needle[a]","case_sensitive":false,"max_results":1}"#
        ).content
    #expect(penSearchHeader(limited).contains("truncated"))
    let insensitive =
        try await files.read(
            tool: "pen_search", argumentsJSON: #"{"path":"src","query":"Needle[a]","case_sensitive":false}"#
        ).content
    #expect(penSearchMatches(insensitive).count == 2)
    for args in [
        #"{"path":"../","query":"Needle"}"#, #"{"path":".","query":""}"#,
        #"{"path":".","query":"Needle","case_sensitive":1}"#, #"{"path":".","query":"Needle","max_results":true}"#,
    ] {
        await #expect(throws: (any Error).self) { _ = try await files.read(tool: "pen_search", argumentsJSON: args) }
    }
}

@Test func penSearchBoundsPathologicalUnicodeSnippetsByScalars() async throws {
    let root = try temporaryPen()
    defer { try? FileManager.default.removeItem(at: root) }
    let line = "a" + String(repeating: "\u{301}", count: 20_000) + "\n"
    try line.write(to: root.appendingPathComponent("text"), atomically: true, encoding: .utf8)
    let files = try PenFileTools(workspace: root)
    let result = try await files.read(tool: "pen_search", argumentsJSON: #"{"path":".","query":"a"}"#)
    #expect(penSearchMatches(result.content).count == 1)
    #expect(result.content.utf8.count < 2_000)
}

@Test func numberedPenReadsPrefixLinesAndFlagNumbersAsNonContent() async throws {
    let root = try temporaryPen()
    defer { try? FileManager.default.removeItem(at: root) }
    let content = "alpha\nbeta\ngamma\n"
    try content.write(to: root.appendingPathComponent("text"), atomically: true, encoding: .utf8)
    let files = try PenFileTools(workspace: root)
    let plain = try await files.read(tool: "pen_read_file", argumentsJSON: #"{"path":"text"}"#).content
    #expect(penReadBody(plain) == content)
    #expect(!penReadHeader(plain).contains("line numbers"))
    let numbered = try await files.read(
        tool: "pen_read_file", argumentsJSON: #"{"path":"text","line_numbers":true}"#
    ).content
    #expect(penReadHeader(numbered).contains("line numbers are not file content"))
    #expect(penReadBody(numbered) == "1\talpha\n2\tbeta\n3\tgamma\n")
}

@Test func penGlobListsMatchingPathsNewestFirstAndSkipsDependencies() async throws {
    let root = try temporaryPen()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
    for (name, offset) in [("src/old.swift", -300.0), ("src/mid.swift", -200.0), ("src/new.swift", -100.0)] {
        let url = root.appendingPathComponent(name)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(offset)], ofItemAtPath: url.path)
    }
    try "y".write(to: root.appendingPathComponent("node_modules/dep.swift"), atomically: true, encoding: .utf8)
    let files = try PenFileTools(workspace: root)
    let result = try await files.read(tool: "pen_glob", argumentsJSON: #"{"path":".","pattern":"*.swift"}"#).content
    #expect(penSearchMatches(result) == ["src/new.swift", "src/mid.swift", "src/old.swift"])
    let limited = try await files.read(
        tool: "pen_glob", argumentsJSON: #"{"path":".","pattern":"*.swift","max_results":2}"#
    ).content
    #expect(penSearchMatches(limited).count == 2)
    #expect(penSearchHeader(limited).contains("truncated"))
    for args in [
        #"{"pattern":""}"#, #"{"path":".","pattern":"*.swift","max_results":0}"#,
        #"{"path":".","pattern":"*.swift","max_results":501}"#,
    ] {
        await #expect(throws: (any Error).self) { _ = try await files.read(tool: "pen_glob", argumentsJSON: args) }
    }
}

@Test func penSearchRegexMatchesLinesAndRejectsInvalidPatterns() async throws {
    let root = try temporaryPen()
    defer { try? FileManager.default.removeItem(at: root) }
    try "let count = 42\nlet name = \"goat\"\n".write(
        to: root.appendingPathComponent("code.swift"), atomically: true, encoding: .utf8)
    let files = try PenFileTools(workspace: root)
    let matched = try await files.read(
        tool: "pen_search", argumentsJSON: #"{"path":".","query":"count = [0-9]+","regex":true}"#
    ).content
    #expect(penSearchMatches(matched).count == 1)
    #expect(penSearchMatches(matched).first?.hasPrefix("code.swift:1: ") == true)
    let literal = try await files.read(
        tool: "pen_search", argumentsJSON: #"{"path":".","query":"count = [0-9]+","regex":false}"#
    ).content
    #expect(penSearchMatches(literal).isEmpty)
    await #expect(throws: (any Error).self) {
        _ = try await files.read(tool: "pen_search", argumentsJSON: #"{"path":".","query":"count = [","regex":true}"#)
    }
}
