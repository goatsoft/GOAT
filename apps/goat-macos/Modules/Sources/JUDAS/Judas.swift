import Foundation

public enum JudasMode: String, CaseIterable, Sendable {
    case configured, localNetworksOnly, blocked

    public static func restored(from value: String?) -> JudasMode {
        guard let value else { return .configured }
        if value == "loopbackOnly" { return .localNetworksOnly }
        return JudasMode(rawValue: value) ?? .blocked
    }
}

public enum JudasSource: String, Sendable {
    case engine, mcp, memory, preview, mcpProcess, hitch, policy, modelTool, extensionTool

    public var label: String {
        switch self {
        case .engine: "Engine"
        case .mcp: "MCP"
        case .memory: "Hindsight"
        case .preview: "Preview"
        case .mcpProcess: "MCP process"
        case .hitch: "Hitch"
        case .policy: "Policy"
        case .modelTool: "MCP tool"
        case .extensionTool: "Extension tool"
        }
    }
}

public enum JudasAction: String, Sendable {
    case allowed, denied, redirectBlocked, revoked, policyChanged, completed, failed, previewPolicy
}

public struct JudasEvent: Sendable {
    public let sequence: UInt64
    public let date: Date
    public let source: JudasSource
    public let action: JudasAction
    public let destination: String
}

public enum JudasError: LocalizedError, Sendable {
    case denied
    public var errorDescription: String? { "JUDAS blocked this connection. Review Settings > JUDAS." }
}

/// Host-owned network policy. The lock protects mode, registrations and the bounded audit queue.
/// Cancellation callbacks run outside the lock. Bundled native code is trusted, not sandboxed
/// by this API; ADR-0045 defines that boundary and the reason for unchecked Sendable.
public final class Judas: @unchecked Sendable {
    public static let shared = Judas()
    private let lock = NSLock()
    private var currentMode: JudasMode
    private var cancellations: [UUID: @Sendable () -> Void] = [:]
    private var events: [JudasEvent] = []
    private var eventObservers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var sequence: UInt64 = 0
    private var dropped = 0
    private let capacity: Int

    public init(mode: JudasMode = .configured, capacity: Int = 2048) {
        currentMode = mode
        self.capacity = max(1, capacity)
    }

    public var mode: JudasMode { lock.withLock { currentMode } }

    public func setMode(_ mode: JudasMode) {
        let callbacks: [@Sendable () -> Void] = lock.withLock {
            guard currentMode != mode else { return [] }
            currentMode = mode
            append(.policy, .policyChanged, mode.rawValue)
            let callbacks = Array(cancellations.values)
            cancellations.removeAll()
            if !callbacks.isEmpty { append(.policy, .revoked, "managed connections") }
            return callbacks
        }
        for cancel in callbacks { cancel() }
    }

    @discardableResult
    public func registerCancellation(_ cancel: @escaping @Sendable () -> Void) -> UUID {
        lock.withLock {
            let id = UUID()
            cancellations[id] = cancel
            return id
        }
    }

    public func unregister(_ id: UUID) { _ = lock.withLock { cancellations.removeValue(forKey: id) } }

    public func authorize(_ url: URL?, configuredOrigin: URL?, source: JudasSource, name: String? = nil) throws {
        try lock.withLock {
            let allowed =
                Self.origin(url) != nil && Self.origin(url) == Self.origin(configuredOrigin)
                && permits(url)
            append(source, allowed ? .allowed : .denied, Self.namedDestination(url, name: name))
            guard allowed else { throw JudasError.denied }
        }
    }

    /// Native commands always retain the Pen sandbox. Network access is separately approved
    /// by the owner and available only in configured-connections mode.
    public func authorizePenCommand(network: Bool) throws {
        try lock.withLock {
            let allowed = !network || currentMode == .configured
            append(
                .extensionTool, allowed ? .allowed : .denied,
                network ? "Herder command: requested network access" : "Herder command: network blocked")
            guard allowed else { throw JudasError.denied }
        }
    }

    public func authorizeProcess(name: String? = nil) throws {
        try lock.withLock {
            let allowed = currentMode == .configured
            append(
                .mcpProcess, allowed ? .allowed : .denied,
                "\(Self.safeLabel(name ?? "Configured MCP server")) · subprocess (external authority)")
            guard allowed else { throw JudasError.denied }
        }
    }

