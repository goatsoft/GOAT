import Foundation
import Tools

/// A host-selected, immutable scope. Providers receive data, never a mutable app model.
public struct ExtensionContext: Sendable {
    public let view: ExtensionView
    public let turnID: UUID
    public init(view: ExtensionView, turnID: UUID) {
        self.view = view
        self.turnID = turnID
    }
}

public struct ExtensionManifest: Sendable {
    public let id: ExtensionID
    public let version: String
    public let apiVersion: Int
    public let dependencies: Set<ExtensionID>
    public init(id: String, version: String, apiVersion: Int = 1, dependencies: Set<ExtensionID> = []) {
        self.id = ExtensionID(rawValue: id)
        self.version = version
        self.apiVersion = apiVersion
        self.dependencies = dependencies
    }
}

public enum TurnOutcome: String, Sendable { case completed, cancelled, failed }

public struct PersistedTurn: Sendable {
    public struct Message: Sendable {
        public let role: String
        public let text: String
        public init(role: String, text: String) {
            self.role = role
            self.text = text
        }
    }
    public let context: ExtensionContext
    public let title: String
    public let createdAt: Date
    public let commandMessageID: UUID?
    public let isHandoff: Bool
    public let messages: [Message]
    public init(
        context: ExtensionContext, title: String, createdAt: Date,
        commandMessageID: UUID? = nil, isHandoff: Bool = false, messages: [Message]
    ) {
        self.context = context
        self.title = title
        self.createdAt = createdAt
        self.commandMessageID = commandMessageID
        self.isHandoff = isHandoff
        self.messages = messages
    }
}

public struct ObserverReceipt: Sendable {
    public let message: String
    public let isError: Bool
    public init(message: String, isError: Bool = false) {
        self.message = message
        self.isError = isError
    }
}

public protocol PromptProvider: Sendable {
    func prompt(for context: ExtensionContext) async throws -> String
}

/// The host owns authorization. A provider cannot authorize itself or replace host guards.
public protocol ModelToolProvider: Sendable {
    func tools(for context: ExtensionContext) async throws -> [ToolSchema]
    func invoke(_ call: ToolCallRequest, context: ExtensionContext) async throws -> ToolResult
}

public protocol TurnObserver: Sendable {
    func turnWillPrepare(_ context: ExtensionContext) async throws
    func turnDidPersist(_ turn: PersistedTurn) async throws -> ObserverReceipt?
    func turnDidEnd(_ context: ExtensionContext, outcome: TurnOutcome) async throws
}

extension TurnObserver {
    public func turnWillPrepare(_ context: ExtensionContext) async throws {}
    public func turnDidPersist(_ turn: PersistedTurn) async throws -> ObserverReceipt? { nil }
    public func turnDidEnd(_ context: ExtensionContext, outcome: TurnOutcome) async throws {}
}

/// Application services are callable by local clients, never advertised as model tools.
public protocol ServiceProvider: Sendable {
    func invoke(operation: String, argumentsJSON: String) async throws -> String
}

public struct ExtensionContributions: Sendable {
    public var contextProviders: [any ContextProvider]
    public var prompts: [any PromptProvider]
    public var tools: [any ModelToolProvider]
    public var observers: [any TurnObserver]
    public var skills: [any SkillProvider]
    public var services: [String: any ServiceProvider]
    public init(
        contextProviders: [any ContextProvider] = [], prompts: [any PromptProvider] = [],
        tools: [any ModelToolProvider] = [],
        observers: [any TurnObserver] = [], skills: [any SkillProvider] = [],
        services: [String: any ServiceProvider] = [:]
    ) {
        self.contextProviders = contextProviders
        self.prompts = prompts
        self.tools = tools
        self.observers = observers
        self.skills = skills
        self.services = services
    }
}

/// Bundled Swift code only. Construct providers without starting background work; activation
/// validates and publishes all contributions atomically. Work belongs to runtime calls.
public protocol Extension: Sendable {
    var manifest: ExtensionManifest { get }
    var contributions: ExtensionContributions { get }
}

public struct ToolHandle: Sendable, Equatable {
    public let registration: Registration
    public let turnID: UUID
    public let providerIndex: Int
    public let name: String
}

public struct ResolvedTool: Sendable {
    public let schema: ToolSchema
    public let handle: ToolHandle
}

public struct TurnSnapshot: Sendable {
    public let context: ExtensionContext
    public let registrations: [Registration]
    public let contextEntries: [ContextEntry]
    public let promptSections: [String]
    public let tools: [ResolvedTool]
}

public struct ExtensionDiagnostic: Sendable, Equatable {
    public let extensionID: ExtensionID
    public let code: String
}

public enum CapabilityError: Error, Sendable, Equatable {
    case invalidManifest, incompatibleAPI, missingDependency, duplicateExtension, duplicateService
    case capacity, timedOut, revoked, invalidPayload, argumentsTooLarge, unavailable, unauthorized
}

public protocol ExtensionClock: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct RuntimeClock: ExtensionClock {
    public init() {}
    public func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

/// A one-shot cancellation race. Unlike a task group, the waiter need not await an
/// uncooperative provider after its deadline. Such an extension is quarantined by the runtime.
/// All mutable state is protected by `lock`; cancellation and resumption happen after unlocking.
final class Invocation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var result: Result<Value, any Error>?
    private var tasks: [Task<Void, Never>] = []

    func finish(_ result: Result<Value, any Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        let tasks = self.tasks
        self.tasks = []
        lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }

    private func add(_ task: Task<Void, Never>) {
        lock.lock()
        if result != nil {
            lock.unlock()
            task.cancel()
        } else {
            tasks.append(task)
            lock.unlock()
        }
    }

    private func attach(_ continuation: CheckedContinuation<Value, any Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func run(
        clock: any ExtensionClock, timeout: Duration,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                attach(continuation)
                add(
                    Task.detached {
                        do {
                            try Task.checkCancellation()
                            self.finish(.success(try await operation()))
                        } catch { self.finish(.failure(error)) }
                    })
                add(
                    Task.detached {
                        do {
                            try await clock.sleep(for: timeout)
                            try Task.checkCancellation()
                            self.finish(.failure(CapabilityError.timedOut))
                        } catch {
                            // Completion or caller cancellation stops the deadline task.
                        }
                    })
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }
}

public struct ContextEntry: Sendable {
    public let identifier: String
    public let title: String
    public let summary: String
    public init(identifier: String, title: String, summary: String) {
        self.identifier = identifier
        self.title = title
        self.summary = summary
    }
}

public protocol ContextProvider: Sendable {
    func contextEntries(for context: ExtensionContext) async throws -> [ContextEntry]
}

extension CapabilityError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidManifest: "The extension manifest is invalid."
        case .incompatibleAPI: "This extension requires an unsupported GOATed API version."
        case .missingDependency: "A required extension is unavailable."
        case .duplicateExtension: "This extension is already active in that scope."
        case .duplicateService: "Another extension already provides that service."
        case .capacity: "The extension operation exceeds the supported capacity."
        case .timedOut: "The extension exceeded its deadline and was disabled. Restart GOAT to retry."
        case .revoked: "This extension or turn is no longer active."
        case .invalidPayload: "The extension input or result does not match its supported contract."
        case .argumentsTooLarge:
            "Tool arguments exceed 64 KiB. Split the work into smaller calls or focused edits; do not resend the same oversized arguments."
        case .unavailable: "The extension capability is unavailable. Check extension status in Settings."
        case .unauthorized: "The host did not authorize this extension operation."
        }
    }
}
