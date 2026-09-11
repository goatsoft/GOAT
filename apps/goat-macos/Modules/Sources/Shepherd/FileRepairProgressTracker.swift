import Tools

public struct FileRepairProgressTracker: Sendable, Equatable {
    public struct Key: Hashable, Sendable {
        public let workspaceIdentity: String
        public let relativePath: String
        public init(workspaceIdentity: String, relativePath: String) {
            self.workspaceIdentity = workspaceIdentity
            self.relativePath = relativePath
        }
    }

    private struct State: Sendable, Equatable {
        var observations: [FileOperationObservation] = []
        var recoveryRequired = false
        var readDigest: String?
        var repeatedFailureSignature: String?
        var repeatedFailureCount = 0
        var mutationDigests: [String] = []
    }

    public static let blockedRemovalMessage =
        "Not executed: this file already exists. Read and edit it instead of deleting it to retry creation."
    private var states: [Key: State] = [:]
    private var order: [Key] = []
    private let maximumPaths = 128
    private let maximumObservations = 16

    public init() {}

    public mutating func preflight(_ diagnostic: ToolExecutionDiagnostic) -> String? {
        for observation in diagnostic.fileObservations where observation.kind == .remove {
            let key = Key(workspaceIdentity: observation.workspaceIdentity, relativePath: observation.relativePath)
            if states[key]?.recoveryRequired == true { return Self.blockedRemovalMessage }
        }
        return nil
    }

    @discardableResult
    public mutating func observe(_ diagnostic: ToolExecutionDiagnostic) -> String? {
        var stopMessage: String?
        for observation in diagnostic.fileObservations {
            let key = Key(workspaceIdentity: observation.workspaceIdentity, relativePath: observation.relativePath)
            touch(key)
            var state = states[key] ?? State()
            state.observations.append(observation)
            if state.observations.count > maximumObservations { state.observations.removeFirst() }

            switch (observation.kind, observation.outcome) {
            case (.create, .alreadyExists):
                state.recoveryRequired = true
                state.readDigest = nil
                state.repeatedFailureSignature = "create:\(observation.outcome.rawValue)"
                state.repeatedFailureCount += 1
            case (.read, .succeeded):
                state.readDigest = observation.afterDigest ?? observation.beforeDigest
            case (.edit, .succeeded):
                let changed = observation.beforeDigest != nil && observation.beforeDigest != observation.afterDigest
                if changed, state.readDigest != nil, state.readDigest == observation.beforeDigest {
                    state.recoveryRequired = false
                }
                state.readDigest = nil
                state.repeatedFailureSignature = nil
                state.repeatedFailureCount = 0
                if let digest = observation.afterDigest, changed {
                    state.mutationDigests.append(digest)
                    if state.mutationDigests.count > 8 { state.mutationDigests.removeFirst() }
                }
            case (.edit, let outcome):
                guard outcome != .succeeded else { break }
                let signature = "\(observation.kind.rawValue):\(outcome.rawValue)"
                if state.repeatedFailureSignature == signature { state.repeatedFailureCount += 1 }
                else { state.repeatedFailureSignature = signature; state.repeatedFailureCount = 1 }
                if state.repeatedFailureCount >= 3 {
                    stopMessage = "Stopped: three identical failed file mutations made no progress. Read the file and continue with a changed exact edit."
                }
            case (.create, let outcome):
                guard outcome != .succeeded else { break }
                let signature = "\(observation.kind.rawValue):\(outcome.rawValue)"
                if state.repeatedFailureSignature == signature {
                    state.repeatedFailureCount += 1
                } else {
                    state.repeatedFailureSignature = signature
                    state.repeatedFailureCount = 1
                }
                if state.repeatedFailureCount >= 3 {
                    stopMessage = "Stopped: three identical failed file mutations made no progress. Read the file and continue with a changed exact edit."
                }
            case (.remove, .succeeded):
                state.recoveryRequired = false
                state.mutationDigests.removeAll()
            default:
                break
            }

            states[key] = state
            if cycleDetected(state.mutationDigests) {
                stopMessage = "Stopped: the same file content cycle repeated. Inspect the file and continue with a new message."
            }
        }
        return stopMessage
    }

    public mutating func endTurn() {
        states.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }

    private mutating func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
        if order.count > maximumPaths, let evicted = order.first {
            order.removeFirst()
            states.removeValue(forKey: evicted)
        }
    }

    private func cycleDetected(_ digests: [String]) -> Bool {
        guard digests.count >= 5 else { return false }
        let end = digests.suffix(5)
        return end.count == 5 && end[0] == end[2] && end[0] == end[4] && end[1] == end[3] && end[0] != end[1]
    }
}
