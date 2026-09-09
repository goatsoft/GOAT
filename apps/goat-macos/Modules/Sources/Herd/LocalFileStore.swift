import Darwin
import Foundation

/// Errors from user-owned local stores. Missing files are represented by `nil` or an empty
/// collection; malformed, unreadable, or unsafe files throw so callers never treat corruption as
/// first-run state and overwrite it.
public enum LocalStoreError: LocalizedError, Sendable, Equatable {
    case invalidData(path: String, reason: String)
    case unsafePath(path: String, reason: String)
    case operationFailed(path: String, operation: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidData(let path, let reason):
            "Invalid local data at \(path): \(reason)"
        case .unsafePath(let path, let reason):
            "Unsafe local path at \(path): \(reason)"
        case .operationFailed(let path, let operation, let reason):
            "Could not \(operation) \(path): \(reason)"
        }
    }
}

/// Shared filesystem checks for stores rooted in GOAT Home.
public enum LocalFileStore {
    /// Managed JSON, Markdown, and marker files are deliberately small. Attachments have their own
    /// larger limit in `AttachmentStore` and call `boundedDataIfPresent` directly.
    public static let maximumManagedFileBytes = 8 * 1_024 * 1_024
    public static let maximumOwnerOnlyFileBytes = 1 * 1_024 * 1_024

    public static func dataIfPresent(at url: URL) throws -> Data? {
        try boundedDataIfPresent(at: url, maximumBytes: maximumManagedFileBytes)
    }

    /// Reads a regular file through one no-follow descriptor and never buffers more than the
    /// caller's limit. Keeping validation and reading on the same descriptor closes path-swap
    /// races for untrusted filenames stored in the database.
    public static func boundedDataIfPresent(at url: URL, maximumBytes: Int) throws -> Data? {
        guard maximumBytes >= 0 else {
            throw LocalStoreError.invalidData(
                path: url.path, reason: "maximum byte count cannot be negative")
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw LocalStoreError.operationFailed(
                path: url.path, operation: "open bounded file", reason: errnoDescription())
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        do {
            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0 else {
                throw LocalStoreError.operationFailed(
                    path: url.path, operation: "inspect bounded file",
                    reason: errnoDescription())
            }
            guard status.st_mode & S_IFMT == S_IFREG else {
                throw LocalStoreError.unsafePath(
                    path: url.path, reason: "expected a regular bounded file")
            }
            guard status.st_size >= 0, UInt64(status.st_size) <= UInt64(maximumBytes) else {
                throw LocalStoreError.invalidData(
                    path: url.path, reason: "file exceeds the permitted byte count")
            }

            var data = Data()
            while data.count <= maximumBytes {
                let remaining = maximumBytes - data.count
                let requested = min(1_048_576, remaining + 1)
                guard let chunk = try handle.read(upToCount: requested), !chunk.isEmpty else {
                    return data
                }
                data.append(chunk)
            }
            throw LocalStoreError.invalidData(
                path: url.path, reason: "file grew beyond the permitted byte count while reading")
        } catch let error as LocalStoreError {
            throw error
        } catch {
            throw LocalStoreError.operationFailed(
                path: url.path, operation: "read bounded file",
                reason: error.localizedDescription)
        }
    }

    /// Opens an existing secret without following a final symlink and tightens legacy/manual
    /// permissions before reading any bytes.
    public static func ownerOnlyDataIfPresent(
        at url: URL, maximumBytes: Int = maximumOwnerOnlyFileBytes
    ) throws -> Data? {
        guard maximumBytes >= 0 else {
            throw LocalStoreError.invalidData(
                path: url.path, reason: "maximum byte count cannot be negative")
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw LocalStoreError.operationFailed(
                path: url.path, operation: "open owner-only file",
                reason: errnoDescription())
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0 else {
                throw LocalStoreError.operationFailed(
                    path: url.path, operation: "inspect owner-only file",
                    reason: errnoDescription())
            }
            guard status.st_mode & S_IFMT == S_IFREG else {
                throw LocalStoreError.unsafePath(
                    path: url.path, reason: "expected a regular owner-only file")
            }
            guard status.st_size >= 0,
                UInt64(status.st_size) <= UInt64(maximumBytes)
            else {
                throw LocalStoreError.invalidData(
                    path: url.path, reason: "owner-only file exceeds the permitted byte count")
            }
            guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw LocalStoreError.operationFailed(
                    path: url.path, operation: "tighten owner-only permissions",
                    reason: errnoDescription())
            }
            let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            guard data.count <= maximumBytes else {
                throw LocalStoreError.invalidData(
                    path: url.path,
                    reason: "owner-only file grew beyond the permitted byte count while reading")
            }
            try handle.close()
            return data
        } catch let error as LocalStoreError {
            throw error
        } catch {
            throw LocalStoreError.operationFailed(
                path: url.path, operation: "read owner-only file",
                reason: error.localizedDescription)
        }
    }

