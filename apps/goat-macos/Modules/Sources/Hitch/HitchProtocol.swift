import Foundation
import GOATed

public struct HitchRequest: Codable, Sendable, Equatable {
    public let version: Int
    public let id: UUID
    public let operation: String
    public let arguments: [String: String]
    public init(id: UUID = UUID(), operation: String, arguments: [String: String] = [:], version: Int = 1) {
        self.version = version
        self.id = id
        self.operation = operation
        self.arguments = arguments
    }
}

public struct HitchReply: Codable, Sendable {
    public let version: Int
    public let id: UUID
    public let result: String?
    public let error: String?
    public init(id: UUID, result: String? = nil, error: String? = nil) {
        version = 1
        self.id = id
        self.result = result
        self.error = error
    }
}

public enum HitchError: String, Error, Sendable {
    case disabled, unavailable, oversized, busy, unauthorized, timeout
    case unsafeEndpoint = "unsafe_endpoint"
    case protocolError = "protocol_error"
    case invalidArguments = "invalid_arguments"
    case idConflict = "id_conflict"
    case historyFull = "history_full"
}

public struct HitchExtension: Extension {
    public let manifest = ExtensionManifest(id: "goat.hitch", version: "0.1.0")
    public let contributions: ExtensionContributions
    public init(service: any ServiceProvider) {
        contributions = ExtensionContributions(services: ["goat.hitch": service])
    }
}

/// Exact request replay for one enabled session. A full ledger rejects new mutations instead of
/// silently evicting their IDs and executing a retry twice. Disable/re-enable starts a new session.
public actor HitchDispatcher {
    public typealias Handler = @Sendable (HitchRequest) async throws -> String
    private let handler: Handler
    private let capacity: Int
    private var ledger: [UUID: (HitchRequest, Task<HitchReply, Never>)] = [:]
    private var enabled = true
    public init(capacity: Int = 1024, handler: @escaping Handler) {
        self.capacity = capacity
        self.handler = handler
    }
    public func stop() {
        enabled = false
        ledger.values.forEach { $0.1.cancel() }
        ledger.removeAll()
    }
    public func dispatch(_ request: HitchRequest) async -> HitchReply {
        guard enabled else { return HitchReply(id: request.id, error: "disabled") }
        guard request.version == 1 else { return HitchReply(id: request.id, error: "unsupported_version") }
        let fields: [String: Set<String>] = [
            "status": [], "pens.list": ["cursor"], "chats.list": ["pen", "cursor"], "chats.create": ["pen"],
            "turn.send": ["chat", "text"], "turn.read": ["turn"], "turn.cancel": ["turn"],
        ]
        guard let allowed = fields[request.operation], Set(request.arguments.keys).isSubset(of: allowed),
            request.arguments.values.allSatisfy({ $0.utf8.count <= 32_768 })
        else {
            return HitchReply(id: request.id, error: "invalid_arguments")
        }
        let mutating = ["chats.create", "turn.send", "turn.cancel"].contains(request.operation)
        if let (original, task) = ledger[request.id] {
            guard original == request else { return HitchReply(id: request.id, error: "id_conflict") }
            return await task.value
        }
        let required: [String: Set<String>] = [
            "turn.send": ["chat", "text"], "turn.read": ["turn"], "turn.cancel": ["turn"],
        ]
        guard (required[request.operation] ?? []).isSubset(of: Set(request.arguments.keys)),
            ["chat", "pen", "turn"].allSatisfy({ key in
                request.arguments[key].map { UUID(uuidString: $0) != nil } ?? true
            }),
            request.arguments["text"].map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true
        else { return HitchReply(id: request.id, error: "invalid_arguments") }
        guard !mutating || ledger.count < capacity else {
            return HitchReply(id: request.id, error: "history_full")
        }
        let handler = self.handler
        let task = Task<HitchReply, Never> {
            do {
                try Task.checkCancellation()
                let result = try await handler(request)
                guard result.utf8.count <= 262_144 else { return HitchReply(id: request.id, error: "oversized") }
                return HitchReply(id: request.id, result: result)
            } catch let error as HitchError {
                return HitchReply(id: request.id, error: error.rawValue)
            } catch is CancellationError { return HitchReply(id: request.id, error: "cancelled") } catch {
                return HitchReply(id: request.id, error: "operation_failed")
            }
        }
        if mutating { ledger[request.id] = (request, task) }
        let reply = await task.value
        guard enabled else { return HitchReply(id: request.id, error: "disabled") }
        return reply
    }
}
