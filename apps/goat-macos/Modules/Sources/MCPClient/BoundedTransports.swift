import Darwin
import Foundation
import JUDAS
import Logging
import MCP
import System

enum BoundedTransportError: LocalizedError, Sendable, Equatable {
    case connectionClosed
    case inboundFrameTooLarge(Int)
    case invalidHTTPResponse
    case invalidSessionIdentifier
    case outboundFrameTooLarge(Int)
    case receiveQueueOverflow
    case unexpectedHTTPStatus(Int)
    case unsupportedContentType(String)

    var errorDescription: String? {
        switch self {
        case .connectionClosed:
            "MCP transport is closed"
        case .inboundFrameTooLarge(let limit):
            "MCP server response exceeds the \(limit)-byte frame limit"
        case .invalidHTTPResponse:
            "MCP server returned an invalid HTTP response"
        case .invalidSessionIdentifier:
            "MCP server returned an invalid session identifier"
        case .outboundFrameTooLarge(let limit):
            "MCP request exceeds the \(limit)-byte frame limit"
        case .receiveQueueOverflow:
            "MCP server produced messages faster than GOAT could safely consume them"
        case .unexpectedHTTPStatus(let status):
            "MCP server returned HTTP status \(status)"
        case .unsupportedContentType(let value):
            "MCP server returned unsupported content type \"\(value)\""
        }
    }
}

