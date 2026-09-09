import CryptoKit
import Darwin
import Foundation
import Herd

struct MemoryConfigurationDirectoryIdentity: Sendable, Hashable {
    let device: UInt64
    let inode: UInt64
}

struct MemoryConfigurationFileFingerprint: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64
    let contentHash: String
}

struct MemoryConfigurationFileRecord: Sendable, Equatable {
    let data: Data
    let fingerprint: MemoryConfigurationFileFingerprint

    func hasSameFileAndContent(as other: Self) -> Bool {
        data == other.data
            && fingerprint.device == other.fingerprint.device
            && fingerprint.inode == other.fingerprint.inode
            && fingerprint.size == other.fingerprint.size
            && fingerprint.contentHash == other.fingerprint.contentHash
    }
}

final class MemoryConfigurationOwnedFileDescriptor {
    let rawValue: Int32

    init(_ rawValue: Int32) {
        self.rawValue = rawValue
    }

    deinit {
        Darwin.close(rawValue)
    }
}

struct MemoryConfigurationDirectory {
    let descriptor: MemoryConfigurationOwnedFileDescriptor
    let identity: MemoryConfigurationDirectoryIdentity
    let path: String
}

private func setMemoryConfigurationLock(_ descriptor: Int32, type: Int16) -> Int32 {
    var lock = flock()
    lock.l_type = type
    lock.l_whence = Int16(SEEK_SET)
    lock.l_start = 0
    lock.l_len = 0
    return Darwin.fcntl(descriptor, F_SETLK, &lock)
}

private enum MemoryConfigurationProcessWriterLocks {
    private static let condition = NSCondition()
    // Every access to this escape hatch is protected by condition.
    nonisolated(unsafe) private static var held: Set<MemoryConfigurationDirectoryIdentity> = []

    static func acquire(
        _ identity: MemoryConfigurationDirectoryIdentity,
        timeout: TimeInterval
    ) throws -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while held.contains(identity) {
            try Task.checkCancellation()
            _ = condition.wait(until: min(deadline, Date().addingTimeInterval(0.05)))
            if Date() >= deadline, held.contains(identity) { return false }
        }
        held.insert(identity)
        return true
    }

    static func release(_ identity: MemoryConfigurationDirectoryIdentity) {
        condition.lock()
        held.remove(identity)
        condition.broadcast()
        condition.unlock()
    }
}

final class MemoryConfigurationWriterLock {
    private let descriptor: MemoryConfigurationOwnedFileDescriptor
    private let directoryIdentity: MemoryConfigurationDirectoryIdentity

    init(
        descriptor: MemoryConfigurationOwnedFileDescriptor,
        directoryIdentity: MemoryConfigurationDirectoryIdentity
    ) {
        self.descriptor = descriptor
        self.directoryIdentity = directoryIdentity
    }

    deinit {
        _ = setMemoryConfigurationLock(descriptor.rawValue, type: Int16(F_UNLCK))
        MemoryConfigurationProcessWriterLocks.release(directoryIdentity)
    }
}

/// Descriptor-anchored operations for the memory configuration authority.
///
/// Absolute strings are retained only for diagnostics. Traversal and mutation use `openat`,
/// `fstatat`, `renameatx_np`, and `unlinkat` relative to validated directory descriptors.
struct SecureMemoryConfigurationFileSystem {
    static let lockName = ".goat-memory-config.lock"
    static let stagingPrefix = ".goat-memory-config-stage-"

    let parentPath: String

    func openParent(create: Bool) throws -> MemoryConfigurationDirectory? {
        guard parentPath.hasPrefix("/"), parentPath != "/", !parentPath.utf8.contains(0) else {
            throw LocalStoreError.unsafePath(
                path: parentPath,
                reason: "memory configuration parent must be a non-root absolute path")
        }
        let components = parentPath.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        let rootDescriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDescriptor >= 0 else {
            throw operationError(path: "/", operation: "open filesystem root")
        }
        var current = MemoryConfigurationOwnedFileDescriptor(rootDescriptor)
        var traversed = ""

        for component in components {
            try validateComponent(component, path: traversed.isEmpty ? "/" : traversed)
            traversed += "/\(component)"
            if let next = try openChildDirectory(
                parent: current.rawValue,
                name: component,
                path: traversed,
                missingIsAllowed: true)
            {
                current = next
                continue
            }
            guard create else { return nil }
            current = try createChildDirectory(
                parent: current.rawValue,
                name: component,
                path: traversed)
        }

        let metadata = try ownedDirectoryMetadata(current.rawValue, path: parentPath)
        return MemoryConfigurationDirectory(
            descriptor: current,
            identity: directoryIdentity(metadata),
            path: parentPath)
    }

