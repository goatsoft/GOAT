import Darwin
import Foundation
import System
import Testing

@testable import MCPClient

private func tempConfig(_ contents: String? = nil) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("goat-mcp-\(UUID().uuidString).json")
    if let contents {
        try contents.data(using: .utf8)!.write(to: url)
    }
    return url
}

private let sample = """
    {
      "mcpServers": {
        "filesystem": {
          "command": "npx",
          "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
          "env": {"FOO": "bar"}
        },
        "linear": {
          "url": "https://mcp.linear.app/mcp",
          "headers": {"Authorization": "Bearer x"}
        },
        "sleepy": {
          "command": "uvx",
          "args": ["some-server"],
          "disabled": true
        },
        "weird-future-thing": {
          "somethingUnknown": true
        }
      },
      "topLevelUnknown": {"keep": "me"}
    }
    """

@Test func parsesClaudeDesktopShape() throws {
    let url = try tempConfig(sample)
    let configs = try MCPConfigFile.load(from: url)
    #expect(configs.count == 3)  // unknown-shape entry skipped, not destroyed

    let fs = configs.first { $0.name == "filesystem" }!
    guard case .stdio(let command, let args, let env) = fs.transport else {
        Issue.record("not stdio")
        return
    }
    #expect(command == "npx")
    #expect(args.count == 3)
    #expect(env["FOO"] == "bar")
    #expect(!fs.disabled)

    let linear = configs.first { $0.name == "linear" }!
    guard case .http(let u, let headers) = linear.transport else {
        Issue.record("not http")
        return
    }
    #expect(u.absoluteString == "https://mcp.linear.app/mcp")
    #expect(headers["Authorization"] == "Bearer x")

    #expect(configs.first { $0.name == "sleepy" }!.disabled)
}

@Test func upsertPreservesUnknownKeysAndServers() throws {
    let url = try tempConfig(sample)
    let new = MCPServerConfig(name: "brave", transport: .stdio(command: "npx", args: ["-y", "brave-search"], env: [:]))
    try MCPConfigFile.upsert(new, in: url)

    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    #expect((root["topLevelUnknown"] as? [String: Any])?["keep"] as? String == "me")
    let servers = root["mcpServers"] as! [String: Any]
    #expect((servers["weird-future-thing"] as? [String: Any])?["somethingUnknown"] as? Bool == true)
    #expect(servers["brave"] != nil)
    #expect(try MCPConfigFile.load(from: url).count == 4)
}

@Test func disableRoundTripsThroughTheFile() throws {
    let url = try tempConfig(sample)
    try MCPConfigFile.setDisabled(true, name: "filesystem", in: url)
    #expect(try MCPConfigFile.load(from: url).first { $0.name == "filesystem" }!.disabled)
    try MCPConfigFile.setDisabled(false, name: "filesystem", in: url)
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    let entry = (root["mcpServers"] as! [String: Any])["filesystem"] as! [String: Any]
    #expect(entry["disabled"] == nil)  // re-enabling removes the key, not sets false
}

@Test func removeDeletesOnlyTheNamedServer() throws {
    let url = try tempConfig(sample)
    try MCPConfigFile.remove(name: "linear", from: url)
    let names = try MCPConfigFile.load(from: url).map(\.name)
    #expect(!names.contains("linear"))
    #expect(names.contains("filesystem"))
}

@Test func missingFileIsCreatedEmpty() throws {
    let url = try tempConfig(nil)
    #expect(try MCPConfigFile.load(from: url).isEmpty)
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test func configCreationAndReplacementUseOwnerOnlyPermissions() throws {
    let url = try tempConfig(nil)
    _ = try MCPConfigFile.load(from: url)
    #expect(try configPermissions(url) == 0o600)

    #expect(chmod(url.path, mode_t(0o644)) == 0)
    _ = try MCPConfigFile.load(from: url)
    #expect(try configPermissions(url) == 0o600)

    let server = MCPServerConfig(
        name: "secure", transport: .stdio(command: "tool", args: [], env: ["TOKEN": "secret"]))
    try MCPConfigFile.upsert(server, in: url)
    #expect(try configPermissions(url) == 0o600)
}

@Test func directConfigSymlinkIsRejectedWithoutTouchingTarget() throws {
    let target = try tempConfig(sample)
    let before = try Data(contentsOf: target)
    let link = FileManager.default.temporaryDirectory
        .appendingPathComponent("goat-mcp-link-\(UUID().uuidString).json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    defer { try? FileManager.default.removeItem(at: link) }

    #expect(throws: MCPConfigFile.ConfigError.self) {
        _ = try MCPConfigFile.load(from: link)
    }
    #expect(throws: MCPConfigFile.ConfigError.self) {
        try MCPConfigFile.upsert(
            MCPServerConfig(
                name: "safe", transport: .stdio(command: "tool", args: [], env: [:])),
            in: link)
    }
    #expect(try Data(contentsOf: target) == before)
}

