import Foundation
import Herd

public struct MemoryConfigurationRevision: RawRepresentable, Sendable, Hashable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct StoredMemoryConfiguration: Sendable, Equatable {
    public let configuration: MemoryConfiguration
    public let revision: MemoryConfigurationRevision

    public init(
        configuration: MemoryConfiguration,
        revision: MemoryConfigurationRevision
    ) {
        self.configuration = configuration
        self.revision = revision
    }
}

struct MemoryConfigurationStoreTestingHooks: Sendable {
    var beforeConfigurationPublication: (@Sendable () -> Void)?

    init(beforeConfigurationPublication: (@Sendable () -> Void)? = nil) {
        self.beforeConfigurationPublication = beforeConfigurationPublication
    }
}

private struct ValidatedMemoryConfigurationLocations {
    let parentPath: String
    let configurationName: String
    let markerName: String
}

/// Synchronous, fail-closed persistence intended to be owned by one MemoryCoordinator actor.
///
/// Cooperating writers serialize before checking the content revision. Replacement atomically
/// exchanges a staged file with the authority and retains the exact displaced file until the new
/// namespace entry is synchronized. A same-UID noncooperating process can still change either name
/// after the final descriptor identity check; an observed mismatch preserves both entries.
public struct MemoryConfigurationStore: Sendable {
    public static let maximumConfigurationBytes = 256 * 1_024

    public let configurationURL: URL
    public let markerURL: URL

    private static let markerData = Data("memory-config-v1\n".utf8)
    private let testingHooks: MemoryConfigurationStoreTestingHooks

    public init(
        configurationURL: URL = Home.memoryConfigurationFile,
        markerURL: URL = Home.memoryConfigurationMarker
    ) {
        self.configurationURL = configurationURL
        self.markerURL = markerURL
        self.testingHooks = MemoryConfigurationStoreTestingHooks()
    }

    init(
        configurationURL: URL,
        markerURL: URL,
        testingHooks: MemoryConfigurationStoreTestingHooks
    ) {
        self.configurationURL = configurationURL
        self.markerURL = markerURL
        self.testingHooks = testingHooks
    }

    /// Missing files initialize a fresh Local Wiki profile only before the marker exists.
    /// A marker without its configuration means previously initialized authority was lost.
    public func loadOrInitialize() throws -> StoredMemoryConfiguration {
        let locations = try validateLocations()
        let fileSystem = SecureMemoryConfigurationFileSystem(parentPath: locations.parentPath)
        guard let directory = try fileSystem.openParent(create: true) else {
            throw LocalStoreError.operationFailed(
                path: locations.parentPath,
                operation: "open memory configuration directory",
                reason: "directory disappeared")
        }
        let writerLock = try fileSystem.acquireWriterLock(in: directory)
        defer { withExtendedLifetime(writerLock) {} }
        guard try fileSystem.directoryIsCurrent(directory) else {
            throw LocalStoreError.unsafePath(
                path: locations.parentPath,
                reason: "memory configuration parent changed while locking")
        }
        guard !(try fileSystem.hasUnresolvedStagingArtifact(in: directory)) else {
            throw LocalStoreError.operationFailed(
                path: locations.parentPath,
                operation: "recover memory configuration",
                reason: "an interrupted memory configuration publication needs manual recovery")
        }

        let marker = try readMarker(
            fileSystem: fileSystem,
            directory: directory,
            name: locations.markerName)
        guard
            let record = try fileSystem.readFile(
                in: directory,
                name: locations.configurationName,
                maximumBytes: Self.maximumConfigurationBytes)
        else {
            guard marker == nil else {
                throw LocalStoreError.invalidData(
                    path: configurationURL.path,
                    reason: "memory configuration is missing after initialization")
            }
            let fresh = try MemoryConfiguration.fresh.validatedCanonical(path: configurationURL.path)
            let encoded = try encode(fresh)
            let published = try fileSystem.publishNew(
                encoded,
                as: locations.configurationName,
                in: directory,
                maximumBytes: Self.maximumConfigurationBytes)
            _ = try fileSystem.publishNew(
                Self.markerData,
                as: locations.markerName,
                in: directory,
                maximumBytes: 64)
            return stored(fresh, record: published)
        }

        let configuration = try decode(record.data)
        if marker == nil {
            _ = try fileSystem.publishNew(
                Self.markerData,
                as: locations.markerName,
                in: directory,
                maximumBytes: 64)
        }
        return stored(configuration, record: record)
    }