/// A newline-framed stdio transport which bounds both an unfinished frame and queued messages
/// before the SDK decoder sees them. It owns duplicates of the supplied pipe descriptors.
actor BoundedStdioTransport: Transport {
    static let maximumFrameBytes = 2 * 1024 * 1024
    static let maximumQueuedFrames = 1

    nonisolated let logger: Logger

    private let judas: Judas
    private let serverName: String?
    private let input: FileDescriptor
    private let output: FileDescriptor
    private let maximumFrameBytes: Int
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var readTask: Task<Void, Never>?
    private var isConnected = false
    private var descriptorsAreClosed = false
    private var writerIsActive = false
    private var writerWaiters: [(id: UUID, continuation: CheckedContinuation<Void, Swift.Error>)] = []

    init(
        input: FileDescriptor,
        output: FileDescriptor,
        serverName: String? = nil,
        judas: Judas = .shared,
        maximumFrameBytes: Int = maximumFrameBytes,
        maximumQueuedFrames: Int = maximumQueuedFrames
    ) throws {
        let ownedInput = fcntl(input.rawValue, F_DUPFD_CLOEXEC, 0)
        guard ownedInput >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EBADF) }
        let ownedOutput = fcntl(output.rawValue, F_DUPFD_CLOEXEC, 0)
        guard ownedOutput >= 0 else {
            close(ownedInput)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EBADF)
        }
        // Darwin pipes support a descriptor-local SIGPIPE suppression flag. This makes a closed
        // child stdin surface as EPIPE without changing signal policy for the rest of the app.
        guard fcntl(ownedOutput, F_SETNOSIGPIPE, 1) >= 0 else {
            let code = errno
            close(ownedInput)
            close(ownedOutput)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }

        self.judas = judas
        self.serverName = serverName
        self.input = FileDescriptor(rawValue: ownedInput)
        self.output = FileDescriptor(rawValue: ownedOutput)
        self.maximumFrameBytes = maximumFrameBytes
        self.logger = Logger(
            label: "goat.mcp.transport.stdio",
            factory: { _ in SwiftLogNoOpLogHandler() })

        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.messageStream = AsyncThrowingStream(
            bufferingPolicy: .bufferingOldest(maximumQueuedFrames)
        ) { continuation = $0 }
        self.messageContinuation = continuation
    }

    func connect() async throws {
        guard !isConnected, !descriptorsAreClosed else {
            throw BoundedTransportError.connectionClosed
        }
        try setNonBlocking(input)
        try setNonBlocking(output)
        isConnected = true
        readTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    func disconnect() async {
        guard !descriptorsAreClosed else { return }
        isConnected = false
        let task = readTask
        readTask = nil
        failWriterWaiters()
        closeDescriptors()
        messageContinuation.finish()
        task?.cancel()
        _ = await task?.value
    }

    func send(_ data: Data) async throws {
        try judas.authorizeProcess(name: serverName)
        try await acquireWriter()
        defer { releaseWriter() }
        guard isConnected, !descriptorsAreClosed else {
            throw BoundedTransportError.connectionClosed
        }
        guard data.count <= maximumFrameBytes else {
            throw BoundedTransportError.outboundFrameTooLarge(maximumFrameBytes)
        }

        var framed = data
        framed.append(0x0A)
        var offset = 0
        while offset < framed.count {
            try Task.checkCancellation()
            try judas.authorizeProcess(name: serverName)
            guard isConnected, !descriptorsAreClosed else {
                throw BoundedTransportError.connectionClosed
            }
            do {
                let written = try framed.withUnsafeBytes { bytes in
                    try output.write(UnsafeRawBufferPointer(rebasing: bytes[offset...]))
                }
                if written > 0 {
                    offset += written
                } else {
                    try await Task.sleep(for: .milliseconds(10))
                }
            } catch let error where MCP.MCPError.isResourceTemporarilyUnavailable(error) {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> { messageStream }

    private func readLoop() async {
        var readBuffer = [UInt8](repeating: 0, count: 8_192)
        var pending = Data()
        do {
            while isConnected, !Task.isCancelled {
                do {
                    let byteCount = try readBuffer.withUnsafeMutableBufferPointer { pointer in
                        try input.read(into: UnsafeMutableRawBufferPointer(pointer))
                    }
                    guard byteCount > 0 else { throw BoundedTransportError.connectionClosed }
                    pending.append(contentsOf: readBuffer[..<byteCount])

                    while let newline = pending.firstIndex(of: 0x0A) {
                        var frame = Data(pending[..<newline])
                        pending = Data(pending[pending.index(after: newline)...])
                        if frame.last == 0x0D { frame.removeLast() }
                        guard frame.count <= maximumFrameBytes else {
                            throw BoundedTransportError.inboundFrameTooLarge(maximumFrameBytes)
                        }
                        if !frame.isEmpty { try yield(frame) }
                    }
                    guard pending.count <= maximumFrameBytes else {
                        throw BoundedTransportError.inboundFrameTooLarge(maximumFrameBytes)
                    }
                } catch let error where MCP.MCPError.isResourceTemporarilyUnavailable(error) {
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            finish()
        } catch is CancellationError {
            finish()
        } catch {
            if isConnected {
                finish(throwing: error)
            } else {
                finish()
            }
        }
    }

    private func acquireWriter() async throws {
        try Task.checkCancellation()
        guard isConnected, !descriptorsAreClosed else {
            throw BoundedTransportError.connectionClosed
        }
        guard writerIsActive else {
            writerIsActive = true
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Swift.Error>) in
                guard !Task.isCancelled, isConnected, !descriptorsAreClosed else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                writerWaiters.append((id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWriterWaiter(id) }
        }
    }

    private func cancelWriterWaiter(_ id: UUID) {
        guard let index = writerWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = writerWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func releaseWriter() {
        guard writerIsActive else { return }
        guard !writerWaiters.isEmpty, isConnected, !descriptorsAreClosed else {
            writerIsActive = false
            return
        }
        let waiter = writerWaiters.removeFirst()
        waiter.continuation.resume()
    }

    private func failWriterWaiters() {
        writerIsActive = false
        let waiters = writerWaiters
        writerWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(throwing: BoundedTransportError.connectionClosed)
        }
    }

    private func yield(_ frame: Data) throws {
        switch messageContinuation.yield(frame) {
        case .enqueued:
            return
        case .dropped:
            throw BoundedTransportError.receiveQueueOverflow
        case .terminated:
            throw CancellationError()
        @unknown default:
            throw BoundedTransportError.receiveQueueOverflow
        }
    }

    private func finish(throwing error: Swift.Error? = nil) {
        isConnected = false
        failWriterWaiters()
        closeDescriptors()
        if let error {
            messageContinuation.finish(throwing: error)
        } else {
            messageContinuation.finish()
        }
    }

    private func closeDescriptors() {
        guard !descriptorsAreClosed else { return }
        descriptorsAreClosed = true
        try? input.close()
        try? output.close()
    }

    private func setNonBlocking(_ descriptor: FileDescriptor) throws {
        let flags = fcntl(descriptor.rawValue, F_GETFL)
        guard flags >= 0, fcntl(descriptor.rawValue, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

/// Streamable HTTP transport for GOAT's tool-only client. Every POST response is streamed through
/// a byte ceiling, including SSE responses, before it enters the SDK's JSON decoder.
actor BoundedHTTPTransport: Transport {
    static let maximumFrameBytes = 2 * 1024 * 1024
    static let maximumQueuedFrames = 1

    nonisolated let logger: Logger

    private let endpoint: URL
    private let headers: [String: String]
    private let session: JudasHTTPClient
    private let maximumFrameBytes: Int
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var isConnected = false
    private var isClosed = false
    private var sessionID: String?
    private var protocolVersion = Version.latest

    init(
        endpoint: URL,
        headers: [String: String],
        serverName: String? = nil,
        judas: Judas = .shared,
        maximumFrameBytes: Int = maximumFrameBytes,
        maximumQueuedFrames: Int = maximumQueuedFrames
    ) {
        self.endpoint = endpoint
        self.headers = headers
        self.maximumFrameBytes = maximumFrameBytes
        self.logger = Logger(
            label: "goat.mcp.transport.http",
            factory: { _ in SwiftLogNoOpLogHandler() })

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.httpMaximumConnectionsPerHost = MCPServerManager.maximumConcurrentConnections
        configuration.timeoutIntervalForRequest = 120
        self.session = JudasHTTPClient(
            origin: endpoint, source: .mcp, name: serverName, configuration: configuration, judas: judas)

        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.messageStream = AsyncThrowingStream(
            bufferingPolicy: .bufferingOldest(maximumQueuedFrames)
        ) { continuation = $0 }
        self.messageContinuation = continuation
    }

    func connect() async throws {
        guard !isClosed else { throw BoundedTransportError.connectionClosed }
        guard !isConnected else { return }
        isConnected = true
    }

    func disconnect() async {
        guard isConnected else { return }
        isConnected = false
        isClosed = true
        session.invalidateAndCancel()
        messageContinuation.finish()
    }

    func send(_ data: Data) async throws {
        guard isConnected else { throw BoundedTransportError.connectionClosed }
        guard data.count <= maximumFrameBytes else {
            throw BoundedTransportError.outboundFrameTooLarge(maximumFrameBytes)
        }

        let outbound = Self.outboundMessage(in: data)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = data
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id") }
        for field in headers.keys.sorted() {
            request.setValue(headers[field], forHTTPHeaderField: field)
        }

        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard isConnected else {
            bytes.task.cancel()
            throw BoundedTransportError.connectionClosed
        }
        guard let response = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw BoundedTransportError.invalidHTTPResponse
        }
        guard 200..<300 ~= response.statusCode else {
            bytes.task.cancel()
            throw BoundedTransportError.unexpectedHTTPStatus(response.statusCode)
        }
        try updateSessionID(from: response)

        if response.statusCode == 202 || response.statusCode == 204 {
            guard !outbound.expectsResponse else {
                throw BoundedTransportError.invalidHTTPResponse
            }
            return
        }

        let rawContentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        let contentType =
            rawContentType.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if contentType == "application/json" {
            let body = try await readJSONBody(bytes, response: response)
            guard !body.isEmpty || outbound.requestID == nil else {
                throw BoundedTransportError.invalidHTTPResponse
            }
            if !body.isEmpty {
                if let requestID = outbound.requestID,
                    !Self.isResponse(body, matching: requestID)
                {
                    throw BoundedTransportError.invalidHTTPResponse
                }
                if outbound.isInitialize { updateProtocolVersion(from: body) }
                try yield(body)
            }
        } else if contentType == "text/event-stream" {
            try await readEventStream(
                bytes, requestID: outbound.requestID, isInitialize: outbound.isInitialize)
        } else {
            throw BoundedTransportError.unsupportedContentType(String(contentType.prefix(256)))
        }
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> { messageStream }

    private func readJSONBody(
        _ bytes: URLSession.AsyncBytes, response: HTTPURLResponse
    ) async throws -> Data {
        if response.expectedContentLength > Int64(maximumFrameBytes) {
            bytes.task.cancel()
            throw BoundedTransportError.inboundFrameTooLarge(maximumFrameBytes)
        }
        var body = Data()
        if response.expectedContentLength > 0 {
            body.reserveCapacity(Int(min(response.expectedContentLength, Int64(maximumFrameBytes))))
        }
        for try await byte in bytes {
            try Task.checkCancellation()
            guard body.count < maximumFrameBytes else {
                bytes.task.cancel()
                throw BoundedTransportError.inboundFrameTooLarge(maximumFrameBytes)
            }
            body.append(byte)
        }
        return body
    }

    private func readEventStream(
        _ bytes: URLSession.AsyncBytes,
        requestID: Data?,
        isInitialize: Bool
    ) async throws {
        var decoder = BoundedSSEDecoder(maximumEventBytes: maximumFrameBytes)
        for try await byte in bytes {
            try Task.checkCancellation()
            if let event = try decoder.append(byte) {
                if isInitialize { updateProtocolVersion(from: event) }
                try yield(event)
                if let requestID, Self.isResponse(event, matching: requestID) {
                    bytes.task.cancel()
                    return
                }
            }
        }
        if let event = try decoder.finish() {
            if isInitialize { updateProtocolVersion(from: event) }
            try yield(event)
            if let requestID, Self.isResponse(event, matching: requestID) { return }
        }
        guard requestID == nil else { throw BoundedTransportError.invalidHTTPResponse }
    }

    private func updateSessionID(from response: HTTPURLResponse) throws {
        guard let candidate = response.value(forHTTPHeaderField: "MCP-Session-Id") else { return }
        guard
            1...1_024 ~= candidate.utf8.count,
            candidate.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E })
        else { throw BoundedTransportError.invalidSessionIdentifier }
        sessionID = candidate
    }

    private func updateProtocolVersion(from response: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
            let result = object["result"] as? [String: Any],
            let candidate = result["protocolVersion"] as? String,
            Version.supported.contains(candidate)
        else { return }
        protocolVersion = candidate
    }

    private func yield(_ frame: Data) throws {
        guard frame.count <= maximumFrameBytes else {
            throw BoundedTransportError.inboundFrameTooLarge(maximumFrameBytes)
        }
        switch messageContinuation.yield(frame) {
        case .enqueued:
            return
        case .dropped:
            isConnected = false
            isClosed = true
            session.invalidateAndCancel()
            messageContinuation.finish(throwing: BoundedTransportError.receiveQueueOverflow)
            throw BoundedTransportError.receiveQueueOverflow
        case .terminated:
            throw CancellationError()
        @unknown default:
            throw BoundedTransportError.receiveQueueOverflow
        }
    }

    private struct OutboundMessage {
        let requestID: Data?
        let expectsResponse: Bool
        let isInitialize: Bool
    }

    private static func outboundMessage(in data: Data) -> OutboundMessage {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return OutboundMessage(requestID: nil, expectsResponse: false, isInitialize: false)
        }
        let method = object["method"] as? String
        let identifier = jsonRPCID(in: data)
        let expectsResponse = method != nil && identifier != nil
        return OutboundMessage(
            requestID: expectsResponse ? identifier : nil,
            expectsResponse: expectsResponse,
            isInitialize: expectsResponse && method == "initialize")
    }

    private static func jsonRPCID(in data: Data) -> Data? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let identifier = object["id"], !(identifier is NSNull),
            JSONSerialization.isValidJSONObject(["id": identifier])
        else { return nil }
        return try? JSONSerialization.data(
            withJSONObject: ["id": identifier], options: [.sortedKeys])
    }

    private static func isResponse(_ data: Data, matching requestID: Data) -> Bool {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["method"] == nil,
            object.keys.contains("result") || object.keys.contains("error")
        else { return false }
        return jsonRPCID(in: data) == requestID
    }
}

/// Minimal SSE decoder with explicit line, event, and payload ceilings. It intentionally ignores
/// server-push metadata because GOAT uses POST responses only, but still charges it to the limit.
struct BoundedSSEDecoder: Sendable {
    private let maximumEventBytes: Int
    private var line = Data()
    private var eventData = Data()
    private var eventBytes = 0
    private var shouldIgnoreLeadingLF = false

    init(maximumEventBytes: Int) {
        self.maximumEventBytes = maximumEventBytes
    }

    mutating func append(_ byte: UInt8) throws -> Data? {
        if shouldIgnoreLeadingLF {
            shouldIgnoreLeadingLF = false
            if byte == 0x0A { return nil }
        }
        eventBytes += 1
        guard eventBytes <= maximumEventBytes else {
            throw BoundedTransportError.inboundFrameTooLarge(maximumEventBytes)
        }
        guard byte == 0x0A || byte == 0x0D else {
            line.append(byte)
            guard line.count <= maximumEventBytes else {
                throw BoundedTransportError.inboundFrameTooLarge(maximumEventBytes)
            }
            return nil
        }

        if byte == 0x0D { shouldIgnoreLeadingLF = true }
        return try processLine()
    }

    mutating func finish() throws -> Data? {
        if !line.isEmpty {
            if let event = try processLine() { return event }
        }
        return eventData.isEmpty ? nil : dispatchEvent()
    }

    private mutating func processLine() throws -> Data? {
        guard !line.isEmpty else { return dispatchEvent() }
        defer { line.removeAll(keepingCapacity: true) }
        guard line.first != 0x3A else { return nil }

        let colon = line.firstIndex(of: 0x3A)
        let fieldEnd = colon ?? line.endIndex
        guard line[..<fieldEnd].elementsEqual("data".utf8) else { return nil }
        var valueStart = colon.map { line.index(after: $0) } ?? line.endIndex
        if valueStart < line.endIndex, line[valueStart] == 0x20 {
            valueStart = line.index(after: valueStart)
        }
        if !eventData.isEmpty { eventData.append(0x0A) }
        eventData.append(contentsOf: line[valueStart...])
        guard eventData.count <= maximumEventBytes else {
            throw BoundedTransportError.inboundFrameTooLarge(maximumEventBytes)
        }
        return nil
    }

    private mutating func dispatchEvent() -> Data? {
        let result = eventData.isEmpty ? nil : eventData
        line = Data()
        eventData = Data()
        eventBytes = 0
        return result
    }
}
