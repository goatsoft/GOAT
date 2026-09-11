import Foundation

public enum FileOperationKind: String, Codable, Sendable, Equatable {
    case read
    case create
    case edit
    case remove
}

public enum FileOperationOutcome: String, Codable, Sendable, Equatable {
    case succeeded
    case alreadyExists
    case missing
    case unchanged
    case failed
}

public struct FileOperationObservation: Codable, Sendable, Equatable, Hashable {
    public let workspaceIdentity: String
    public let relativePath: String
    public let kind: FileOperationKind
    public let outcome: FileOperationOutcome
    public let beforeDigest: String?
    public let afterDigest: String?

    public init(
        workspaceIdentity: String, relativePath: String, kind: FileOperationKind,
        outcome: FileOperationOutcome, beforeDigest: String? = nil, afterDigest: String? = nil
    ) {
        self.workspaceIdentity = workspaceIdentity
        self.relativePath = relativePath
        self.kind = kind
        self.outcome = outcome
        self.beforeDigest = beforeDigest
        self.afterDigest = afterDigest
    }
}

public enum ToolExecutionFailureCategory: String, Codable, Sendable, Equatable {
    case fileAlreadyExists
    case fileMissing
    case fileUnchanged
    case commandUnavailable
    case unknown
}

public struct ToolExecutionDiagnostic: Codable, Sendable, Equatable {
    public let fileObservations: [FileOperationObservation]
    public let failureCategory: ToolExecutionFailureCategory?

    public init(
        fileObservations: [FileOperationObservation] = [],
        failureCategory: ToolExecutionFailureCategory? = nil
    ) {
        self.fileObservations = Array(fileObservations.prefix(16))
        self.failureCategory = failureCategory
    }
}
