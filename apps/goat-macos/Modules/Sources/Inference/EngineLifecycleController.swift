import Foundation

/// Probes one explicit engine configuration without mutating the live inference engine.
/// Keeping probes separate prevents discovery and Settings health checks from redirecting
/// an in-flight or newly selected engine while their network requests are suspended.
public protocol EngineProbe: Sendable {
    func probe(_ config: EngineConfig) async -> EngineHealth
}

/// The production health probe for an OpenAI-compatible engine.
public struct OpenAICompatEngineProbe: EngineProbe {
    public init() {}

    public func probe(_ config: EngineConfig) async -> EngineHealth {
        let probe = OpenAICompatEngine(config: config)
        return await probe.health()
    }
}

/// Serializes the intent to select or refresh an engine while allowing network probes to overlap.
/// Actor reentrancy means an older probe can finish after a newer one. Each operation therefore
/// receives a revision, and only the newest revision may produce a resolution for the caller.
public actor EngineLifecycleController {
    public struct Operation: Sendable, Equatable {
        public let revision: UInt64

        fileprivate init(revision: UInt64) {
            self.revision = revision
        }
    }

    public struct Target: Sendable, Equatable {
        public let profileID: String
        public let config: EngineConfig

        public init(profileID: String, config: EngineConfig) {
            self.profileID = profileID
            self.config = config
        }
    }

    public struct Resolution: Sendable, Equatable {
        public let revision: UInt64
        public let target: Target
        public let health: EngineHealth

        fileprivate init(revision: UInt64, target: Target, health: EngineHealth) {
            self.revision = revision
            self.target = target
            self.health = health
        }
    }

    private let engineProbe: any EngineProbe
    private var latestRevision: UInt64 = 0
    private var latestIntentRevision: UInt64 = 0

    public init(probe: any EngineProbe = OpenAICompatEngineProbe()) {
        engineProbe = probe
    }

    /// Begin one logical lifecycle operation. Discovery reuses this token across all candidate
    /// probes, so a superseded discovery cannot reclaim ownership by starting its next probe.
    public func begin() -> Operation {
        latestIntentRevision &+= 1
        return Operation(revision: advanceRevision())
    }

    /// Begin an operation for a caller-owned, monotonically increasing intent. An older caller
    /// can reach this actor after a newer one; rejecting its lower intent prevents it from
    /// superseding the operation that represents the latest UI state.
    public func begin(intentRevision: UInt64) -> Operation? {
        guard intentRevision > latestIntentRevision else { return nil }
        latestIntentRevision = intentRevision
        return Operation(revision: advanceRevision())
    }

    /// Probe one target as part of `operation`. Stale operations are rejected both before and
    /// after the network suspension point.
    public func probe(_ target: Target, for operation: Operation) async -> Resolution? {
        guard operation.revision == latestRevision, !Task.isCancelled else { return nil }
        let health = await engineProbe.probe(target.config)
        guard !Task.isCancelled, operation.revision == latestRevision else { return nil }
        return Resolution(revision: operation.revision, target: target, health: health)
    }

    /// Probe `target`, returning it only if no newer lifecycle operation superseded it.
    /// The caller should update the live engine from the returned target, then call
    /// `isCurrent(_:)` after that await before publishing health or model state.
    public func resolve(_ target: Target) async -> Resolution? {
        let operation = begin()
        return await probe(target, for: operation)
    }

    /// Supersede any probe currently in flight. Its eventual result will be discarded.
    @discardableResult
    public func invalidate() -> UInt64 {
        advanceRevision()
    }

    /// Revalidate a resolution after the caller crosses another actor boundary, such as
    /// updating the live engine actor, and before it publishes observable UI state.
    public func isCurrent(_ resolution: Resolution) -> Bool {
        resolution.revision == latestRevision
    }

    public func isCurrent(_ operation: Operation) -> Bool {
        operation.revision == latestRevision
    }

    public var revision: UInt64 { latestRevision }

    @discardableResult
    private func advanceRevision() -> UInt64 {
        // Wrapping keeps this total and avoids a release-only overflow trap. Reaching the
        // boundary would require centuries of probes at UI interaction rates.
        latestRevision &+= 1
        return latestRevision
    }
}
