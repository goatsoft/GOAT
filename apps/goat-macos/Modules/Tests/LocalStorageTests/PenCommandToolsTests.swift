import Foundation
import JUDAS
import Pens
import Testing

private func commandFolder() throws -> URL {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(
        "command-test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func commandJSON(_ value: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
}

private func commandObject(_ text: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

private func runCommand(_ runner: PenCommandTools, _ input: [String: Any]) async throws -> [String: Any] {
    let command = try await runner.prepare(argumentsJSON: commandJSON(input))
    let started = try commandObject(await runner.start(command).content)
    let id = try #require(started["job_id"] as? String)
    for _ in 0..<20 {
        let result = try commandObject(
            await runner.invoke(
                tool: "pen_command_status", argumentsJSON: commandJSON(["job_id": id, "wait_seconds": 1])
            ).content)
        if result["running"] as? Bool == false { return result }
    }
    await runner.stopAll()
    throw CocoaError(.executableRuntimeMismatch)
}

@Test func commandsRunWithLiteralArgumentsAndConfinedFileAccess() async throws {
    let root = try commandFolder()
    let outside = try commandFolder()
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }
    let secret = outside.appendingPathComponent("secret")
    try "PRIVATE_MARKER".write(to: secret, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
    let runner = PenCommandTools(workspace: root, files: try PenFileTools(workspace: root), judas: Judas())
    let script =
        "printf 'verified 🐐\\n' > result.txt; cat result.txt; cat \"$1\"; cat escape/secret; echo bad > \"$2\"; echo bad > escape/bad; ln \"$1\" linked-secret; cat linked-secret"
    let result = try await runCommand(
        runner,
        [
            "command": "/bin/sh",
            "args": ["-c", script, "goat", secret.path, outside.appendingPathComponent("bad").path],
        ])
    let output = try #require(result["output"] as? String)
    #expect(output.contains("verified 🐐"))
    #expect(!output.contains("PRIVATE_MARKER"))
    #expect(output.contains("Operation not permitted"))
    #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("bad").path))
    #expect(try String(contentsOf: secret, encoding: .utf8) == "PRIVATE_MARKER")
    let literal = try await runCommand(runner, ["command": "/bin/echo", "args": ["$(touch injected)", "a b", "x;y"]])
    #expect((literal["output"] as? String)?.contains("$(touch injected) a b x;y") == true)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("injected").path))
    await runner.stopAll()
}

@Test func commandTimeoutStopsItsChildBeforeLaterWrites() async throws {
    let root = try commandFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = PenCommandTools(workspace: root, files: try PenFileTools(workspace: root), judas: Judas())
    let result = try await runCommand(
        runner, ["command": "/bin/sh", "args": ["-c", "(sleep 2; echo escaped > late) & wait"], "timeout_seconds": 1])
    #expect(result["running"] as? Bool == false)
    #expect((result["notice"] as? String)?.contains("timed out") == true)
    try await Task.sleep(for: .seconds(1.3))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("late").path))
    await runner.stopAll()
}

@Test func commandOutputIsBoundedAndTurnEndRevokesJobs() async throws {
    let root = try commandFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = PenCommandTools(workspace: root, files: try PenFileTools(workspace: root), judas: Judas())
    let result = try await runCommand(runner, ["command": "/bin/sh", "args": ["-c", "yes x | head -c 200000"]])
    #expect(result["exit_code"] as? Int == 0)
    #expect(result["output_truncated"] as? Bool == true)
    #expect((result["output"] as? String)?.utf8.count == 32 * 1_024)
    let command = try await runner.prepare(argumentsJSON: commandJSON(["command": "sleep", "args": ["20"]]))
    let started = try commandObject(await runner.start(command).content)
    let id = try #require(started["job_id"] as? String)
    await runner.stopAll()
    let final = try commandObject(
        await runner.invoke(tool: "pen_command_status", argumentsJSON: commandJSON(["job_id": id, "wait_seconds": 0]))
            .content)
    #expect(final["running"] as? Bool == false)
    #expect((final["notice"] as? String)?.contains("turn ended") == true)
    await #expect(throws: (any Error).self) { _ = try await runner.start(command) }
}

@Test func commandsRejectEscapingDirectoriesChangedExecutablesAndUnauthorizedNetwork() async throws {
    let root = try commandFolder()
    let outside = try commandFolder()
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }
    let policy = Judas(mode: .blocked)
    let runner = PenCommandTools(workspace: root, files: try PenFileTools(workspace: root), judas: policy)
    for input: [String: Any] in [
        ["command": "pwd", "args": [], "working_directory": ".."],
        ["command": "pwd", "args": [], "working_directory": outside.path],
        ["command": "pwd", "args": [], "network": true],
        ["command": "pwd", "args": [], "timeout_seconds": 601],
    ] {
        await #expect(throws: (any Error).self) { _ = try await runner.prepare(argumentsJSON: commandJSON(input)) }
    }
    let script = root.appendingPathComponent("script")
    try "#!/bin/sh\necho first\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let prepared = try await runner.prepare(argumentsJSON: commandJSON(["command": "./script", "args": []]))
    try "#!/bin/sh\necho replaced\n".write(to: script, atomically: true, encoding: .utf8)
    await #expect(throws: (any Error).self) { _ = try await runner.start(prepared) }
    let allowed = try await runCommand(runner, ["command": "pwd", "args": []])
    #expect(allowed["exit_code"] as? Int == 0)
    await runner.stopAll()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GOAT_LIVE_COMMANDS"] == "1"))
