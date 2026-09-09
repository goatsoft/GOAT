import CryptoKit
import Darwin
import Foundation
import Herd

struct WikiTimestamp: Sendable, Equatable {
    let seconds: Int64
    let nanoseconds: Int64

    var date: Date {
        Date(
            timeIntervalSince1970: TimeInterval(seconds)
                + TimeInterval(nanoseconds) / 1_000_000_000)
    }

    var timespecValue: timespec {
        timespec(tv_sec: Int(seconds), tv_nsec: Int(nanoseconds))
    }
}

struct WikiDirectoryIdentity: Sendable, Hashable {
    let device: UInt64
    let inode: UInt64
}

struct WikiDirectoryMetadata: Sendable, Equatable {
    let identity: WikiDirectoryIdentity
    let modificationTime: WikiTimestamp
    let changeTime: WikiTimestamp
    let mode: mode_t
}

struct WikiFileFingerprint: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modificationTime: WikiTimestamp
    let changeTime: WikiTimestamp
    let contentHash: String

    func hasSameStagedContent(as other: WikiFileFingerprint) -> Bool {
        size == other.size
            && modificationTime == other.modificationTime
            && contentHash == other.contentHash
    }
}

struct WikiFileRecord: Sendable, Equatable {
    let data: Data
    let fingerprint: WikiFileFingerprint
    let mode: mode_t
}

final class WikiOwnedFileDescriptor {
    let rawValue: Int32

    init(_ rawValue: Int32) {
        self.rawValue = rawValue
    }

    deinit {
        Darwin.close(rawValue)
    }
}

private func setWikiAdvisoryLock(_ descriptor: Int32, type: Int16) -> Int32 {
    var lock = flock()
    lock.l_type = type
    lock.l_whence = Int16(SEEK_SET)
    lock.l_start = 0
    lock.l_len = 0
    return Darwin.fcntl(descriptor, F_SETLK, &lock)
}

private enum WikiProcessWriterLocks {
    private static let condition = NSCondition()
    // Every access to this escape hatch is protected by condition.
    nonisolated(unsafe) private static var held: Set<WikiDirectoryIdentity> = []

    static func acquire(_ identity: WikiDirectoryIdentity, timeout: TimeInterval) throws -> Bool {
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

    static func release(_ identity: WikiDirectoryIdentity) {
        condition.lock()
        held.remove(identity)
        condition.broadcast()
        condition.unlock()
    }
}

final class WikiWriterLock {
    private let descriptor: WikiOwnedFileDescriptor
    private let rootIdentity: WikiDirectoryIdentity

    init(descriptor: WikiOwnedFileDescriptor, rootIdentity: WikiDirectoryIdentity) {
        self.descriptor = descriptor
        self.rootIdentity = rootIdentity
    }

    deinit {
        _ = setWikiAdvisoryLock(descriptor.rawValue, type: Int16(F_UNLCK))
        WikiProcessWriterLocks.release(rootIdentity)
    }
}

struct WikiScopeLocation {
    let root: WikiOwnedFileDescriptor
    let projectParent: WikiOwnedFileDescriptor?
    let scope: WikiOwnedFileDescriptor?
    let rootIdentity: WikiDirectoryIdentity
    let parentIdentity: WikiDirectoryIdentity
    let destinationName: String
    let parentPath: String
    let scopePath: String

    var parentDescriptor: Int32 {
        projectParent?.rawValue ?? root.rawValue
    }
}

struct WikiCreatedDirectory {
    let name: String
    let descriptor: WikiOwnedFileDescriptor
    let path: String
}

/// Directory-descriptor based file operations for the human-editable wiki boundary.
///
/// Absolute paths are used only for diagnostics. After opening `/`, every traversal, read,
/// creation, publication, and cleanup is relative to an already validated directory descriptor.
struct SecureWikiFileSystem {
    let root: URL
    let globalDirectoryName: String

    init(root: URL, globalDirectoryName: String = "global") {
        self.root = root
        self.globalDirectoryName = globalDirectoryName
    }