    /// Re-reads and validates the current authority immediately before checking its revision.
    /// Corrupt, missing, or externally changed bytes are never replaced.
    public func save(
        _ configuration: MemoryConfiguration,
        ifRevision expectedRevision: MemoryConfigurationRevision
    ) throws -> StoredMemoryConfiguration {
        let locations = try validateLocations()
        let canonical = try configuration.validatedCanonical(path: configurationURL.path)
        let fileSystem = SecureMemoryConfigurationFileSystem(parentPath: locations.parentPath)
        guard let directory = try fileSystem.openParent(create: false) else {
            throw LocalStoreError.invalidData(
                path: configurationURL.path,
                reason: "memory configuration must be loaded before saving")
        }
        let writerLock = try fileSystem.acquireWriterLock(in: directory)
        defer { withExtendedLifetime(writerLock) {} }
        guard try fileSystem.directoryIsCurrent(directory) else {
            throw LocalStoreError.unsafePath(
                path: locations.parentPath,
                reason: "memory configuration parent changed while locking")
        }
        guard !(try fileSystem.hasUnresolvedStagingArtifact(in: directory)) else {
            throw LocalStoreError.operationFailed(
                path: locations.parentPath,
                operation: "recover memory configuration",
                reason: "an interrupted memory configuration publication needs manual recovery")
        }

        let marker = try readMarker(
            fileSystem: fileSystem,
            directory: directory,
            name: locations.markerName)
        guard
            let current = try fileSystem.readFile(
                in: directory,
                name: locations.configurationName,
                maximumBytes: Self.maximumConfigurationBytes)
        else {
            throw LocalStoreError.invalidData(
                path: configurationURL.path,
                reason: marker == nil
                    ? "memory configuration must be loaded before saving"
                    : "memory configuration is missing after initialization")
        }
        let currentConfiguration = try decode(current.data)
        guard current.fingerprint.contentHash == expectedRevision.rawValue else {
            throw LocalStoreError.invalidData(
                path: configurationURL.path,
                reason: "memory configuration changed since it was loaded")
        }
        let transitioned = try canonical.validatedTransition(
            from: currentConfiguration,
            path: configurationURL.path)
        let encoded = try encode(transitioned)

        let effectiveMarker: MemoryConfigurationFileRecord
        if let marker {
            effectiveMarker = marker
        } else {
            effectiveMarker = try fileSystem.publishNew(
                Self.markerData,
                as: locations.markerName,
                in: directory,
                maximumBytes: 64)
        }
        testingHooks.beforeConfigurationPublication?()
        guard
            try fileSystem.directoryIsCurrent(directory),
            try readMarker(
                fileSystem: fileSystem,
                directory: directory,
                name: locations.markerName) == effectiveMarker
        else {
            throw LocalStoreError.invalidData(
                path: markerURL.path,
                reason: "memory configuration marker changed before publication")
        }
        let published = try fileSystem.replace(
            encoded,
            as: locations.configurationName,
            replacing: current,
            in: directory,
            maximumBytes: Self.maximumConfigurationBytes)
        guard
            try fileSystem.directoryIsCurrent(directory),
            try readMarker(
                fileSystem: fileSystem,
                directory: directory,
                name: locations.markerName) == effectiveMarker
        else {
            throw LocalStoreError.operationFailed(
                path: markerURL.path,
                operation: "validate memory configuration marker",
                reason: "memory configuration marker changed during publication")
        }
        return stored(transitioned, record: published)
    }