func nativePythonAndClangBuildInsideADisposablePen() async throws {
    let root = try commandFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = PenCommandTools(workspace: root, files: try PenFileTools(workspace: root), judas: Judas())
    try "#include <stdio.h>\nint main(void) { puts(\"GOAT_C_ACCEPTANCE_42\"); return 0; }\n".write(
        to: root.appendingPathComponent("main.c"), atomically: true, encoding: .utf8)
    let python = try await runCommand(
        runner,
        [
            "command": "/Applications/Xcode.app/Contents/Developer/usr/bin/python3",
            "args": [
                "-c",
                "import os,pathlib,sys; p=pathlib.Path('python.txt'); p.write_text('GOAT_PYTHON_ACCEPTANCE_42\\n'); assert p.read_text() == 'GOAT_PYTHON_ACCEPTANCE_42\\n'; assert os.environ['HOME'] != sys.argv[1]; print('GOAT_PYTHON_ACCEPTANCE_42')",
                FileManager.default.homeDirectoryForCurrentUser.path,
            ],
        ])
    try #require(python["exit_code"] as? Int == 0, "\(python["output"] as? String ?? "No output")")
    #expect(
        try String(contentsOf: root.appendingPathComponent("python.txt"), encoding: .utf8)
            == "GOAT_PYTHON_ACCEPTANCE_42\n")
    let compile = try await runCommand(
        runner,
        [
            "command": "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang",
            "args": [
                "-isysroot",
                "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
                "main.c", "-o", "hello",
            ],
        ])
    try #require(compile["exit_code"] as? Int == 0, "\(compile["output"] as? String ?? "No output")")
    let execute = try await runCommand(runner, ["command": "./hello", "args": []])
    #expect(execute["exit_code"] as? Int == 0)
    #expect((execute["output"] as? String)?.contains("GOAT_C_ACCEPTANCE_42") == true)
    await runner.stopAll()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GOAT_LIVE_COMMANDS"] == "1"))
func nativeNpmInstallsBuildsAndTestsWithAnIsolatedHome() async throws {
    let root = try commandFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    try
        #"{"name":"goat-command-fixture","private":true,"scripts":{"build":"node build.cjs","test":"node --test test.cjs"},"devDependencies":{"esbuild":"0.25.0"}}"#
        .write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    try "export const value: number = 42;\n".write(
        to: root.appendingPathComponent("source.ts"), atomically: true, encoding: .utf8)
    try #"require('esbuild').buildSync({entryPoints:['source.ts'],outfile:'output.cjs',bundle:true,platform:'node'});"#
        .write(to: root.appendingPathComponent("build.cjs"), atomically: true, encoding: .utf8)
    try #"require('node:assert/strict').equal(require('./output.cjs').value, 42);"#
        .write(to: root.appendingPathComponent("test.cjs"), atomically: true, encoding: .utf8)
    let runner = PenCommandTools(workspace: root, files: try PenFileTools(workspace: root), judas: Judas())
    for (arguments, network) in [
        (["install", "--no-audit", "--no-fund"], true), (["run", "build"], false), (["test"], false),
    ] {
        let result = try await runCommand(runner, ["command": "npm", "args": arguments, "network": network])
        #expect(result["exit_code"] as? Int == 0, "\(result["output"] as? String ?? "No output")")
    }
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("output.cjs").path))
    await runner.stopAll()
}

@Test func commandsRejectPreexistingHardLinksSharedOutsideTheWorkspace() async throws {
    let root = try commandFolder()
    let outside = try commandFolder()
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }
    let original = outside.appendingPathComponent("original")
    try "unchanged".write(to: original, atomically: true, encoding: .utf8)
    try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("linked"))
    let runner = PenCommandTools(workspace: root, files: try PenFileTools(workspace: root), judas: Judas())
    await #expect(throws: (any Error).self) {
        _ = try await runner.prepare(argumentsJSON: #"{"command":"sh","args":["-c","echo bad > linked"]}"#)
    }
    #expect(try String(contentsOf: original, encoding: .utf8) == "unchanged")
    await runner.stopAll()
}

@Test func changingNetworkPolicyStopsAnApprovedNetworkJob() async throws {
    let root = try commandFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let policy = Judas()
    let runner = PenCommandTools(workspace: root, files: try PenFileTools(workspace: root), judas: policy)
    let prepared = try await runner.prepare(argumentsJSON: #"{"command":"sleep","args":["10"],"network":true}"#)
    let started = try commandObject(await runner.start(prepared).content)
    let id = try #require(started["job_id"] as? String)
    policy.setMode(.blocked)
    let result = try commandObject(
        await runner.invoke(tool: "pen_command_status", argumentsJSON: commandJSON(["job_id": id, "wait_seconds": 1]))
            .content)
    #expect(result["running"] as? Bool == false)
    #expect((result["notice"] as? String)?.contains("JUDAS") == true)
    await runner.stopAll()
}

@Test func removingAFileUsesARealCommandJobAndUnknownJobsGiveRecoveryGuidance() async throws {
    let root = try commandFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("obsolete config.ts")
    try "old".write(to: path, atomically: true, encoding: .utf8)
    let runner = PenCommandTools(workspace: root, files: try PenFileTools(workspace: root), judas: Judas())
    do {
        _ = try await runner.invoke(tool: "pen_stop_command", argumentsJSON: #"{"job_id":"job1"}"#)
        Issue.record("An invented job must fail")
    } catch {
        #expect(error.localizedDescription.contains("do not invent or alter a job ID"))
    }
    #expect(FileManager.default.fileExists(atPath: path.path))
    let result = try await runCommand(runner, ["command": "rm", "args": ["--", "obsolete config.ts"]])
    #expect(result["exit_code"] as? Int == 0)
    #expect(result["running"] as? Bool == false)
    #expect(!FileManager.default.fileExists(atPath: path.path))
}