    func locate(_ scope: MemoryScope, createParents: Bool) throws -> WikiScopeLocation? {
        guard let rootDescriptor = try openRoot(create: createParents) else { return nil }
        let rootMetadata = try directoryMetadata(
            descriptor: rootDescriptor.rawValue,
            path: root.path)

        switch scope {
        case .global:
            let name = globalDirectoryName
            let path = root.appendingPathComponent(name, isDirectory: true).path
            let scopeDescriptor = try openChildDirectory(
                parent: rootDescriptor.rawValue,
                name: name,
                path: path,
                missingIsAllowed: true)
            return WikiScopeLocation(
                root: rootDescriptor,
                projectParent: nil,
                scope: scopeDescriptor,
                rootIdentity: rootMetadata.identity,
                parentIdentity: rootMetadata.identity,
                destinationName: name,
                parentPath: root.path,
                scopePath: path)

        case .project(let id):
            let projectsPath = root.appendingPathComponent("projects", isDirectory: true).path
            let projects: WikiOwnedFileDescriptor
            if let existing = try openChildDirectory(
                parent: rootDescriptor.rawValue,
                name: "projects",
                path: projectsPath,
                missingIsAllowed: true)
            {
                projects = existing
            } else if createParents {
                projects = try createChildDirectory(
                    parent: rootDescriptor.rawValue,
                    name: "projects",
                    path: projectsPath,
                    mode: 0o700)
                try syncDirectory(rootDescriptor.rawValue, path: root.path)
            } else {
                return nil
            }

            let name = id.uuidString
            let path = root.appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true).path
            let scopeDescriptor = try openChildDirectory(
                parent: projects.rawValue,
                name: name,
                path: path,
                missingIsAllowed: true)
            let parentIdentity = try directoryMetadata(
                descriptor: projects.rawValue,
                path: projectsPath
            ).identity
            return WikiScopeLocation(
                root: rootDescriptor,
                projectParent: projects,
                scope: scopeDescriptor,
                rootIdentity: rootMetadata.identity,
                parentIdentity: parentIdentity,
                destinationName: name,
                parentPath: projectsPath,
                scopePath: path)
        }
    }

    func locationIsCurrent(_ location: WikiScopeLocation) throws -> Bool {
        guard let descriptor = try openRoot(create: false) else { return false }
        guard
            try directoryMetadata(descriptor: descriptor.rawValue, path: root.path).identity
                == location.rootIdentity
        else { return false }
        guard location.projectParent != nil else {
            return location.parentIdentity == location.rootIdentity
        }
        let projectsPath = root.appendingPathComponent("projects", isDirectory: true).path
        guard
            let projects = try openChildDirectory(
                parent: descriptor.rawValue,
                name: "projects",
                path: projectsPath,
                missingIsAllowed: true)
        else { return false }
        return try directoryMetadata(descriptor: projects.rawValue, path: projectsPath).identity
            == location.parentIdentity
    }