    func directoryIsCurrent(_ directory: MemoryConfigurationDirectory) throws -> Bool {
        guard let current = try openParent(create: false) else { return false }
        return current.identity == directory.identity
    }

    func acquireWriterLock(
        in directory: MemoryConfigurationDirectory
    ) throws -> MemoryConfigurationWriterLock {
        guard try MemoryConfigurationProcessWriterLocks.acquire(directory.identity, timeout: 5) else {
            throw LocalStoreError.operationFailed(
                path: directory.path,
                operation: "lock memory configuration",
                reason: "timed out waiting for another in-process writer")
        }
        var releaseProcessLock = true
        var releaseFileLock = false
        var openedDescriptor: MemoryConfigurationOwnedFileDescriptor?
        defer {
            if releaseFileLock, let openedDescriptor {
                _ = setMemoryConfigurationLock(
                    openedDescriptor.rawValue,
                    type: Int16(F_UNLCK))
            }
            if releaseProcessLock {
                MemoryConfigurationProcessWriterLocks.release(directory.identity)
            }
        }

        let path = childPath(Self.lockName)
        var created = false
        var existingBeforeOpen: stat?
        var rawDescriptor = Self.lockName.withCString {
            Darwin.openat(
                directory.descriptor.rawValue,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC,
                mode_t(0o600))
        }
        if rawDescriptor >= 0 {
            created = true
        } else if errno == EEXIST {
            let existing = try requiredMetadata(
                directory: directory.descriptor.rawValue,
                name: Self.lockName,
                path: path)
            try validateOwnerFile(existing, path: path, expectedSize: 0)
            existingBeforeOpen = existing
            rawDescriptor = Self.lockName.withCString {
                Darwin.openat(
                    directory.descriptor.rawValue,
                    $0,
                    O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            }
        }
        guard rawDescriptor >= 0 else {
            if errno == ELOOP {
                throw LocalStoreError.unsafePath(
                    path: path,
                    reason: "memory configuration lock must not be a symbolic link")
            }
            throw operationError(path: path, operation: "open memory configuration lock")
        }
        let descriptor = MemoryConfigurationOwnedFileDescriptor(rawDescriptor)
        openedDescriptor = descriptor
        let opened = try fileMetadata(descriptor.rawValue, path: path)
        let named = try requiredMetadata(
            directory: directory.descriptor.rawValue,
            name: Self.lockName,
            path: path)
        try validateOwnerFile(opened, path: path, expectedSize: 0)
        guard sameNode(opened, named), existingBeforeOpen.map({ sameNode($0, opened) }) ?? true else {
            throw LocalStoreError.unsafePath(
                path: path,
                reason: "memory configuration lock changed identity while opening")
        }

        var acquired = false
        for _ in 0..<500 {
            try Task.checkCancellation()
            if setMemoryConfigurationLock(descriptor.rawValue, type: Int16(F_WRLCK)) == 0 {
                acquired = true
                break
            }
            let code = errno
            if code != EACCES && code != EAGAIN {
                throw operationError(
                    path: path,
                    operation: "lock memory configuration",
                    code: code)
            }
            Darwin.usleep(10_000)
        }
        guard acquired else {
            throw LocalStoreError.operationFailed(
                path: path,
                operation: "lock memory configuration",
                reason: "timed out waiting for another process")
        }
        releaseFileLock = true

        if created {
            guard Darwin.fchmod(descriptor.rawValue, 0o600) == 0,
                Darwin.fsync(descriptor.rawValue) == 0
            else {
                throw operationError(path: path, operation: "secure memory configuration lock")
            }
            try syncDirectory(directory)
        }
        let locked = try fileMetadata(descriptor.rawValue, path: path)
        let namedAfterLock = try requiredMetadata(
            directory: directory.descriptor.rawValue,
            name: Self.lockName,
            path: path)
        try validateOwnerFile(locked, path: path, expectedSize: 0)
        guard sameNode(locked, namedAfterLock), try directoryIsCurrent(directory) else {
            throw LocalStoreError.unsafePath(
                path: path,
                reason: "memory configuration lock or named parent changed while locking")
        }

        releaseFileLock = false
        releaseProcessLock = false
        return MemoryConfigurationWriterLock(
            descriptor: descriptor,
            directoryIdentity: directory.identity)
    }

    func readFile(
        in directory: MemoryConfigurationDirectory,
        name: String,
        maximumBytes: Int
    ) throws -> MemoryConfigurationFileRecord? {
        try validateComponent(name, path: directory.path)
        guard maximumBytes >= 0 else {
            throw LocalStoreError.invalidData(
                path: childPath(name),
                reason: "maximum byte count cannot be negative")
        }
        let path = childPath(name)
        guard
            let namedBefore = try optionalMetadata(
                directory: directory.descriptor.rawValue,
                name: name,
                path: path)
        else { return nil }
        try validateOwnerFile(namedBefore, path: path)

        let rawDescriptor = name.withCString {
            Darwin.openat(
                directory.descriptor.rawValue,
                $0,
                O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard rawDescriptor >= 0 else {
            throw operationError(path: path, operation: "open memory configuration file")
        }
        let descriptor = MemoryConfigurationOwnedFileDescriptor(rawDescriptor)
        let before = try fileMetadata(descriptor.rawValue, path: path)
        try validateOwnerFile(before, path: path)
        guard sameNode(namedBefore, before) else {
            throw LocalStoreError.unsafePath(
                path: path,
                reason: "memory configuration file changed identity before reading")
        }
        guard before.st_size >= 0, UInt64(before.st_size) <= UInt64(maximumBytes) else {
            throw LocalStoreError.invalidData(
                path: path,
                reason: "owner-only file exceeds the permitted byte count")
        }

        let data = try boundedRead(
            descriptor: descriptor.rawValue,
            path: path,
            maximumBytes: maximumBytes)
        let after = try fileMetadata(descriptor.rawValue, path: path)
        let namedAfter = try requiredMetadata(
            directory: directory.descriptor.rawValue,
            name: name,
            path: path)
        try validateOwnerFile(after, path: path)
        guard stableFile(before, after), sameNode(after, namedAfter) else {
            throw LocalStoreError.invalidData(
                path: path,
                reason: "memory configuration file changed while reading")
        }
        return MemoryConfigurationFileRecord(
            data: data,
            fingerprint: fingerprint(after, data: data))
    }

    /// A retained exchange stage means a configuration publication was interrupted or could not
    /// be durably finalized. Its bytes are recovery evidence, never an alternate authority.
    func hasUnresolvedStagingArtifact(in directory: MemoryConfigurationDirectory) throws -> Bool {
        let duplicate = Darwin.dup(directory.descriptor.rawValue)
        guard duplicate >= 0 else {
            throw operationError(path: directory.path, operation: "duplicate configuration directory")
        }
        guard let stream = Darwin.fdopendir(duplicate) else {
            let code = errno
            Darwin.close(duplicate)
            throw operationError(path: directory.path, operation: "open configuration directory", code: code)
        }
        defer { Darwin.closedir(stream) }

        Darwin.rewinddir(stream)
        while true {
            errno = 0
            guard let entry = Darwin.readdir(stream) else {
                let code = errno
                if code != 0 {
                    throw operationError(path: directory.path, operation: "read configuration directory", code: code)
                }
                return false
            }
            var value = entry.pointee
            let bytes = withUnsafeBytes(of: &value.d_name) { Array($0) }
            guard let terminator = bytes.firstIndex(of: 0),
                let name = String(bytes: bytes[..<terminator], encoding: .utf8)
            else {
                throw LocalStoreError.unsafePath(
                    path: directory.path,
                    reason: "configuration directory contains an invalid UTF-8 entry name")
            }
            if name.hasPrefix(Self.stagingPrefix) { return true }
        }
    }

    func publishNew(
        _ data: Data,
        as name: String,
        in directory: MemoryConfigurationDirectory,
        maximumBytes: Int
    ) throws -> MemoryConfigurationFileRecord {
        let staged = try createStagedFile(
            data,
            in: directory,
            maximumBytes: maximumBytes)
        var removeStaging = true
        defer {
            if removeStaging {
                try? removeFileIfMatching(
                    in: directory,
                    name: staged.name,
                    expected: staged.record)
            }
        }
        guard try readFile(in: directory, name: name, maximumBytes: maximumBytes) == nil else {
            throw LocalStoreError.invalidData(
                path: childPath(name),
                reason: "memory configuration entry already exists")
        }
        guard try directoryIsCurrent(directory),
            try readFile(
                in: directory,
                name: staged.name,
                maximumBytes: maximumBytes) == staged.record
        else {
            throw LocalStoreError.unsafePath(
                path: directory.path,
                reason: "memory configuration parent or staged file changed before publication")
        }
        let result = staged.name.withCString { source in
            name.withCString { destination in
                Darwin.renameatx_np(
                    directory.descriptor.rawValue,
                    source,
                    directory.descriptor.rawValue,
                    destination,
                    UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            throw operationError(path: childPath(name), operation: "publish memory configuration")
        }
        removeStaging = false
        guard try directoryIsCurrent(directory),
            let published = try readFile(
                in: directory,
                name: name,
                maximumBytes: maximumBytes),
            published.hasSameFileAndContent(as: staged.record)
        else {
            throw LocalStoreError.operationFailed(
                path: childPath(name),
                operation: "validate published memory configuration",
                reason: "published namespace identity changed; GOAT left it untouched")
        }
        do {
            try syncDirectory(directory)
        } catch {
            throw LocalStoreError.operationFailed(
                path: childPath(name),
                operation: "synchronize published memory configuration",
                reason: "the exact published bytes remain visible: \(error.localizedDescription)")
        }
        return published
    }

    func replace(
        _ data: Data,
        as name: String,
        replacing expected: MemoryConfigurationFileRecord,
        in directory: MemoryConfigurationDirectory,
        maximumBytes: Int
    ) throws -> MemoryConfigurationFileRecord {
        let staged = try createStagedFile(
            data,
            in: directory,
            maximumBytes: maximumBytes)
        var removeStaging = true
        defer {
            if removeStaging {
                try? removeFileIfMatching(
                    in: directory,
                    name: staged.name,
                    expected: staged.record)
            }
        }
        guard try directoryIsCurrent(directory),
            try readFile(in: directory, name: name, maximumBytes: maximumBytes) == expected,
            try readFile(
                in: directory,
                name: staged.name,
                maximumBytes: maximumBytes) == staged.record
        else {
            throw LocalStoreError.invalidData(
                path: childPath(name),
                reason: "memory configuration changed before atomic publication")
        }

        let result = staged.name.withCString { stagedName in
            name.withCString { destinationName in
                Darwin.renameatx_np(
                    directory.descriptor.rawValue,
                    stagedName,
                    directory.descriptor.rawValue,
                    destinationName,
                    UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else {
            throw operationError(path: childPath(name), operation: "exchange memory configuration")
        }
        removeStaging = false

        let displaced = try readFile(
            in: directory,
            name: staged.name,
            maximumBytes: maximumBytes)
        let published = try readFile(
            in: directory,
            name: name,
            maximumBytes: maximumBytes)
        let entriesRemainExactlySwapped =
            displaced?.hasSameFileAndContent(as: expected) == true
            && published?.hasSameFileAndContent(as: staged.record) == true
        guard let published,
            entriesRemainExactlySwapped,
            try directoryIsCurrent(directory)
        else {
            if entriesRemainExactlySwapped {
                let restored = try restoreDisplacedAuthorityIfUnchanged(
                    authorityName: name,
                    stagedName: staged.name,
                    expectedAuthority: expected,
                    publishedCandidate: staged.record,
                    in: directory,
                    maximumBytes: maximumBytes)
                if restored {
                    try removeFileIfMatching(
                        in: directory,
                        name: staged.name,
                        expected: staged.record)
                    try syncDirectory(directory)
                }
            }
            throw LocalStoreError.operationFailed(
                path: childPath(name),
                operation: "validate exchanged memory configuration",
                reason:
                    "namespace ownership changed; published and displaced entries were both preserved at \(childPath(staged.name))"
            )
        }
        do {
            try syncDirectory(directory)
        } catch {
            throw LocalStoreError.operationFailed(
                path: childPath(name),
                operation: "synchronize exchanged memory configuration",
                reason:
                    "published bytes and the displaced backup at \(childPath(staged.name)) remain visible: \(error.localizedDescription)"
            )
        }

        do {
            try removeFileIfMatching(
                in: directory,
                name: staged.name,
                expected: expected)
            guard try readFile(in: directory, name: staged.name, maximumBytes: maximumBytes) == nil else {
                throw LocalStoreError.operationFailed(
                    path: childPath(staged.name),
                    operation: "remove displaced configuration backup",
                    reason: "could not remove the displaced configuration backup")
            }
            try syncDirectory(directory)
        } catch {
            throw LocalStoreError.operationFailed(
                path: childPath(staged.name),
                operation: "recover published memory configuration",
                reason: "published configuration needs manual recovery: \(error.localizedDescription)")
        }
        return published
    }

    private func restoreDisplacedAuthorityIfUnchanged(
        authorityName: String,
        stagedName: String,
        expectedAuthority: MemoryConfigurationFileRecord,
        publishedCandidate: MemoryConfigurationFileRecord,
        in directory: MemoryConfigurationDirectory,
        maximumBytes: Int
    ) throws -> Bool {
        guard
            try readFile(in: directory, name: authorityName, maximumBytes: maximumBytes)?
                .hasSameFileAndContent(as: publishedCandidate) == true,
            try readFile(in: directory, name: stagedName, maximumBytes: maximumBytes)?
                .hasSameFileAndContent(as: expectedAuthority) == true
        else { return false }
        let result = stagedName.withCString { staged in
            authorityName.withCString { authority in
                Darwin.renameatx_np(
                    directory.descriptor.rawValue,
                    staged,
                    directory.descriptor.rawValue,
                    authority,
                    UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else {
            throw operationError(
                path: childPath(authorityName),
                operation: "restore displaced memory configuration")
        }
        guard
            try readFile(in: directory, name: authorityName, maximumBytes: maximumBytes)?
                .hasSameFileAndContent(as: expectedAuthority) == true,
            try readFile(in: directory, name: stagedName, maximumBytes: maximumBytes)?
                .hasSameFileAndContent(as: publishedCandidate) == true
        else {
            throw LocalStoreError.operationFailed(
                path: childPath(authorityName),
                operation: "restore displaced memory configuration",
                reason: "configuration changed while restoring a displaced authority")
        }
        try syncDirectory(directory)
        return true
    }

    func syncDirectory(_ directory: MemoryConfigurationDirectory) throws {
        guard Darwin.fsync(directory.descriptor.rawValue) == 0 else {
            throw operationError(path: directory.path, operation: "synchronize directory")
        }
    }

    private struct StagedFile {
        let name: String
        let record: MemoryConfigurationFileRecord
    }

    private func createStagedFile(
        _ data: Data,
        in directory: MemoryConfigurationDirectory,
        maximumBytes: Int
    ) throws -> StagedFile {
        guard data.count <= maximumBytes else {
            throw LocalStoreError.invalidData(
                path: directory.path,
                reason: "memory configuration staging data exceeds the permitted byte count")
        }
        for _ in 0..<16 {
            let name = Self.stagingPrefix + UUID().uuidString.lowercased()
            let path = childPath(name)
            let descriptor = name.withCString {
                Darwin.openat(
                    directory.descriptor.rawValue,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(0o600))
            }
            if descriptor < 0 {
                if errno == EEXIST { continue }
                throw operationError(path: path, operation: "create staged memory configuration")
            }
            var shouldRemove = true
            var descriptorIsOpen = true
            var createdMetadata: stat?
            defer {
                if descriptorIsOpen {
                    _ = Darwin.close(descriptor)
                }
                if shouldRemove, let createdMetadata,
                    let named = try? requiredMetadata(
                        directory: directory.descriptor.rawValue,
                        name: name,
                        path: path),
                    sameNode(createdMetadata, named)
                {
                    _ = name.withCString {
                        Darwin.unlinkat(directory.descriptor.rawValue, $0, 0)
                    }
                }
            }
            try writeAll(data, descriptor: descriptor, path: path)
            guard Darwin.fchmod(descriptor, 0o600) == 0,
                Darwin.fsync(descriptor) == 0
            else {
                throw operationError(path: path, operation: "synchronize staged configuration")
            }
            createdMetadata = try fileMetadata(descriptor, path: path)
            let closeResult = Darwin.close(descriptor)
            descriptorIsOpen = false
            guard closeResult == 0 else {
                throw operationError(path: path, operation: "close staged configuration")
            }
            guard
                let record = try readFile(
                    in: directory,
                    name: name,
                    maximumBytes: maximumBytes),
                record.data == data
            else {
                throw LocalStoreError.operationFailed(
                    path: path,
                    operation: "validate staged memory configuration",
                    reason: "staged bytes did not round-trip")
            }
            shouldRemove = false
            return StagedFile(name: name, record: record)
        }
        throw LocalStoreError.operationFailed(
            path: directory.path,
            operation: "allocate staged memory configuration",
            reason: "could not allocate a unique staging name")
    }

    private func removeFileIfMatching(
        in directory: MemoryConfigurationDirectory,
        name: String,
        expected: MemoryConfigurationFileRecord
    ) throws {
        guard
            let observed = try readFile(
                in: directory,
                name: name,
                maximumBytes: expected.data.count),
            observed.hasSameFileAndContent(as: expected),
            let named = try optionalMetadata(
                directory: directory.descriptor.rawValue,
                name: name,
                path: childPath(name)),
            unsigned(named.st_dev) == expected.fingerprint.device,
            unsigned(named.st_ino) == expected.fingerprint.inode
        else { return }
        let result = name.withCString {
            Darwin.unlinkat(directory.descriptor.rawValue, $0, 0)
        }
        guard result == 0 else {
            throw operationError(path: childPath(name), operation: "remove staged configuration")
        }
    }

    private func createChildDirectory(
        parent: Int32,
        name: String,
        path: String
    ) throws -> MemoryConfigurationOwnedFileDescriptor {
        let result = name.withCString { Darwin.mkdirat(parent, $0, 0o700) }
        if result != 0, errno != EEXIST {
            throw operationError(path: path, operation: "create configuration directory")
        }
        guard
            let descriptor = try openChildDirectory(
                parent: parent,
                name: name,
                path: path,
                missingIsAllowed: false)
        else {
            throw LocalStoreError.operationFailed(
                path: path,
                operation: "open configuration directory",
                reason: "new directory disappeared")
        }
        let metadata = try fileMetadata(descriptor.rawValue, path: path)
        guard metadata.st_uid == Darwin.geteuid(), metadata.st_mode & 0o022 == 0 else {
            throw LocalStoreError.unsafePath(
                path: path,
                reason: "new configuration directories must be owner-controlled")
        }
        guard Darwin.fsync(parent) == 0 else {
            throw operationError(path: path, operation: "synchronize configuration parent")
        }
        return descriptor
    }

    private func openChildDirectory(
        parent: Int32,
        name: String,
        path: String,
        missingIsAllowed: Bool
    ) throws -> MemoryConfigurationOwnedFileDescriptor? {
        let descriptor = name.withCString {
            Darwin.openat(
                parent,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            let code = errno
            if missingIsAllowed, code == ENOENT { return nil }
            if code == ELOOP || code == ENOTDIR {
                throw LocalStoreError.unsafePath(
                    path: path,
                    reason: "configuration directory components must not be symbolic links")
            }
            throw operationError(path: path, operation: "open configuration directory", code: code)
        }
        return MemoryConfigurationOwnedFileDescriptor(descriptor)
    }

    private func ownedDirectoryMetadata(_ descriptor: Int32, path: String) throws -> stat {
        let metadata = try fileMetadata(descriptor, path: path)
        guard metadata.st_mode & S_IFMT == S_IFDIR,
            metadata.st_uid == Darwin.geteuid(),
            metadata.st_mode & 0o022 == 0
        else {
            throw LocalStoreError.unsafePath(
                path: path,
                reason: "configuration parent must be an owner-controlled directory")
        }
        return metadata
    }

    private func optionalMetadata(
        directory: Int32,
        name: String,
        path: String
    ) throws -> stat? {
        var metadata = stat()
        let result = name.withCString {
            Darwin.fstatat(directory, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 { return metadata }
        if errno == ENOENT { return nil }
        throw operationError(path: path, operation: "inspect memory configuration entry")
    }

    private func requiredMetadata(
        directory: Int32,
        name: String,
        path: String
    ) throws -> stat {
        guard let metadata = try optionalMetadata(directory: directory, name: name, path: path)
        else {
            throw LocalStoreError.operationFailed(
                path: path,
                operation: "inspect memory configuration entry",
                reason: "entry disappeared")
        }
        return metadata
    }

    private func fileMetadata(_ descriptor: Int32, path: String) throws -> stat {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw operationError(path: path, operation: "inspect open memory configuration entry")
        }
        return metadata
    }

    private func validateOwnerFile(
        _ metadata: stat,
        path: String,
        expectedSize: Int64? = nil
    ) throws {
        guard metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_nlink == 1,
            metadata.st_uid == Darwin.geteuid(),
            mode_t(metadata.st_mode & 0o777) == 0o600,
            expectedSize.map({ metadata.st_size == $0 }) ?? true
        else {
            throw LocalStoreError.unsafePath(
                path: path,
                reason: "configuration files must be single-linked owner-only regular files")
        }
    }

    private func boundedRead(
        descriptor: Int32,
        path: String,
        maximumBytes: Int
    ) throws -> Data {
        var data = Data()
        while true {
            let remaining = maximumBytes - data.count
            let requested = min(64 * 1_024, max(1, remaining + 1))
            var buffer = [UInt8](repeating: 0, count: requested)
            let amount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, requested)
            }
            if amount == 0 { return data }
            if amount < 0 {
                if errno == EINTR { continue }
                throw operationError(path: path, operation: "read memory configuration")
            }
            data.append(contentsOf: buffer.prefix(Int(amount)))
            guard data.count <= maximumBytes else {
                throw LocalStoreError.invalidData(
                    path: path,
                    reason: "configuration file grew beyond the permitted byte count")
            }
        }
    }

    private func writeAll(_ data: Data, descriptor: Int32, path: String) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let amount = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset)
                if amount < 0 {
                    if errno == EINTR { continue }
                    throw operationError(path: path, operation: "write staged configuration")
                }
                guard amount > 0 else {
                    throw LocalStoreError.operationFailed(
                        path: path,
                        operation: "write staged configuration",
                        reason: "write made no progress")
                }
                offset += amount
            }
        }
    }

    private func validateComponent(_ component: String, path: String) throws {
        guard !component.isEmpty, component != ".", component != "..",
            !component.contains("/"), !component.utf8.contains(0)
        else {
            throw LocalStoreError.unsafePath(
                path: path,
                reason: "configuration path contains an unsafe component")
        }
    }

    private func childPath(_ name: String) -> String {
        parentPath + "/" + name
    }

    private func fingerprint(_ metadata: stat, data: Data) -> MemoryConfigurationFileFingerprint {
        MemoryConfigurationFileFingerprint(
            device: unsigned(metadata.st_dev),
            inode: unsigned(metadata.st_ino),
            size: Int64(metadata.st_size),
            modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
            changeSeconds: Int64(metadata.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec),
            contentHash: hexadecimalHash(data))
    }

    private func hexadecimalHash(_ data: Data) -> String {
        let hexadecimal = Array("0123456789abcdef".utf8)
        let bytes = SHA256.hash(data: data).flatMap { byte in
            [hexadecimal[Int(byte >> 4)], hexadecimal[Int(byte & 0x0f)]]
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func directoryIdentity(_ metadata: stat) -> MemoryConfigurationDirectoryIdentity {
        MemoryConfigurationDirectoryIdentity(
            device: unsigned(metadata.st_dev),
            inode: unsigned(metadata.st_ino))
    }

    private func sameNode(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private func stableFile(_ lhs: stat, _ rhs: stat) -> Bool {
        sameNode(lhs, rhs)
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private func unsigned<T: BinaryInteger>(_ value: T) -> UInt64 {
        UInt64(truncatingIfNeeded: value)
    }

    private func operationError(
        path: String,
        operation: String,
        code: Int32 = errno
    ) -> LocalStoreError {
        LocalStoreError.operationFailed(
            path: path,
            operation: operation,
            reason: String(cString: strerror(code)))
    }
}
