import Darwin
import Foundation

/// Serializes MCP configuration filesystem work away from UI actors.
///
/// `MCPConfigFile` and `CodexConfig` intentionally remain synchronous parsers. App-facing code
/// crosses this actor before invoking them so reads, writes, imports, and watcher setup never run
/// on the main actor.
public actor MCPConfigFileWorker {
    public enum MutationError: LocalizedError, Equatable {
        case staleOperation(requested: UInt64, latest: UInt64)

        public var errorDescription: String? {
            switch self {
            case .staleOperation(let requested, let latest):
                "Ignored stale MCP config operation \(requested); latest operation is \(latest)"
            }
        }
    }

    public enum ImportFormat: Sendable {
        case claudeDesktop
        case codex
    }

    private var latestMutationRevision: UInt64 = 0

    public init() {}

    public func load(from url: URL) throws -> [MCPServerConfig] {
        try MCPConfigFile.load(from: url)
    }

    /// Writes one server and returns the authoritative refreshed snapshot. Callers must not publish
    /// or connect from the pre-write value when the follow-up read fails.
    public func upsertAndLoad(
        _ config: MCPServerConfig,
        renamedFrom oldName: String? = nil,
        revision: UInt64,
        in url: URL
    ) throws -> [MCPServerConfig] {
        try admitMutation(revision)
        try MCPConfigFile.upsert(config, renamedFrom: oldName, in: url)
        return try MCPConfigFile.load(from: url)
    }

    public func removeAndLoad(name: String, revision: UInt64, from url: URL) throws -> [MCPServerConfig] {
        try admitMutation(revision)
        try MCPConfigFile.remove(name: name, from: url)
        return try MCPConfigFile.load(from: url)
    }

    /// Updates one server and returns the authoritative refreshed snapshot.
    public func setDisabledAndLoad(
        _ disabled: Bool,
        name: String,
        revision: UInt64,
        in url: URL
    ) throws -> [MCPServerConfig] {
        try admitMutation(revision)
        try MCPConfigFile.setDisabled(disabled, name: name, in: url)
        return try MCPConfigFile.load(from: url)
    }

    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func importServers(
        from source: URL,
        format: ImportFormat,
        revision: UInt64,
        into destination: URL
    ) throws -> [String] {
        try admitMutation(revision)
        switch format {
        case .claudeDesktop:
            return try MCPConfigFile.importServers(from: source, into: destination)
        case .codex:
            return try MCPConfigFile.importParsed(
                CodexConfig.load(from: source),
                into: destination
            )
        }
    }

    public func ensureFileExists(at url: URL) throws {
        _ = try MCPConfigFile.load(from: url)
    }

    /// The returned descriptor is owned by the caller and must be closed when its dispatch source
    /// is cancelled.
    public func openEventDescriptor(for url: URL) -> Int32 {
        open(url.path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
    }

    public func closeEventDescriptor(_ descriptor: Int32) {
        close(descriptor)
    }

    private func admitMutation(_ revision: UInt64) throws {
        guard revision > latestMutationRevision else {
            throw MutationError.staleOperation(
                requested: revision, latest: latestMutationRevision)
        }
        latestMutationRevision = revision
    }
}
