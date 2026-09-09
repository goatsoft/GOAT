import Darwin
import Foundation
import Testing

@testable import Hitch

private actor Counter {
    var count = 0
    func increment() -> String {
        count += 1
        return "ok"
    }
}

@Test func concurrentMutationRetriesExecuteOnceAndConflictsFail() async {
    let counter = Counter()
    let dispatcher = HitchDispatcher { _ in await counter.increment() }
    let request = HitchRequest(operation: "chats.create")
    let tasks = (0..<20).map { _ in Task { await dispatcher.dispatch(request) } }
    for task in tasks { #expect(await task.value.result == "ok") }
    #expect(await counter.count == 1)
    let conflict = await dispatcher.dispatch(HitchRequest(id: request.id, operation: "turn.cancel"))
    #expect(conflict.error == "id_conflict")
}

@Test func fullLedgerRejectsNewMutationsButAllowsReadsAndRetries() async {
    let dispatcher = HitchDispatcher(capacity: 1) { _ in "ok" }
    let request = HitchRequest(operation: "chats.create")
    #expect(await dispatcher.dispatch(request).result == "ok")
    #expect(await dispatcher.dispatch(HitchRequest(operation: "chats.create")).error == "history_full")
    #expect(await dispatcher.dispatch(request).result == "ok")
    #expect(await dispatcher.dispatch(HitchRequest(operation: "status")).result == "ok")
}

@Test func invalidProtocolNeverReachesHandlerAndStopRevokesDispatcher() async {
    let counter = Counter()
    let dispatcher = HitchDispatcher { _ in await counter.increment() }
    #expect(
        await dispatcher.dispatch(HitchRequest(operation: "status", version: 2)).error == "unsupported_version")
    #expect(await dispatcher.dispatch(HitchRequest(operation: "shell.exec")).error == "invalid_arguments")
    #expect(
        await dispatcher.dispatch(HitchRequest(operation: "status", arguments: ["secret": "x"])).error
            == "invalid_arguments")
    await dispatcher.stop()
    #expect(await dispatcher.dispatch(HitchRequest(operation: "status")).error == "disabled")
    #expect(await counter.count == 0)
}

@Test func localSocketRoundTripPermissionsExclusivityAndShutdown() async throws {
    let directory = "/private/tmp/gc-" + UUID().uuidString
    let path = directory + "/goat.sock"
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let server = HitchServer()
    let dispatcher = HitchDispatcher { request in
        request.operation == "pens.list" ? String(repeating: "\u{0}", count: 250_000) : "local only"
    }
    try await server.start(path: path, dispatcher: dispatcher)
    let reply = try await Task.detached {
        try LocalSocket.request(HitchRequest(operation: "status"), path: path)
    }.value
    #expect(reply.result == "local only")
    let oversized = try await Task.detached {
        try LocalSocket.request(HitchRequest(operation: "pens.list"), path: path)
    }.value
    #expect(oversized.error == "oversized")
    try LocalSocket.inspect(directory, type: S_IFDIR, mode: 0o700)
    try LocalSocket.inspect(path, type: S_IFSOCK, mode: 0o600)
    let second = HitchServer()
    await #expect(throws: HitchError.busy) { try await second.start(path: path, dispatcher: dispatcher) }
    await server.stop()
    #expect(!FileManager.default.fileExists(atPath: path))
    #expect(throws: (any Error).self) {
        _ = try LocalSocket.request(HitchRequest(operation: "status"), path: path)
    }
    try await second.start(path: path, dispatcher: HitchDispatcher { _ in "restarted" })
    await second.stop()
}

@Test func socketRejectsSymlinksAndPublicDirectories() async throws {
    let directory = "/private/tmp/gc-" + UUID().uuidString
    try FileManager.default.createDirectory(
        atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let server = HitchServer()
    let dispatcher = HitchDispatcher { _ in "bad" }
    await #expect(throws: HitchError.unsafeEndpoint) {
        try await server.start(path: directory + "/goat.sock", dispatcher: dispatcher)
    }
    chmod(directory, 0o700)
    try FileManager.default.createSymbolicLink(
        atPath: directory + "/goat.sock", withDestinationPath: "/private/tmp/nowhere")
    await #expect(throws: HitchError.unsafeEndpoint) {
        try await server.start(path: directory + "/goat.sock", dispatcher: dispatcher)
    }
}

@Test func invalidRequiredArgumentsNeverDispatch() async {
    let counter = Counter()
    let dispatcher = HitchDispatcher { _ in await counter.increment() }
    for request in [
        HitchRequest(operation: "turn.send"),
        HitchRequest(operation: "turn.cancel", arguments: ["turn": "not-a-uuid"]),
        HitchRequest(operation: "turn.send", arguments: ["chat": UUID().uuidString, "text": "   "]),
        HitchRequest(operation: "chats.list", arguments: ["pen": "wrong"]),
    ] { #expect(await dispatcher.dispatch(request).error == "invalid_arguments") }
    #expect(await counter.count == 0)
}

@Test func framingRejectsOversizeAndExtraMessages() throws {
    var fds: [Int32] = [-1, -1]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    defer {
        close(fds[0])
        close(fds[1])
    }
    try LocalSocket.configure(fds[0])
    try LocalSocket.configure(fds[1])
    let bytes = Data("one\ntwo\n".utf8)
    _ = bytes.withUnsafeBytes { Darwin.write(fds[0], $0.baseAddress, $0.count) }
    #expect(throws: HitchError.protocolError) { _ = try LocalSocket.readFrame(fds[1], maximum: 100) }
    let tooBig = Data(repeating: 65, count: 9)
    _ = tooBig.withUnsafeBytes { Darwin.write(fds[0], $0.baseAddress, $0.count) }
    #expect(throws: HitchError.oversized) { _ = try LocalSocket.readFrame(fds[1], maximum: 8) }
}

@Test func shippedCLIConnectsToTheLocalProtocol() async throws {
    let directory = "/private/tmp/gcli-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let server = HitchServer()
    try await server.start(
        path: directory + "/goat.sock", dispatcher: HitchDispatcher { _ in "{\"state\":\"ready\"}" })
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    #if DEBUG
    let configuration = "debug"
    #else
    let configuration = "release"
    #endif
    let executable = package.appendingPathComponent(".build/\(configuration)/goat")
    let result = try await Task.detached {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = ["status", "--socket", directory + "/goat.sock"]
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }.value
    await server.stop()
    #expect(result.0 == 0)
    let reply = try JSONDecoder().decode(HitchReply.self, from: result.1)
    #expect(reply.result == "{\"state\":\"ready\"}")
}

@Test func asynchronousSocketIOHandlesFullFramesAndShutdown() async throws {
    var fds: [Int32] = [-1, -1]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    let reader = fds[0]
    let writer = fds[1]
    defer {
        close(reader)
        close(writer)
    }
    try LocalSocket.configure(reader)
    try LocalSocket.configure(writer)
    let payload = Data(repeating: 65, count: 65_536)
    async let received = LocalSocket.readFrameAsync(reader, maximum: payload.count)
    try await LocalSocket.writeFrameAsync(payload, fd: writer)
    #expect(try await received == payload)
    let waiting = Task { try await LocalSocket.readFrameAsync(reader, maximum: 10) }
    shutdown(reader, SHUT_RDWR)
    do {
        _ = try await waiting.value
        Issue.record("Shutdown must interrupt a pending socket read")
    } catch {}
}