private func configPermissions(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

@Test func unknownTransportShapeRemainsInertAndPreserved() throws {
    let url = try tempConfig(sample)
    let loaded = try MCPConfigFile.load(from: url)
    #expect(!loaded.contains(where: { $0.name == "weird-future-thing" }))

    let added = MCPServerConfig(
        name: "safe", transport: .stdio(command: "tool", args: [], env: [:]))
    try MCPConfigFile.upsert(added, in: url)
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    let servers = root["mcpServers"] as! [String: Any]
    let unknown = servers["weird-future-thing"] as! [String: Any]
    #expect(unknown["somethingUnknown"] as? Bool == true)
}

@Test func configFileWorkerSerializesMutationAndRefresh() async throws {
    let url = try tempConfig(sample)
    let worker = MCPConfigFileWorker()
    let added = MCPServerConfig(
        name: "worker-test",
        transport: .stdio(command: "tool", args: ["serve"], env: [:]))

    let afterInsert = try await worker.upsertAndLoad(added, revision: 1, in: url)
    #expect(afterInsert.contains(where: { $0.name == added.name }))

    let afterDisable = try await worker.setDisabledAndLoad(
        true, name: added.name, revision: 2, in: url)
    #expect(afterDisable.first(where: { $0.name == added.name })?.disabled == true)

    let afterRemove = try await worker.removeAndLoad(name: added.name, revision: 3, from: url)
    #expect(!afterRemove.contains(where: { $0.name == added.name }))
}

@Test func configFileWorkerRejectsOutOfOrderMutation() async throws {
    let url = try tempConfig(sample)
    let worker = MCPConfigFileWorker()
    let added = MCPServerConfig(
        name: "newer", transport: .stdio(command: "tool", args: [], env: [:]))

    _ = try await worker.upsertAndLoad(added, revision: 10, in: url)
    do {
        _ = try await worker.removeAndLoad(name: added.name, revision: 9, from: url)
        Issue.record("stale mutation was accepted")
    } catch let error as MCPConfigFileWorker.MutationError {
        #expect(error == .staleOperation(requested: 9, latest: 10))
    }
    await #expect(throws: MCPConfigFileWorker.MutationError.self) {
        _ = try await worker.setDisabledAndLoad(
            true, name: added.name, revision: 10, in: url)
    }
    #expect(try MCPConfigFile.load(from: url).contains(where: { $0.name == added.name }))
}

@Test func corruptConfigIsNeverOverwrittenByMutation() throws {
    let original = #"{"mcpServers": "not-an-object", "keep": true}"#
    let url = try tempConfig(original)
    let added = MCPServerConfig(
        name: "safe", transport: .stdio(command: "tool", args: [], env: [:]))

    #expect(throws: MCPConfigFile.ConfigError.self) {
        try MCPConfigFile.upsert(added, in: url)
    }
    #expect(try String(contentsOf: url, encoding: .utf8) == original)
}

@Test func mutationCannotWriteAConfigWhichItsReaderWouldReject() throws {
    let limit = 5 * 1024 * 1024
    let padding = String(repeating: "x", count: limit - 256)
    let original = #"{"mcpServers":{},"padding":"\#(padding)"}"#
    let originalData = Data(original.utf8)
    #expect(originalData.count < limit)
    let url = try tempConfig(original)
    let added = MCPServerConfig(
        name: "bounded",
        transport: .stdio(command: "tool", args: [String(repeating: "y", count: 1024)], env: [:]))

    #expect(throws: MCPConfigFile.ConfigError.self) {
        try MCPConfigFile.upsert(added, in: url)
    }
    #expect(try Data(contentsOf: url) == originalData)
}