    func acquireWriterLock(
        rootDescriptor: Int32,
        rootIdentity: WikiDirectoryIdentity,
        rootPath: String
    ) throws -> WikiWriterLock {
        guard try WikiProcessWriterLocks.acquire(rootIdentity, timeout: 5) else {
            throw MemoryStoreError.conflict(
                name: "MEMORY.md",
                reason: "timed out waiting for another memory writer")
        }
        var processLockNeedsRelease = true
        var fileLockNeedsRelease = false
        var lockDescriptor: WikiOwnedFileDescriptor?
        defer {
            if fileLockNeedsRelease, let lockDescriptor {
                _ = setWikiAdvisoryLock(
                    lockDescriptor.rawValue,
                    type: Int16(F_UNLCK))
            }
            if processLockNeedsRelease {
                WikiProcessWriterLocks.release(rootIdentity)
            }
        }

        let name = ".goat-memory.lock"
        let path = URL(fileURLWithPath: rootPath).appendingPathComponent(name).path
        var created = false
        var existingBeforeOpen: stat?
        var rawDescriptor = name.withCString {
            Darwin.openat(
                rootDescriptor,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC,
                mode_t(0o600))
        }
        if rawDescriptor >= 0 {
            created = true
        } else if errno == EEXIST {
            let existing = try metadataAt(
                directory: rootDescriptor,
                name: name,
                path: path)
            guard existing.st_mode & S_IFMT == S_IFREG, existing.st_nlink == 1,
                existing.st_uid == Darwin.geteuid(), existing.st_size == 0,
                mode_t(existing.st_mode & 0o777) == 0o600
            else {
                throw LocalStoreError.unsafePath(
                    path: path,
                    reason: "memory writer lock must be one owner-controlled regular file")
            }
            existingBeforeOpen = existing
            rawDescriptor = name.withCString {
                Darwin.openat(
                    rootDescriptor,
                    $0,
                    O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            }
        }
        guard rawDescriptor >= 0 else {
            if errno == ELOOP {
                throw LocalStoreError.unsafePath(
                    path: path,
                    reason: "memory writer lock must not be a symbolic link")
            }
            throw operationError(path: path, operation: "open memory writer lock")
        }
        let descriptor = WikiOwnedFileDescriptor(rawDescriptor)
        lockDescriptor = descriptor
        let opened = try fileMetadata(descriptor: descriptor.rawValue, path: path)
        let namedBeforeLock = try metadataAt(
            directory: rootDescriptor,
            name: name,
            path: path)
        guard opened.st_mode & S_IFMT == S_IFREG, opened.st_nlink == 1,
            opened.st_uid == Darwin.geteuid(), opened.st_size == 0,
            sameNode(opened, namedBeforeLock),
            existingBeforeOpen.map({ sameNode($0, opened) }) ?? true,
            created || mode_t(opened.st_mode & 0o777) == 0o600
        else {
            throw LocalStoreError.unsafePath(
                path: path,
                reason: "memory writer lock must be one owner-controlled regular file")
        }

        var acquired = false
        for _ in 0..<500 {
            try Task.checkCancellation()
            if setWikiAdvisoryLock(descriptor.rawValue, type: Int16(F_WRLCK)) == 0 {
                acquired = true
                break
            }
            let code = errno
            if code != EACCES && code != EAGAIN {
                throw operationError(path: path, operation: "lock memory writer", code: code)
            }
            Darwin.usleep(10_000)
        }
        guard acquired else {
            throw MemoryStoreError.conflict(
                name: "MEMORY.md",
                reason: "timed out waiting for a memory writer in another process")
        }
        fileLockNeedsRelease = true

        if created {
            guard Darwin.fchmod(descriptor.rawValue, 0o600) == 0,
                Darwin.fsync(descriptor.rawValue) == 0
            else {
                throw operationError(path: path, operation: "secure memory writer lock")
            }
            try syncDirectory(rootDescriptor, path: rootPath)
        }

        let named = try metadataAt(
            directory: rootDescriptor,
            name: name,
            path: path)
        let locked = try fileMetadata(descriptor: descriptor.rawValue, path: path)
        guard sameNode(locked, named),
            locked.st_mode & S_IFMT == S_IFREG,
            locked.st_nlink == 1,
            locked.st_uid == Darwin.geteuid(),
            locked.st_size == 0,
            mode_t(locked.st_mode & 0o777) == 0o600
        else {
            throw LocalStoreError.unsafePath(
                path: path,
                reason: "memory writer lock changed identity while locking")
        }

        fileLockNeedsRelease = false
        processLockNeedsRelease = false
        return WikiWriterLock(descriptor: descriptor, rootIdentity: rootIdentity)
    }

    func entryNames(
        descriptor: Int32,
        path: String,
        maximumEntries: Int
    ) throws -> [String] {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0 else {
            throw operationError(path: path, operation: "duplicate directory descriptor")
        }
        guard let directory = Darwin.fdopendir(duplicate) else {
            let code = errno
            Darwin.close(duplicate)
            throw operationError(path: path, operation: "open directory stream", code: code)
        }
        defer { Darwin.closedir(directory) }
        Darwin.rewinddir(directory)

        var names: [String] = []
        while true {
            errno = 0
            guard let entry = Darwin.readdir(directory) else {
                let code = errno
                if code != 0 {
                    throw operationError(path: path, operation: "read directory stream", code: code)
                }
                break
            }
            var value = entry.pointee
            let rawName = withUnsafeBytes(of: &value.d_name) { Array($0) }
            let name = try Self.decodeDirectoryEntryName(rawName, path: path)
            if name == "." || name == ".." { continue }
            guard names.count < maximumEntries else {
                throw MemoryStoreError.capacityExceeded(
                    path: path,
                    reason: "scope contains too many entries")
            }
            names.append(name)
        }
        return names.sorted()
    }

    static func decodeDirectoryEntryName(_ bytes: [UInt8], path: String) throws -> String {
        guard let terminator = bytes.firstIndex(of: 0),
            let name = String(bytes: bytes[..<terminator], encoding: .utf8)
        else {
            throw LocalStoreError.unsafePath(
                path: path,
                reason: "memory scope contains an invalid UTF-8 filename")
        }
        return name
    }

    func readFile(
        directory: Int32,
        name: String,
        directoryPath: String,
        maximumBytes: Int
    ) throws -> WikiFileRecord {
        try validateComponent(name, path: directoryPath)
        let path = URL(fileURLWithPath: directoryPath).appendingPathComponent(name).path
        let namedBefore = try metadataAt(
            directory: directory,
            name: name,
            path: path)
        guard namedBefore.st_mode & S_IFMT == S_IFREG, namedBefore.st_nlink == 1 else {
            throw LocalStoreError.unsafePath(
                path: path,
                reason: "memory scope entries must be unlinked regular files")
        }
        guard namedBefore.st_uid == Darwin.geteuid(), namedBefore.st_mode & 0o022 == 0 else {
            throw LocalStoreError.unsafePath(
                path: path,
                reason: "memory scope entries must be owner-controlled")
        }

        let rawDescriptor = name.withCString {
            Darwin.openat(
                directory,
                $0,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard rawDescriptor >= 0 else {
            throw operationError(path: path, operation: "open memory entry")
        }
        let descriptor = WikiOwnedFileDescriptor(rawDescriptor)
        let before = try fileMetadata(descriptor: descriptor.rawValue, path: path)
        guard before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
            before.st_uid == Darwin.geteuid(), before.st_mode & 0o022 == 0,
            sameNode(namedBefore, before)
        else {
            throw LocalStoreError.unsafePath(
                path: path,
                reason: "memory entry changed identity before it could be read")
        }
        guard before.st_size >= 0, UInt64(before.st_size) <= UInt64(maximumBytes) else {
            throw MemoryStoreError.capacityExceeded(
                path: path,
                reason: "file exceeds \(maximumBytes) bytes")
        }

        let data = try boundedRead(
            descriptor: descriptor.rawValue,
            path: path,
            maximumBytes: maximumBytes)
        let after = try fileMetadata(descriptor: descriptor.rawValue, path: path)
        let namedAfter = try metadataAt(
            directory: directory,
            name: name,
            path: path)
        guard stableFile(before, after), sameNode(after, namedAfter),
            after.st_uid == Darwin.geteuid(), after.st_mode & 0o022 == 0
        else {
            throw MemoryStoreError.conflict(
                name: name,
                reason: "the file changed while it was being read")
        }

        return WikiFileRecord(
            data: data,
            fingerprint: WikiFileFingerprint(
                device: unsigned(after.st_dev),
                inode: unsigned(after.st_ino),
                size: Int64(after.st_size),
                modificationTime: timestamp(after.st_mtimespec),
                changeTime: timestamp(after.st_ctimespec),
                contentHash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()),
            mode: mode_t(after.st_mode & 0o777))
    }

    @discardableResult
    func createFile(
        directory: Int32,
        name: String,
        directoryPath: String,
        data: Data,
        mode: mode_t = 0o600,
        preservingModificationTime: WikiTimestamp? = nil
    ) throws -> WikiFileRecord {
        try validateComponent(name, path: directoryPath)
        let path = URL(fileURLWithPath: directoryPath).appendingPathComponent(name).path
        let rawDescriptor = name.withCString {
            Darwin.openat(
                directory,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode)
        }
        guard rawDescriptor >= 0 else {
            throw operationError(path: path, operation: "create staged memory entry")
        }
        let descriptor = WikiOwnedFileDescriptor(rawDescriptor)

        try writeAll(data, descriptor: descriptor.rawValue, path: path)
        guard Darwin.fchmod(descriptor.rawValue, mode) == 0 else {
            throw operationError(path: path, operation: "set staged memory permissions")
        }
        if let preservingModificationTime {
            var times = [
                preservingModificationTime.timespecValue,
                preservingModificationTime.timespecValue,
            ]
            let result = times.withUnsafeMutableBufferPointer {
                Darwin.futimens(descriptor.rawValue, $0.baseAddress)
            }
            guard result == 0 else {
                throw operationError(path: path, operation: "preserve staged memory timestamp")
            }
        }
        guard Darwin.fsync(descriptor.rawValue) == 0 else {
            throw operationError(path: path, operation: "synchronize staged memory entry")
        }
        return try readFile(
            directory: directory,
            name: name,
            directoryPath: directoryPath,
            maximumBytes: max(data.count, 1))
    }

    func createStagingDirectory(
        parent: Int32,
        parentPath: String
    ) throws -> WikiCreatedDirectory {
        for _ in 0..<16 {
            let name = ".goat-memory-stage-\(UUID().uuidString.lowercased())"
            let path = URL(fileURLWithPath: parentPath)
                .appendingPathComponent(name, isDirectory: true).path
            let result = name.withCString { Darwin.mkdirat(parent, $0, 0o700) }
            if result == 0 {
                guard
                    let descriptor = try openChildDirectory(
                        parent: parent,
                        name: name,
                        path: path,
                        missingIsAllowed: false)
                else {
                    throw LocalStoreError.operationFailed(
                        path: path,
                        operation: "open staging directory",
                        reason: "new directory disappeared")
                }
                return WikiCreatedDirectory(name: name, descriptor: descriptor, path: path)
            }
            if errno != EEXIST {
                throw operationError(path: path, operation: "create staging directory")
            }
        }
        throw LocalStoreError.operationFailed(
            path: parentPath,
            operation: "create staging directory",
            reason: "could not allocate a unique staging name")
    }

    func setDirectoryMode(_ descriptor: Int32, mode: mode_t, path: String) throws {
        guard Darwin.fchmod(descriptor, mode) == 0 else {
            throw operationError(path: path, operation: "set memory directory permissions")
        }
    }

    func syncDirectory(_ descriptor: Int32, path: String) throws {
        guard Darwin.fsync(descriptor) == 0 else {
            throw operationError(path: path, operation: "synchronize directory")
        }
    }

    func publishNew(
        parent: Int32,
        parentPath: String,
        stagingName: String,
        destinationName: String
    ) throws {
        let result = stagingName.withCString { source in
            destinationName.withCString { destination in
                Darwin.renameatx_np(
                    parent,
                    source,
                    parent,
                    destination,
                    UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            let code = errno
            if code == EEXIST {
                throw MemoryStoreError.conflict(
                    name: destinationName,
                    reason: "the scope appeared before exclusive publication")
            }
            throw operationError(
                path: parentPath,
                operation: "publish new memory scope",
                code: code)
        }
    }

    func exchange(
        parent: Int32,
        parentPath: String,
        first: String,
        second: String
    ) throws {
        let result = first.withCString { firstName in
            second.withCString { secondName in
                Darwin.renameatx_np(
                    parent,
                    firstName,
                    parent,
                    secondName,
                    UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else {
            throw operationError(path: parentPath, operation: "exchange memory scope")
        }
    }

    func openSiblingDirectory(
        parent: Int32,
        parentPath: String,
        name: String
    ) throws -> WikiOwnedFileDescriptor {
        let path = URL(fileURLWithPath: parentPath)
            .appendingPathComponent(name, isDirectory: true).path
        guard
            let descriptor = try openChildDirectory(
                parent: parent,
                name: name,
                path: path,
                missingIsAllowed: false)
        else {
            throw LocalStoreError.operationFailed(
                path: path,
                operation: "open exchanged memory scope",
                reason: "directory disappeared")
        }
        return descriptor
    }

    func siblingDirectoryIdentity(
        parent: Int32,
        parentPath: String,
        name: String
    ) throws -> WikiDirectoryIdentity {
        try directoryIdentityAt(
            parent: parent,
            name: name,
            path: URL(fileURLWithPath: parentPath)
                .appendingPathComponent(name, isDirectory: true).path)
    }

    /// Removes only the exact captured tree. POSIX cannot prevent a same-UID process with an
    /// already-open writable descriptor from changing a file between the final check and unlink,
    /// so human editors must coordinate with publication and hidden-backup maintenance.
    func removeFlatDirectory(
        parent: Int32,
        parentPath: String,
        name: String,
        maximumEntries: Int,
        expectedIdentity: WikiDirectoryIdentity,
        expectedEntries: [String: WikiFileFingerprint]
    ) throws {
        let path = URL(fileURLWithPath: parentPath)
            .appendingPathComponent(name, isDirectory: true).path
        let directory = try openSiblingDirectory(parent: parent, parentPath: parentPath, name: name)
        let openedIdentity = try directoryMetadata(
            descriptor: directory.rawValue,
            path: path
        ).identity
        guard openedIdentity == expectedIdentity,
            try directoryIdentityAt(parent: parent, name: name, path: path) == expectedIdentity
        else {
            throw LocalStoreError.unsafePath(
                path: path,
                reason: "recovery directory changed identity before cleanup")
        }
        let names = try entryNames(
            descriptor: directory.rawValue,
            path: path,
            maximumEntries: maximumEntries)

        guard Set(names) == Set(expectedEntries.keys) else {
            throw LocalStoreError.unsafePath(
                path: path,
                reason: "recovery directory entries changed before cleanup")
        }
        for child in names {
            guard let expected = expectedEntries[child],
                let maximumBytes = Int(exactly: expected.size)
            else {
                throw LocalStoreError.unsafePath(
                    path: path,
                    reason: "recovery directory contains an invalid expected entry")
            }
            let observed = try readFile(
                directory: directory.rawValue,
                name: child,
                directoryPath: path,
                maximumBytes: maximumBytes)
            guard observed.fingerprint == expected else {
                throw LocalStoreError.unsafePath(
                    path: URL(fileURLWithPath: path).appendingPathComponent(child).path,
                    reason: "recovery entry changed before cleanup")
            }
        }

        for child in names {
            let childPath = URL(fileURLWithPath: path).appendingPathComponent(child).path
            guard let expected = expectedEntries[child],
                let maximumBytes = Int(exactly: expected.size)
            else {
                throw LocalStoreError.unsafePath(
                    path: path,
                    reason: "recovery directory contains an invalid expected entry")
            }
            let observed = try readFile(
                directory: directory.rawValue,
                name: child,
                directoryPath: path,
                maximumBytes: maximumBytes)
            guard observed.fingerprint == expected else {
                throw LocalStoreError.unsafePath(
                    path: childPath,
                    reason: "recovery entry changed immediately before cleanup")
            }
            let result = child.withCString { Darwin.unlinkat(directory.rawValue, $0, 0) }
            guard result == 0 else {
                throw operationError(
                    path: URL(fileURLWithPath: path).appendingPathComponent(child).path,
                    operation: "remove exchanged memory entry")
            }
        }
        try syncDirectory(directory.rawValue, path: path)
        guard try directoryIdentityAt(parent: parent, name: name, path: path) == expectedIdentity else {
            throw LocalStoreError.unsafePath(
                path: path,
                reason: "recovery directory changed identity during cleanup")
        }
        let result = name.withCString { Darwin.unlinkat(parent, $0, AT_REMOVEDIR) }
        guard result == 0 else {
            throw operationError(path: path, operation: "remove exchanged memory directory")
        }
    }

    func directoryMetadata(descriptor: Int32, path: String) throws -> WikiDirectoryMetadata {
        let metadata = try fileMetadata(descriptor: descriptor, path: path)
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw LocalStoreError.unsafePath(path: path, reason: "expected a directory")
        }
        guard metadata.st_uid == Darwin.geteuid(), metadata.st_mode & 0o022 == 0 else {
            throw LocalStoreError.unsafePath(
                path: path,
                reason: "memory directories must be owner-controlled and not group/world writable")
        }
        return WikiDirectoryMetadata(
            identity: WikiDirectoryIdentity(
                device: unsigned(metadata.st_dev),
                inode: unsigned(metadata.st_ino)),
            modificationTime: timestamp(metadata.st_mtimespec),
            changeTime: timestamp(metadata.st_ctimespec),
            mode: mode_t(metadata.st_mode & 0o777))
    }

    private func openRoot(create: Bool) throws -> WikiOwnedFileDescriptor? {
        let path = root.path
        guard path.hasPrefix("/"), path != "/", !path.utf8.contains(0) else {
            throw LocalStoreError.unsafePath(
                path: path,
                reason: "memory root must be a non-root absolute path")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var current = WikiOwnedFileDescriptor(
            Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
        guard current.rawValue >= 0 else {
            throw operationError(path: "/", operation: "open filesystem root")
        }
        var traversed = ""

        for (index, component) in components.enumerated() {
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
                path: traversed,
                mode: index == components.indices.last ? 0o700 : 0o755)
        }
        return current
    }

    private func createChildDirectory(
        parent: Int32,
        name: String,
        path: String,
        mode: mode_t
    ) throws -> WikiOwnedFileDescriptor {
        let result = name.withCString { Darwin.mkdirat(parent, $0, mode) }
        if result != 0, errno != EEXIST {
            throw operationError(path: path, operation: "create directory")
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
                operation: "open created directory",
                reason: "directory disappeared")
        }
        try syncDirectory(parent, path: URL(fileURLWithPath: path).deletingLastPathComponent().path)
        return descriptor
    }

    private func openChildDirectory(
        parent: Int32,
        name: String,
        path: String,
        missingIsAllowed: Bool
    ) throws -> WikiOwnedFileDescriptor? {
        try validateComponent(name, path: path)
        let rawDescriptor = name.withCString {
            Darwin.openat(
                parent,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard rawDescriptor >= 0 else {
            let code = errno
            if missingIsAllowed, code == ENOENT { return nil }
            if code == ELOOP || code == ENOTDIR {
                throw LocalStoreError.unsafePath(
                    path: path,
                    reason: "directory components must not be symbolic links")
            }
            throw operationError(path: path, operation: "open directory", code: code)
        }
        return WikiOwnedFileDescriptor(rawDescriptor)
    }

    private func metadataAt(
        directory: Int32,
        name: String,
        path: String
    ) throws -> stat {
        var metadata = stat()
        let result = name.withCString {
            Darwin.fstatat(directory, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            throw operationError(path: path, operation: "inspect memory entry")
        }
        return metadata
    }

    private func directoryIdentityAt(
        parent: Int32,
        name: String,
        path: String
    ) throws -> WikiDirectoryIdentity {
        let metadata = try metadataAt(directory: parent, name: name, path: path)
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw LocalStoreError.unsafePath(
                path: path,
                reason: "expected a real recovery directory")
        }
        return WikiDirectoryIdentity(
            device: unsigned(metadata.st_dev),
            inode: unsigned(metadata.st_ino))
    }

    private func fileMetadata(descriptor: Int32, path: String) throws -> stat {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw operationError(path: path, operation: "inspect open memory entry")
        }
        return metadata
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
                throw operationError(path: path, operation: "read memory entry")
            }
            data.append(contentsOf: buffer.prefix(Int(amount)))
            guard data.count <= maximumBytes else {
                throw MemoryStoreError.capacityExceeded(
                    path: path,
                    reason: "file grew beyond \(maximumBytes) bytes while reading")
            }
        }
    }

    private func writeAll(_ data: Data, descriptor: Int32, path: String) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw operationError(path: path, operation: "write staged memory entry")
                }
                guard written > 0 else {
                    throw LocalStoreError.operationFailed(
                        path: path,
                        operation: "write staged memory entry",
                        reason: "write made no progress")
                }
                offset += written
            }
        }
    }

    private func validateComponent(_ component: String, path: String) throws {
        guard !component.isEmpty, component != ".", component != "..",
            !component.contains("/"), !component.utf8.contains(0)
        else {
            throw LocalStoreError.unsafePath(
                path: path,
                reason: "path contains an unsafe component")
        }
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

    private func timestamp(_ value: timespec) -> WikiTimestamp {
        WikiTimestamp(
            seconds: Int64(value.tv_sec),
            nanoseconds: Int64(value.tv_nsec))
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