    /// Preview navigation uses the same mode as HTTP. WebKit subresource enforcement is done
    /// by content rules, not by navigation callbacks; no per-resource audit is claimed.
    public func authorizePreview(_ url: URL, offGrid: Bool) -> Bool {
        lock.withLock {
            let allowed =
                Self.origin(url) != nil && permits(url)
                && ((!offGrid && currentMode == .configured) || Self.isLoopback(url))
            append(.preview, allowed ? .allowed : .denied, Self.destination(url))
            return allowed
        }
    }

    public func announcePolicy() {
        lock.withLock { append(.policy, .policyChanged, currentMode.rawValue) }
    }

    public func recordPreviewPolicy(offGrid: Bool, bundledScripts: Bool) {
        lock.withLock {
            append(
                .preview, .previewPolicy,
                "\(currentMode.rawValue); offGrid=\(offGrid); bundledScripts=\(bundledScripts)")
        }
    }

    public func recordTool(_ action: JudasAction, server: String, tool: String, isExtension: Bool = false) {
        lock.withLock {
            append(
                isExtension ? .extensionTool : .modelTool, action,
                "\(Self.safeLabel(server)) · \(Self.safeLabel(tool))")
        }
    }

    private static func safeLabel(_ value: String) -> String {
        // Display names are metadata, never arguments. Reject URL-like or control-bearing values
        // instead of allowing labels to smuggle credentials or extra log lines into the audit.
        let permitted = CharacterSet.letters.union(.decimalDigits).union(.nonBaseCharacters)
            .union(CharacterSet(charactersIn: " _-.()/"))
        guard !value.isEmpty, value.unicodeScalars.count <= 128,
            value.unicodeScalars.allSatisfy({ permitted.contains($0) })
        else { return "redacted name" }
        return value
    }

    private static func namedDestination(_ url: URL?, name: String?) -> String {
        guard let name, !name.isEmpty else { return destination(url) }
        let label = safeLabel(name)
        return url == nil ? label : "\(label) · \(destination(url))"
    }

    public func recordHitch(_ action: JudasAction, operation: String) {
        let known = ["status", "pens.list", "chats.list", "chats.create", "turn.send", "turn.read", "turn.cancel"]
        lock.withLock { append(.hitch, action, known.contains(operation) ? operation : "redacted") }
    }

    public static func previewCSP(mode: JudasMode, offGrid: Bool, bundledScripts: Bool) -> String {
        guard mode != .configured || offGrid else { return "" }
        let local =
            mode == .blocked
            ? ""
            : " http://localhost:* https://localhost:* http://127.0.0.1:* https://127.0.0.1:* http://[::1]:* https://[::1]:*"
        let script = bundledScripts ? "'unsafe-inline' file:" : "'none'"
        let policy =
            "default-src 'none'; script-src \(script); style-src 'unsafe-inline' file:; img-src data: blob: file:\(local); font-src data: file:; media-src data: blob: file:\(local); connect-src 'none'; frame-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"
        return "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"
    }

    public func record(_ source: JudasSource, _ action: JudasAction, url: URL? = nil, name: String? = nil) {
        lock.withLock {
            append(source, action, Self.namedDestination(url, name: name ?? (url == nil ? source.label : nil)))
        }
    }