@Test func importValidatesEveryServerBeforeWriting() throws {
    let url = try tempConfig(sample)
    let before = try Data(contentsOf: url)
    let valid = MCPServerConfig(
        name: "valid", transport: .stdio(command: "tool", args: [], env: [:]))
    let invalid = MCPServerConfig(
        name: "invalid name", transport: .stdio(command: "tool", args: [], env: [:]))

    #expect(throws: MCPConfigFile.ConfigError.self) {
        try MCPConfigFile.importParsed([valid, invalid], into: url)
    }
    #expect(try Data(contentsOf: url) == before)
}

@Test func malformedRecognizedEntryFailsClosed() throws {
    let original = #"{"mcpServers":{"broken":{"command":"tool","args":"not-an-array"}}}"#
    let url = try tempConfig(original)

    #expect(throws: MCPConfigFile.ConfigError.self) {
        _ = try MCPConfigFile.load(from: url)
    }
    #expect(throws: MCPConfigFile.ConfigError.self) {
        try MCPConfigFile.setDisabled(true, name: "broken", in: url)
    }
    #expect(try String(contentsOf: url, encoding: .utf8) == original)
}

@Test func missingConfigMutationIsReportedWithoutWriting() throws {
    let url = try tempConfig(sample)
    let before = try Data(contentsOf: url)

    #expect(throws: MCPConfigFile.ConfigError.self) {
        try MCPConfigFile.setDisabled(true, name: "missing", in: url)
    }
    #expect(throws: MCPConfigFile.ConfigError.self) {
        try MCPConfigFile.remove(name: "missing", from: url)
    }
    #expect(try Data(contentsOf: url) == before)
}

@Test func renameCannotOverwriteAnotherServer() throws {
    let url = try tempConfig(sample)
    let before = try Data(contentsOf: url)
    let renamed = MCPServerConfig(
        name: "linear", transport: .stdio(command: "replacement", args: [], env: [:]))

    #expect(throws: MCPConfigFile.ConfigError.self) {
        try MCPConfigFile.upsert(renamed, renamedFrom: "filesystem", in: url)
    }
    #expect(try Data(contentsOf: url) == before)
}

@Test func specialConfigAndImportFilesAreRejectedWithoutBlocking() throws {
    let fifo = try tempConfig(nil)
    #expect(mkfifo(fifo.path, 0o600) == 0)
    defer { unlink(fifo.path) }

    #expect(throws: MCPConfigFile.ConfigError.self) {
        _ = try MCPConfigFile.load(from: fifo)
    }
    #expect(throws: MCPConfigFile.ConfigError.self) {
        _ = try CodexConfig.load(from: fifo)
    }
}