    private func validateLocations() throws -> ValidatedMemoryConfigurationLocations {
        let configurationPath = try validateLocation(
            configurationURL,
            label: "memory configuration")
        let markerPath = try validateLocation(markerURL, label: "memory configuration marker")
        guard configurationPath != markerPath else {
            throw LocalStoreError.unsafePath(
                path: configurationPath,
                reason: "configuration and marker paths must be different")
        }
        let configuration = try splitLocation(
            configurationPath,
            label: "memory configuration")
        let marker = try splitLocation(
            markerPath,
            label: "memory configuration marker")
        guard configuration.parent == marker.parent else {
            throw LocalStoreError.unsafePath(
                path: markerPath,
                reason: "configuration and marker must have the same parent directory")
        }
        for name in [configuration.name, marker.name] {
            guard name != SecureMemoryConfigurationFileSystem.lockName,
                !name.hasPrefix(SecureMemoryConfigurationFileSystem.stagingPrefix)
            else {
                throw LocalStoreError.unsafePath(
                    path: configuration.parent + "/" + name,
                    reason: "memory configuration targets use a reserved filename")
            }
        }
        return ValidatedMemoryConfigurationLocations(
            parentPath: configuration.parent,
            configurationName: configuration.name,
            markerName: marker.name)
    }

    private func validateLocation(_ url: URL, label: String) throws -> String {
        let path = url.path
        guard url.isFileURL,
            url.baseURL == nil,
            url.host == nil || url.host?.isEmpty == true,
            url.user == nil,
            url.password == nil,
            url.query == nil,
            url.fragment == nil,
            path.utf8.count <= 4_096,
            isLexicallyCanonicalAbsolutePath(path)
        else {
            throw LocalStoreError.unsafePath(
                path: path,
                reason: "\(label) must be a canonical absolute local path")
        }
        return path
    }

    private func isLexicallyCanonicalAbsolutePath(_ path: String) -> Bool {
        guard !path.isEmpty, path != "/", path.hasPrefix("/"), !path.hasSuffix("/"),
            !path.unicodeScalars.contains(where: { scalar in
                scalar.value < 0x20 || scalar.value == 0x7f
            })
        else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
            .allSatisfy { component in
                !component.isEmpty && component != "." && component != ".."
            }
    }

    private func splitLocation(
        _ path: String,
        label: String
    ) throws -> (parent: String, name: String) {
        guard let separator = path.lastIndex(of: "/") else {
            throw LocalStoreError.unsafePath(
                path: path,
                reason: "\(label) has no absolute parent")
        }
        let nameStart = path.index(after: separator)
        guard nameStart < path.endIndex else {
            throw LocalStoreError.unsafePath(
                path: path,
                reason: "\(label) has no filename")
        }
        let parent = separator == path.startIndex ? "/" : String(path[..<separator])
        guard parent != "/" else {
            throw LocalStoreError.unsafePath(
                path: path,
                reason: "root-level memory configuration targets are not allowed")
        }
        return (parent, String(path[nameStart...]))
    }

    private func readMarker(
        fileSystem: SecureMemoryConfigurationFileSystem,
        directory: MemoryConfigurationDirectory,
        name: String
    ) throws -> MemoryConfigurationFileRecord? {
        guard
            let record = try fileSystem.readFile(
                in: directory,
                name: name,
                maximumBytes: 64)
        else { return nil }
        guard record.data == Self.markerData else {
            throw LocalStoreError.invalidData(
                path: markerURL.path,
                reason: "memory configuration marker is invalid")
        }
        return record
    }

    private func decode(_ data: Data) throws -> MemoryConfiguration {
        do {
            let value = try JSONDecoder().decode(MemoryConfiguration.self, from: data)
            return try value.validatedCanonical(path: configurationURL.path)
        } catch let error as LocalStoreError {
            throw error
        } catch {
            throw LocalStoreError.invalidData(
                path: configurationURL.path,
                reason: error.localizedDescription)
        }
    }

    private func encode(_ configuration: MemoryConfiguration) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(configuration)
            data.append(0x0a)
            guard data.count <= Self.maximumConfigurationBytes else {
                throw LocalStoreError.invalidData(
                    path: configurationURL.path,
                    reason: "memory configuration exceeds \(Self.maximumConfigurationBytes) bytes")
            }
            return data
        } catch let error as LocalStoreError {
            throw error
        } catch {
            throw LocalStoreError.invalidData(
                path: configurationURL.path,
                reason: error.localizedDescription)
        }
    }

    private func stored(
        _ configuration: MemoryConfiguration,
        record: MemoryConfigurationFileRecord
    ) -> StoredMemoryConfiguration {
        StoredMemoryConfiguration(
            configuration: configuration,
            revision: MemoryConfigurationRevision(
                rawValue: record.fingerprint.contentHash))
    }
}