    /// Coalesced wakeups, not audit storage. The bounded queue remains the source of events.
    /// Consumers sleep until activity arrives, and unregister when their task is cancelled.
    public func eventNotifications() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            self?.removeEventObserver(id)
        }
        lock.withLock {
            eventObservers[id] = continuation
            if !events.isEmpty { continuation.yield(()) }
        }
        return stream
    }

    private func removeEventObserver(_ id: UUID) {
        lock.withLock { _ = eventObservers.removeValue(forKey: id) }
    }

    public func drain() -> (events: [JudasEvent], dropped: Int) {
        lock.withLock {
            let result = (events, dropped)
            events.removeAll(keepingCapacity: true)
            dropped = 0
            return result
        }
    }

    private func permits(_ url: URL?) -> Bool {
        switch currentMode {
        case .configured: true
        case .localNetworksOnly: url.map(LocalNetworkAddress.contains) ?? false
        case .blocked: false
        }
    }

    private func append(_ source: JudasSource, _ action: JudasAction, _ destination: String) {
        sequence &+= 1
        if events.count == capacity {
            events.removeFirst()
            dropped += 1
        }
        events.append(
            JudasEvent(sequence: sequence, date: Date(), source: source, action: action, destination: destination))
        for observer in eventObservers.values { observer.yield(()) }
    }

    private static func origin(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = url.host?.lowercased(), !host.isEmpty,
            url.user == nil, url.password == nil, url.fragment == nil,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.port == nil || (1...65535).contains(components.port ?? 0)
        else { return nil }
        return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }

    private static func destination(_ url: URL?) -> String {
        // Never retain userinfo, paths, queries, fragments, headers, bodies or error text.
        guard let origin = origin(url), origin.utf8.count <= 256,
            !origin.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
        else { return "redacted" }
        return origin
    }

    public static func isLoopback(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        // Deliberately accept only these literal addresses and localhost, never DNS answers.
        return ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)
    }

    public static func previewRules(mode: JudasMode, offGrid: Bool) -> String? {
        guard mode != .configured || offGrid else { return nil }
        var rules: [[String: [String: String]]] = [
            ["trigger": ["url-filter": ".*"], "action": ["type": "block"]]
        ]
        // WebKit's content-rule regex dialect does not support alternation.
        for scheme in ["file", "about", "data", "blob"] {
            rules.append(["trigger": ["url-filter": "^\(scheme):"], "action": ["type": "ignore-previous-rules"]])
        }
        if mode != .blocked {
            for host in [#"127\.0\.0\.1"#, "localhost", #"\[::1\]"#] {
                rules.append([
                    "trigger": ["url-filter": "^https?://\(host)[:/].*"],
                    "action": ["type": "ignore-previous-rules"],
                ])
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"# }
        return text
    }
}

/// URLSession invokes delegates concurrently. Immutable fields and Foundation's thread-safe
/// session are the only state here; JUDAS owns synchronized policy state (ADR-0045).
public final class JudasHTTPClient: @unchecked Sendable {
    private let session: URLSession
    private let judas: Judas
    private let origin: URL
    private let source: JudasSource
    private let name: String?
    private let cancellation: UUID

    public init(
        origin: URL, source: JudasSource, name: String? = nil, configuration: URLSessionConfiguration = .ephemeral,
        judas: Judas = .shared
    ) {
        self.origin = origin
        self.source = source
        self.name = name
        self.judas = judas
        let isolated = configuration.copy() as? URLSessionConfiguration ?? .ephemeral
        isolated.urlCache = nil
        isolated.httpCookieStorage = nil
        isolated.urlCredentialStorage = nil
        isolated.httpShouldSetCookies = false
        isolated.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(
            configuration: isolated,
            delegate: JudasRedirectDelegate(judas: judas, source: source, name: name), delegateQueue: nil)
        self.session = session
        cancellation = judas.registerCancellation {
            judas.record(source, .revoked, url: origin, name: name)
            session.invalidateAndCancel()
        }
    }

    deinit {
        session.invalidateAndCancel()
        judas.unregister(cancellation)
    }

    public func invalidateAndCancel() {
        session.invalidateAndCancel()
        judas.unregister(cancellation)
    }

    public func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try judas.authorize(request.url, configuredOrigin: origin, source: source, name: name)
        return try await session.bytes(for: request)
    }
}

/// Immutable delegate; concurrent callbacks only access the locked JUDAS service (ADR-0045).
private final class JudasRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let judas: Judas
    let source: JudasSource
    let name: String?
    init(judas: Judas, source: JudasSource, name: String?) {
        self.judas = judas
        self.source = source
        self.name = name
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        judas.record(source, .redirectBlocked, url: request.url, name: name)
        return nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        judas.record(source, error == nil ? .completed : .failed, url: task.originalRequest?.url, name: name)
    }
}

/// A registration follows its owner's lifetime, including early startup failures.
public final class JudasRegistration: Sendable {
    private let judas: Judas
    private let id: UUID
    public init(judas: Judas = .shared, cancel: @escaping @Sendable () -> Void) {
        self.judas = judas
        id = judas.registerCancellation(cancel)
    }
    deinit { judas.unregister(id) }
}