@Test func validatesServerIdentityAndHTTPBoundary() throws {
    let invalidName = MCPServerConfig(
        name: "a/b", transport: .stdio(command: "tool", args: [], env: [:]))
    #expect(throws: MCPConfigFile.ConfigError.self) { try invalidName.validate() }

    let embeddedCredentials = MCPServerConfig(
        name: "remote",
        transport: .http(
            url: try #require(URL(string: "https://user:secret@example.com/mcp")), headers: [:]))
    #expect(throws: MCPConfigFile.ConfigError.self) { try embeddedCredentials.validate() }

    let framingOverride = MCPServerConfig(
        name: "remote",
        transport: .http(
            url: try #require(URL(string: "https://example.com/mcp")),
            headers: ["MCP-Session-Id": "attacker-controlled"]))
    #expect(throws: MCPConfigFile.ConfigError.self) { try framingOverride.validate() }

    let headerInjection = MCPServerConfig(
        name: "remote",
        transport: .http(
            url: try #require(URL(string: "https://example.com/mcp")),
            headers: ["Authorization": "Bearer ok\r\nX-Injected: yes"]))
    #expect(throws: MCPConfigFile.ConfigError.self) { try headerInjection.validate() }
}

@Test func plaintextHTTPIsLimitedToExplicitLoopbackHostsByDefault() throws {
    let accepted = [
        "https://example.com/mcp",
        "http://localhost:8080/mcp",
        "http://worker.localhost/mcp",
        "http://127.0.0.42/mcp",
        "http://[::1]/mcp",
    ]
    for rawURL in accepted {
        let config = MCPServerConfig(
            name: "accepted", transport: .http(url: try #require(URL(string: rawURL)), headers: [:]))
        try config.validate()
    }

    let rejected = [
        "http://example.com/mcp",
        "http://192.168.1.2/mcp",
        "http://0.0.0.0/mcp",
        "http://[::ffff:127.0.0.1]/mcp",
    ]
    for rawURL in rejected {
        let config = MCPServerConfig(
            name: "rejected", transport: .http(url: try #require(URL(string: rawURL)), headers: [:]))
        #expect(throws: MCPConfigFile.ConfigError.self) { try config.validate() }
    }

    let appOwnedPrivateServer = MCPServerConfig(
        name: "managed-private-server",
        transport: .http(url: try #require(URL(string: "http://192.168.253.1/mcp")), headers: [:]),
        allowsPrivateNetworkHTTP: true)
    try appOwnedPrivateServer.validate()

    let publicServer = MCPServerConfig(
        name: "managed-public-server",
        transport: .http(url: try #require(URL(string: "http://8.8.8.8/mcp")), headers: [:]),
        allowsPrivateNetworkHTTP: true)
    #expect(throws: MCPConfigFile.ConfigError.self) { try publicServer.validate() }
}

@Test func configBoundsTotalAndEnabledServersWithoutOverwriting() throws {
    var enabledServers: [String: Any] = [:]
    for index in 0..<MCPConfigFile.maximumEnabledServers {
        enabledServers["server_\(index)"] = ["command": "tool"]
    }
    enabledServers["disabled_extra"] = ["command": "tool", "disabled": true]
    let enabledURL = try tempConfig(
        String(
            decoding: try JSONSerialization.data(withJSONObject: ["mcpServers": enabledServers]),
            as: UTF8.self))
    #expect(try MCPConfigFile.load(from: enabledURL).count == enabledServers.count)

    enabledServers["disabled_extra"] = ["command": "tool"]
    let tooManyEnabledData = try JSONSerialization.data(
        withJSONObject: ["mcpServers": enabledServers])
    try tooManyEnabledData.write(to: enabledURL)
    #expect(throws: MCPConfigFile.ConfigError.self) {
        _ = try MCPConfigFile.load(from: enabledURL)
    }

    var inertServers: [String: Any] = [:]
    for index in 0..<MCPConfigFile.maximumConfiguredServers {
        inertServers["future_\(index)"] = ["unknownTransport": true]
    }
    let boundedData = try JSONSerialization.data(withJSONObject: ["mcpServers": inertServers])
    let totalURL = try tempConfig(String(decoding: boundedData, as: UTF8.self))
    #expect(try MCPConfigFile.load(from: totalURL).isEmpty)

    let added = MCPServerConfig(
        name: "one_too_many", transport: .stdio(command: "tool", args: [], env: [:]))
    #expect(throws: MCPConfigFile.ConfigError.self) {
        try MCPConfigFile.upsert(added, in: totalURL)
    }
    #expect(try Data(contentsOf: totalURL) == boundedData)
}

@Test func permissionFingerprintIsStableAndCapabilityBound() throws {
    let url = try #require(URL(string: "https://example.com/mcp"))
    let first = MCPServerConfig(
        name: "remote",
        transport: .http(
            url: url,
            headers: ["Authorization": "Bearer secret", "X-Tenant": "one"]))
    let reordered = MCPServerConfig(
        name: "remote",
        transport: .http(
            url: url,
            headers: ["X-Tenant": "one", "Authorization": "Bearer secret"]))
    let changedSecret = MCPServerConfig(
        name: "remote",
        transport: .http(
            url: url,
            headers: ["Authorization": "Bearer other", "X-Tenant": "one"]))

    #expect(first.permissionFingerprint == reordered.permissionFingerprint)
    #expect(first.permissionFingerprint != changedSecret.permissionFingerprint)
    #expect(first.permissionFingerprint.count == 64)

    let stdio = MCPServerConfig(
        name: "local",
        transport: .stdio(
            command: "tool", args: ["serve", "--safe"], env: ["A": "one", "B": "two"]))
    let reorderedEnvironment = MCPServerConfig(
        name: "local",
        transport: .stdio(
            command: "tool", args: ["serve", "--safe"], env: ["B": "two", "A": "one"]))
    let changedArgument = MCPServerConfig(
        name: "local",
        transport: .stdio(
            command: "tool", args: ["serve", "--unsafe"], env: ["A": "one", "B": "two"]))
    #expect(stdio.permissionFingerprint == reorderedEnvironment.permissionFingerprint)
    #expect(stdio.permissionFingerprint != changedArgument.permissionFingerprint)
}

@Test func configuredHTTPHeadersAreAppliedWithoutDroppingTransportHeaders() throws {
    let url = try #require(URL(string: "https://example.com/mcp"))
    var request = URLRequest(url: url)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let modified = MCPServerManager.applyingHTTPHeaders(
        ["Authorization": "Bearer secret", "X-Tenant": "one"], to: request)

    #expect(modified.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    #expect(modified.value(forHTTPHeaderField: "X-Tenant") == "one")
    #expect(modified.value(forHTTPHeaderField: "Content-Type") == "application/json")
}

@Test func malformedToolArgumentsAreRejected() throws {
    _ = try MCPServerManager.decodeToolArguments(#"{"path":"README.md"}"#)
    #expect(MCPServerManager.argumentsAreValid(#"{"path":"README.md"}"#))
    for invalid in ["", "null", "[]", #"{"unterminated":true"#] {
        #expect(!MCPServerManager.argumentsAreValid(invalid))
        #expect(throws: MCPError.self) {
            _ = try MCPServerManager.decodeToolArguments(invalid)
        }
    }

    let oversized = #"{"value":"\#(String(repeating: "x", count: MCPServerManager.maximumArgumentBytes))"}"#
    #expect(!MCPServerManager.argumentsAreValid(oversized))
}

@Test func toolResultAndUnicodeGraphemesAreBoundedByBytes() {
    let pathological = "a" + String(repeating: "\u{0301}", count: 10_000)
    let result = MCPServerManager.boundedToolResultText([pathological], maximumBytes: 64)
    let markerBytes = Data("\n… (truncated)".utf8).count

    #expect(result.contains("(truncated)"))
    #expect(result.utf8.count <= 64 + markerBytes + 2)
}

private actor CleanupProbe {
    private var didRun = false

    func mark() { didRun = true }
    func value() -> Bool { didRun }
}

@Test func timeoutReturnsAtTheDeadlineForNonCooperativeWork() async throws {
    let probe = CleanupProbe()
    let start = Date()
    do {
        _ = try await withTimeout(
            seconds: 0.03,
            onTimeout: { await probe.mark() }
        ) {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                    continuation.resume(returning: ())
                }
            }
        }
        Issue.record("operation did not time out")
    } catch MCPError.timeout {
        // Expected.
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    #expect(Date().timeIntervalSince(start) < 0.15)
    try await Task.sleep(for: .milliseconds(20))
    #expect(await probe.value())
}

@Test func cancellationReturnsWithoutWaitingForNonCooperativeWork() async throws {
    let probe = CleanupProbe()
    let task = Task {
        _ = try await withTimeout(
            seconds: 10,
            onCancel: { await probe.mark() }
        ) {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                    continuation.resume(returning: ())
                }
            }
        }
    }
    try await Task.sleep(for: .milliseconds(20))
    let cancellationTime = Date()
    task.cancel()
    do {
        try await task.value
        Issue.record("cancelled operation returned successfully")
    } catch is CancellationError {
        // Expected.
    }

    #expect(Date().timeIntervalSince(cancellationTime) < 0.15)
    try await Task.sleep(for: .milliseconds(20))
    #expect(await probe.value())
}

@Test func processTerminationEscalatesWhenTermIsIgnored() async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "trap '' TERM; read line"]
    process.standardInput = Pipe()
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    defer {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    MCPServerManager.stopProcess(process, grace: 0.02)
    try await Task.sleep(for: .milliseconds(100))
    #expect(!process.isRunning)
}

@Test func importSkipsExistingNames() throws {
    let target = try tempConfig(sample)
    let source = try tempConfig(
        """
        {"mcpServers": {
          "filesystem": {"command": "different", "args": []},
          "fetch": {"command": "uvx", "args": ["mcp-server-fetch"]}
        }}
        """)
    let imported = try MCPConfigFile.importServers(from: source, into: target)
    #expect(imported == ["fetch"])
    let fs = try MCPConfigFile.load(from: target).first { $0.name == "filesystem" }!
    guard case .stdio(let command, _, _) = fs.transport else {
        Issue.record("not stdio")
        return
    }
    #expect(command == "npx")  // existing entry untouched
}

@Test func importsNeverCreateChmodOrFollowTheSource() throws {
    let source = try tempConfig(
        #"{"mcpServers":{"new_source":{"command":"tool","args":["value with spaces"]}}}"#)
    #expect(chmod(source.path, mode_t(0o644)) == 0)
    let target = try tempConfig(sample)
    #expect(try MCPConfigFile.importServers(from: source, into: target) == ["new_source"])
    #expect(try configPermissions(source) == 0o644)

    let missing = try tempConfig(nil)
    #expect(throws: Error.self) {
        _ = try MCPConfigFile.importServers(from: missing, into: target)
    }
    #expect(!FileManager.default.fileExists(atPath: missing.path))

    let codex = try tempConfig(codexSample)
    let codexLink = FileManager.default.temporaryDirectory
        .appendingPathComponent("goat-codex-link-\(UUID().uuidString).toml")
    try FileManager.default.createSymbolicLink(at: codexLink, withDestinationURL: codex)
    defer { try? FileManager.default.removeItem(at: codexLink) }
    #expect(throws: MCPConfigFile.ConfigError.self) {
        _ = try CodexConfig.load(from: codexLink)
    }
}

// MARK: - Codex (TOML) import

private let codexSample = """
    model = "gpt-5"

    [mcp_servers.tooluniverse]
    command = "uvx"
    args = ["--refresh", "tooluniverse"]  # inline comment

    [mcp_servers.tooluniverse.env]
    PYTHONIOENCODING = "utf-8"

    [mcp_servers.fetch]
    command = "uvx"
    args = [
      "mcp-server-fetch",
      "--verbose",
    ]

    [mcp_servers.remote]
    url = "https://mcp.example.com/mcp"

    [mcp_servers.remote.headers]
    Authorization = "Bearer abc"

    [mcp_servers.inline]
    command = "node"
    args = ["server.js"]
    env = { KEY = "val", TWO = "2" }
    """

@Test func parsesCodexToml() throws {
    let configs = CodexConfig.parse(codexSample)
    #expect(configs.count == 4)

    let tu = configs.first { $0.name == "tooluniverse" }!
    guard case .stdio(let cmd, let args, let env) = tu.transport else {
        Issue.record("not stdio")
        return
    }
    #expect(cmd == "uvx")
    #expect(args == ["--refresh", "tooluniverse"])
    #expect(env["PYTHONIOENCODING"] == "utf-8")

    let fetch = configs.first { $0.name == "fetch" }!
    guard case .stdio(_, let fargs, _) = fetch.transport else {
        Issue.record("not stdio")
        return
    }
    #expect(fargs == ["mcp-server-fetch", "--verbose"])  // multi-line array

    let remote = configs.first { $0.name == "remote" }!
    guard case .http(let u, let headers) = remote.transport else {
        Issue.record("not http")
        return
    }
    #expect(u.absoluteString == "https://mcp.example.com/mcp")
    #expect(headers["Authorization"] == "Bearer abc")

    let inline = configs.first { $0.name == "inline" }!
    guard case .stdio(_, _, let ienv) = inline.transport else {
        Issue.record("not stdio")
        return
    }
    #expect(ienv["KEY"] == "val")
    #expect(ienv["TWO"] == "2")
}

@Test func importParsedMarksServersDisabled() throws {
    let target = try tempConfig(sample)
    let imported = try MCPConfigFile.importParsed(CodexConfig.parse(codexSample), into: target)
    #expect(imported.count == 4)
    let loaded = try MCPConfigFile.load(from: target)
    for name in imported {
        #expect(loaded.first { $0.name == name }!.disabled)  // imported servers arrive off
    }
}

@Test func reloadPreparationPublishesAllPendingServersBeforeConnecting() async throws {
    let manager = MCPServerManager()
    let alpha = MCPServerConfig(
        name: "alpha", transport: .http(url: try #require(URL(string: "http://127.0.0.1:9101")), headers: [:]))
    let beta = MCPServerConfig(
        name: "beta", transport: .http(url: try #require(URL(string: "http://127.0.0.1:9102")), headers: [:]))
    let sleeping = MCPServerConfig(
        name: "sleeping", transport: .stdio(command: "unused", args: [], env: [:]), disabled: true)

    let pending = await manager.prepareReload([alpha, beta, sleeping])
    let states = await manager.snapshot()

    #expect(Set(pending.map(\.name)) == ["alpha", "beta"])
    #expect(states["alpha"]?.status == .connecting)
    #expect(states["beta"]?.status == .connecting)
    #expect(states["sleeping"]?.status == .disconnected)
}

@Test func disconnectInvalidatesAPreparedConnectionBeforeItTouchesTheNetwork() async throws {
    let manager = MCPServerManager()
    let config = MCPServerConfig(
        name: "alpha", transport: .http(url: try #require(URL(string: "http://127.0.0.1:9101")), headers: [:]))
    let pending = await manager.prepareReload([config])
    let attempt = try #require(pending.first)

    await manager.disconnect(name: config.name)
    let staleResult = await manager.connectPrepared(attempt)
    let states = await manager.snapshot()

    #expect(staleResult == nil)
    #expect(states[config.name]?.status == .disconnected)
}

@Test func newerReloadInvalidatesAnOlderPreparedConnection() async throws {
    let manager = MCPServerManager()
    let first = MCPServerConfig(
        name: "alpha",
        transport: .http(
            url: try #require(URL(string: "http://127.0.0.1:9101")), headers: [:]))
    let changed = MCPServerConfig(
        name: "alpha",
        transport: .http(
            url: try #require(URL(string: "http://127.0.0.1:9102")), headers: [:]))
    let firstAttempt = try #require(await manager.prepareReload([first]).first)
    let nextAttempts = await manager.prepareReload([changed])

    #expect(nextAttempts.count == 1)
    #expect(await manager.connectPrepared(firstAttempt) == nil)
    #expect((await manager.capabilitySnapshots()).isEmpty)
}

// MARK: - Bounded transport safety boundary

private func makePipeDescriptors() throws -> (read: Int32, write: Int32) {
    var descriptors = [Int32](repeating: -1, count: 2)
    let result = descriptors.withUnsafeMutableBufferPointer { buffer in
        pipe(buffer.baseAddress!)
    }
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return (descriptors[0], descriptors[1])
}

private func makeBoundedStdioTransport(
    maximumFrameBytes: Int = 128,
    maximumQueuedFrames: Int = 1
) throws -> (transport: BoundedStdioTransport, serverWrite: Int32, serverRead: Int32) {
    let inbound = try makePipeDescriptors()
    let outbound = try makePipeDescriptors()
    do {
        let transport = try BoundedStdioTransport(
            input: FileDescriptor(rawValue: inbound.read),
            output: FileDescriptor(rawValue: outbound.write),
            maximumFrameBytes: maximumFrameBytes,
            maximumQueuedFrames: maximumQueuedFrames)
        close(inbound.read)
        close(outbound.write)
        return (transport, inbound.write, outbound.read)
    } catch {
        close(inbound.read)
        close(inbound.write)
        close(outbound.read)
        close(outbound.write)
        throw error
    }
}

private func writeAll(_ data: Data, to descriptor: Int32) throws {
    var offset = 0
    while offset < data.count {
        let count = data.withUnsafeBytes { bytes in
            Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        }
        guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        offset += count
    }
}

@Test func boundedSSESupportsEveryLineEndingAndEnforcesTheExactLimit() throws {
    var mixed = BoundedSSEDecoder(maximumEventBytes: 128)
    var events: [Data] = []
    for byte in Data("data: one\rdata: two\r\rdata: three\r\n\r\n".utf8) {
        if let event = try mixed.append(byte) { events.append(event) }
    }
    if let event = try mixed.finish() { events.append(event) }
    #expect(events.map { String(decoding: $0, as: UTF8.self) } == ["one\ntwo", "three"])

    let exactBytes = Data("data: exact\n\n".utf8)
    var exact = BoundedSSEDecoder(maximumEventBytes: exactBytes.count)
    var exactEvent: Data?
    for byte in exactBytes {
        if let event = try exact.append(byte) { exactEvent = event }
    }
    #expect(String(decoding: try #require(exactEvent), as: UTF8.self) == "exact")

    var oversized = BoundedSSEDecoder(maximumEventBytes: exactBytes.count - 1)
    #expect(throws: BoundedTransportError.self) {
        for byte in exactBytes { _ = try oversized.append(byte) }
    }
}

@Test func boundedStdioFramesCRLFAndFailsOnUnexpectedEOF() async throws {
    var setup = try makeBoundedStdioTransport()
    defer {
        close(setup.serverWrite)
        close(setup.serverRead)
    }
    try await setup.transport.connect()
    let stream = await setup.transport.receive()
    var iterator = stream.makeAsyncIterator()
    try writeAll(Data("first\r\nsecond\n".utf8), to: setup.serverWrite)

    #expect(try await iterator.next() == Data("first".utf8))
    #expect(try await iterator.next() == Data("second".utf8))

    close(setup.serverWrite)
    setup.serverWrite = -1
    do {
        _ = try await iterator.next()
        Issue.record("unexpected EOF finished normally")
    } catch let error as BoundedTransportError {
        #expect(error == .connectionClosed)
    }
    await setup.transport.disconnect()
}

@Test func boundedStdioRejectsUnterminatedAndQueuedOverflow() async throws {
    let oversized = try makeBoundedStdioTransport(maximumFrameBytes: 8)
    defer {
        close(oversized.serverWrite)
        close(oversized.serverRead)
    }
    try await oversized.transport.connect()
    var oversizedIterator = await oversized.transport.receive().makeAsyncIterator()
    try writeAll(Data("123456789".utf8), to: oversized.serverWrite)
    do {
        _ = try await oversizedIterator.next()
        Issue.record("oversized unterminated frame was accepted")
    } catch let error as BoundedTransportError {
        #expect(error == .inboundFrameTooLarge(8))
    }
    await oversized.transport.disconnect()

    let queued = try makeBoundedStdioTransport(maximumQueuedFrames: 1)
    defer {
        close(queued.serverWrite)
        close(queued.serverRead)
    }
    try await queued.transport.connect()
    try writeAll(Data("one\ntwo\n".utf8), to: queued.serverWrite)
    try await Task.sleep(for: .milliseconds(30))
    var queuedIterator = await queued.transport.receive().makeAsyncIterator()
    #expect(try await queuedIterator.next() == Data("one".utf8))
    do {
        _ = try await queuedIterator.next()
        Issue.record("receive queue overflow finished normally")
    } catch let error as BoundedTransportError {
        #expect(error == .receiveQueueOverflow)
    }
    await queued.transport.disconnect()
}

@Test func closedStdioReaderReturnsEPIPEInsteadOfTerminatingGOAT() async throws {
    var setup = try makeBoundedStdioTransport()
    defer {
        close(setup.serverWrite)
        if setup.serverRead >= 0 { close(setup.serverRead) }
    }
    close(setup.serverRead)
    setup.serverRead = -1
    try await setup.transport.connect()
    do {
        try await setup.transport.send(Data("request".utf8))
        Issue.record("write unexpectedly succeeded after the child closed stdin")
    } catch {
        #expect((error as? Errno) == .brokenPipe)
    }
    await setup.transport.disconnect()
    await setup.transport.disconnect()
}

@Test func structuredResultAllowancePreservesJSONWithoutChangingDefaultToolLimit() throws {
    let json = "{\"items\":[\"" + String(repeating: "a", count: 64_000) + "\"]}"
    let ordinary = MCPServerManager.boundedToolResultText([json])
    #expect(ordinary.hasSuffix("\n… (truncated)"))
    let structured = MCPServerManager.boundedToolResultText(
        [json], maximumBytes: MCPServerManager.maximumStructuredResultBytes)
    #expect(structured == json)
    _ = try JSONSerialization.jsonObject(with: Data(structured.utf8))
    let oversized = MCPServerManager.boundedToolResultText(
        [String(repeating: "a", count: MCPServerManager.maximumStructuredResultBytes + 1)],
        maximumBytes: MCPServerManager.maximumStructuredResultBytes)
    #expect(oversized.hasSuffix("\n… (truncated)"))
}