    public static func regularFileExists(at url: URL) throws -> Bool {
        let manager = FileManager.default
        guard pathEntryExists(at: url, manager: manager) else { return false }
        try rejectSymbolicLink(at: url)
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                throw LocalStoreError.unsafePath(
                    path: url.path, reason: "expected a regular file")
            }
            return true
        } catch let error as LocalStoreError {
            throw error
        } catch {
            throw LocalStoreError.operationFailed(
                path: url.path, operation: "inspect", reason: error.localizedDescription)
        }
    }

    public static func ensureDirectory(at url: URL) throws {
        let manager = FileManager.default
        if pathEntryExists(at: url, manager: manager) {
            try rejectSymbolicLink(at: url)
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else {
                    throw LocalStoreError.unsafePath(
                        path: url.path, reason: "expected a directory")
                }
            } catch let error as LocalStoreError {
                throw error
            } catch {
                throw LocalStoreError.operationFailed(
                    path: url.path, operation: "inspect", reason: error.localizedDescription)
            }
            return
        }
        do {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw LocalStoreError.operationFailed(
                path: url.path, operation: "create directory", reason: error.localizedDescription)
        }
    }

    public static func directoryExists(at url: URL) throws -> Bool {
        let manager = FileManager.default
        guard pathEntryExists(at: url, manager: manager) else { return false }
        try rejectSymbolicLink(at: url)
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw LocalStoreError.unsafePath(
                    path: url.path, reason: "expected a directory")
            }
            return true
        } catch let error as LocalStoreError {
            throw error
        } catch {
            throw LocalStoreError.operationFailed(
                path: url.path, operation: "inspect", reason: error.localizedDescription)
        }
    }

    public static func makeStagingDirectory(in root: URL) throws -> URL {
        try ensureDirectory(at: root)
        let staging = stagingURL(in: root)
        try requireContained(staging, in: root)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            return staging
        } catch {
            throw LocalStoreError.operationFailed(
                path: staging.path, operation: "create staging directory",
                reason: error.localizedDescription)
        }
    }

    public static func makeStagingCopy(of source: URL, in root: URL) throws -> URL {
        try ensureDirectory(at: root)
        try requireContained(source, in: root)
        guard try directoryExists(at: source) else {
            throw LocalStoreError.operationFailed(
                path: source.path, operation: "stage directory",
                reason: "source does not exist")
        }
        let staging = stagingURL(in: root)
        do {
            try FileManager.default.copyItem(at: source, to: staging)
            try rejectSymbolicLink(at: staging)
            return staging
        } catch let error as LocalStoreError {
            try? FileManager.default.removeItem(at: staging)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw LocalStoreError.operationFailed(
                path: source.path, operation: "stage directory",
                reason: error.localizedDescription)
        }
    }

    public static func commitNewDirectory(_ staging: URL, to destination: URL, in root: URL) throws {
        try requireContained(staging, in: root)
        try requireContained(destination, in: root)
        guard !(try directoryExists(at: destination)) else {
            throw LocalStoreError.operationFailed(
                path: destination.path, operation: "commit directory",
                reason: "destination already exists")
        }
        guard Darwin.rename(staging.path, destination.path) == 0 else {
            throw LocalStoreError.operationFailed(
                path: destination.path, operation: "commit directory",
                reason: errnoDescription())
        }
        try synchronizeDirectory(root)
    }

    /// Atomically swaps a fully prepared staging directory with an existing managed directory.
    /// After the swap, the old directory occupies the hidden staging path and is best-effort
    /// cleaned; a crash can leave a hidden backup, never a partially updated visible entry.
    public static func commitReplacingDirectory(
        _ staging: URL, at destination: URL, in root: URL
    ) throws {
        try requireContained(staging, in: root)
        try requireContained(destination, in: root)
        try rejectSymbolicLink(at: staging)
        guard try directoryExists(at: destination) else {
            throw LocalStoreError.operationFailed(
                path: destination.path, operation: "replace directory",
                reason: "destination does not exist")
        }
        guard Darwin.renamex_np(staging.path, destination.path, UInt32(RENAME_SWAP)) == 0 else {
            throw LocalStoreError.operationFailed(
                path: destination.path, operation: "replace directory",
                reason: errnoDescription())
        }
        try? FileManager.default.removeItem(at: staging)
        try synchronizeDirectory(root)
    }

    public static func childDirectories(in root: URL) throws -> [URL] {
        let manager = FileManager.default
        guard pathEntryExists(at: root, manager: manager) else { return [] }
        try ensureDirectory(at: root)
        do {
            let children = try manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles])
            return try children.map { child in
                let values = try child.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true, values.isDirectory == true else {
                    throw LocalStoreError.unsafePath(
                        path: child.path, reason: "store entries must be real directories")
                }
                try requireContained(child, in: root)
                return child
            }
        } catch let error as LocalStoreError {
            throw error
        } catch {
            throw LocalStoreError.operationFailed(
                path: root.path, operation: "list directory", reason: error.localizedDescription)
        }
    }

    public static func validateComponent(_ component: String, label: String) throws {
        let allowed = component.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == "."
        }
        guard !component.isEmpty, !component.hasPrefix("."),
            component.count <= 128, allowed,
            (component as NSString).lastPathComponent == component
        else {
            throw LocalStoreError.unsafePath(
                path: component, reason: "\(label) must be one safe path component")
        }
    }

    public static func requireContained(_ child: URL, in root: URL) throws {
        guard let rootPath = normalizedPathWithoutResolvingSymlinks(root),
            let childPath = normalizedPathWithoutResolvingSymlinks(child)
        else {
            throw LocalStoreError.unsafePath(
                path: child.path, reason: "path contains an unresolved parent component")
        }
        let lexicalContainment = isDescendant(childPath, of: rootPath)
        let canonicalContainment = isDescendant(
            child.standardizedFileURL.path,
            of: root.standardizedFileURL.path)
        guard lexicalContainment || canonicalContainment else {
            throw LocalStoreError.unsafePath(
                path: child.path, reason: "path escapes its store root")
        }
    }

    /// URL.standardizedFileURL resolves an existing intermediate symbolic link on macOS while a
    /// not-yet-created sibling remains textual. `/private/tmp/root` and `/tmp/root/new` can then
    /// compare as unrelated even though they were derived from the same lexical root. Normalize
    /// only dot components here; callers independently reject symbolic links at filesystem edges.
    private static func normalizedPathWithoutResolvingSymlinks(_ url: URL) -> String? {
        let path = url.path
        guard path.hasPrefix("/") else { return nil }
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    private static func isDescendant(_ child: String, of root: String) -> Bool {
        root == "/" ? child.hasPrefix("/") && child != "/" : child.hasPrefix(root + "/")
    }

    public static func rejectSymbolicLink(at url: URL) throws {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                throw LocalStoreError.unsafePath(
                    path: url.path, reason: "symbolic links are not allowed in managed stores")
            }
        } catch let error as LocalStoreError {
            throw error
        } catch {
            throw LocalStoreError.operationFailed(
                path: url.path, operation: "inspect", reason: error.localizedDescription)
        }
    }

    public static func write(_ data: Data, to url: URL) throws {
        try atomicWrite(data, to: url, permissions: S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
    }

    /// Write secrets with mode 0600 before any bytes become visible, sync the temporary file, then
    /// atomically rename it over the destination. There is no intermediate world-readable file.
    public static func writeOwnerOnly(
        _ data: Data, to url: URL, maximumBytes: Int = maximumOwnerOnlyFileBytes
    ) throws {
        guard maximumBytes >= 0, data.count <= maximumBytes else {
            throw LocalStoreError.invalidData(
                path: url.path, reason: "owner-only file exceeds the permitted byte count")
        }
        try atomicWrite(data, to: url, permissions: S_IRUSR | S_IWUSR)
    }

    private static func atomicWrite(_ data: Data, to url: URL, permissions: mode_t) throws {
        let parent = url.deletingLastPathComponent()
        try ensureDirectory(at: parent)
        if pathEntryExists(at: url, manager: FileManager.default) {
            try rejectSymbolicLink(at: url)
        }
        let temporary = parent.appendingPathComponent(".goat-secret-\(UUID().uuidString)")
        try requireContained(temporary, in: parent)
        let descriptor = Darwin.open(
            temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            permissions)
        guard descriptor >= 0 else {
            throw LocalStoreError.operationFailed(
                path: temporary.path, operation: "create owner-only file",
                reason: errnoDescription())
        }

        var shouldRemove = true
        defer {
            if shouldRemove { _ = Darwin.unlink(temporary.path) }
        }
        do {
            guard Darwin.fchmod(descriptor, permissions) == 0 else {
                throw LocalStoreError.operationFailed(
                    path: temporary.path, operation: "set file permissions",
                    reason: errnoDescription())
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch let error as LocalStoreError {
            throw error
        } catch {
            throw LocalStoreError.operationFailed(
                path: temporary.path, operation: "write owner-only file",
                reason: error.localizedDescription)
        }
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            throw LocalStoreError.operationFailed(
                path: url.path, operation: "replace owner-only file",
                reason: errnoDescription())
        }
        shouldRemove = false
        try synchronizeDirectory(parent)
    }

    public static func removeItem(at url: URL) throws {
        let manager = FileManager.default
        guard pathEntryExists(at: url, manager: manager) else { return }
        try rejectSymbolicLink(at: url)
        do {
            try manager.removeItem(at: url)
        } catch {
            throw LocalStoreError.operationFailed(
                path: url.path, operation: "delete", reason: error.localizedDescription)
        }
    }

    private static func pathEntryExists(at url: URL, manager: FileManager) -> Bool {
        if manager.fileExists(atPath: url.path) { return true }
        return (try? manager.attributesOfItem(atPath: url.path)) != nil
    }

    private static func stagingURL(in root: URL) -> URL {
        root.appendingPathComponent(
            ".goat-stage-\(UUID().uuidString)", isDirectory: true)
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw LocalStoreError.operationFailed(
                path: directory.path, operation: "open directory for sync",
                reason: errnoDescription())
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw LocalStoreError.operationFailed(
                path: directory.path, operation: "sync directory",
                reason: errnoDescription())
        }
    }

    private static func errnoDescription() -> String {
        String(cString: strerror(errno))
    }
}
