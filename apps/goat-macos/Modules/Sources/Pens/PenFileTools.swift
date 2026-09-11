import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import Tools

/// One turn's authority over one user-configured workspace. Blocking file work stays on this actor.
public actor PenFileTools {
    public static let maximumFileBytes = 1_024 * 1_024
    private static let maximumReadBytes = 32 * 1_024
    public static let schemas: [ToolSchema] = [
        ToolSchema(
            name: "pen_list_files",
            description:
                "List a sorted page of up to 200 Pen directory entries. Use '.' for the workspace root. If next_after is present, pass it as after for the next page; narrow directories above 20,000 entries.",
            inputSchemaJSON:
                #"{"type":"object","properties":{"path":{"type":"string"},"after":{"type":"string","maxLength":4096}},"required":["path"],"additionalProperties":false}"#
        ),
        ToolSchema(
            name: "pen_read_file",
            description:
                "Read a UTF-8 Pen file up to 1 MiB. Returns exact content for up to 200 lines and 32 KiB. Use next_start_line to continue a truncated read. Line numbers are 1-based; old_text for edits must come from content, not metadata.",
            inputSchemaJSON:
                #"{"type":"object","properties":{"path":{"type":"string"},"start_line":{"type":"integer","minimum":1},"line_count":{"type":"integer","minimum":1,"maximum":200}},"required":["path"],"additionalProperties":false}"#
        ),
        ToolSchema(
            name: "pen_search",
            description:
                "Search literal text in UTF-8 Pen files. Returns matching paths, 1-based line numbers and snippets. file_glob matches filenames (for example '*.vue'); case_sensitive defaults to true. Skips symlinks, .git and generated/dependency directories. Results and scanning are bounded; narrow path or query when truncated. Use pen_read_file before editing a match.",
            inputSchemaJSON:
                #"{"type":"object","properties":{"path":{"type":"string"},"query":{"type":"string","minLength":1,"maxLength":512},"file_glob":{"type":"string","maxLength":256},"case_sensitive":{"type":"boolean"},"max_results":{"type":"integer","minimum":1,"maximum":100}},"required":["path","query"],"additionalProperties":false}"#
        ),
        ToolSchema(
            name: "pen_write_file",
            description:
                "Create a new UTF-8 file in the Pen, including missing parent directories, after user approval. Pass the actual file content as a JSON string. Existing files are never overwritten; use pen_edit_file instead. Paths are workspace-relative. Keep each encoded tool call below 64 KiB; use focused edits for larger files.",
            inputSchemaJSON:
                #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"],"additionalProperties":false}"#
        ),
        ToolSchema(
            name: "pen_edit_file",
            description:
                "Replace one exact, unique occurrence of old_text with new_text in a Pen file after user approval. Read the file first and copy old_text from that result; never guess it. new_text must differ from old_text. Use a small unique fragment, preserving unrelated content. Paths are workspace-relative; ambiguous matches and changes during approval fail without writing.",
            inputSchemaJSON:
                #"{"type":"object","properties":{"path":{"type":"string"},"old_text":{"type":"string"},"new_text":{"type":"string"}},"required":["path","old_text","new_text"],"additionalProperties":false}"#
        ),
    ]

    public struct PreparedWrite: Sendable {
        fileprivate let owner: UUID
        fileprivate let path: String
        fileprivate let original: Data?
        fileprivate let replacement: Data
        fileprivate let mode: mode_t
        public let previewJSON: String
    }

    private let identity = UUID()
    private let rootPath: String
    private let root: Descriptor
    /// Durable grants bind to this physical folder, not merely a reusable path or Pen name.
    public nonisolated let workspaceIdentity: String

    public init(workspace: URL) throws {
        guard let resolved = realpath(workspace.path, nil) else { throw Failure("Pen folder is unavailable.") }
        defer { free(resolved) }
        rootPath = String(cString: resolved)
        guard rootPath != "/" else { throw Failure("Choose a project folder, not the filesystem root.") }
        root = try Self.openDirectory(rootPath)
        var info = stat()
        guard fstat(root.raw, &info) == 0 else { throw Failure("Pen folder identity is unavailable.") }
        workspaceIdentity =
            "\(rootPath)|\(info.st_dev)|\(info.st_ino)|\(info.st_birthtimespec.tv_sec)|\(info.st_birthtimespec.tv_nsec)"
    }

    public nonisolated var workspacePath: String { rootPath }

    public func validateWorkspace() throws { try validateRoot() }

    public func read(tool: String, argumentsJSON: String) throws -> ToolResult {
        try Task.checkCancellation()
        try validateRoot()
        guard argumentsJSON.utf8.count <= 65_536,
            let args = try JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any],
            let path = args["path"] as? String
        else { throw Failure("Supply the documented JSON fields and a workspace-relative path.") }
        switch tool {
        case "pen_list_files":
            try validateKeys(args, allowed: ["path", "after"])
            if let after = args["after"], !(after is String) {
                throw Failure("after must be a string from next_after.")
            }
            let parts = try components(path, allowRoot: true)
            let entries = try directoryEntries(parts).map { $0.displayName }.sorted()
            let remaining = entries.filter { $0 > (args["after"] as? String ?? "") }
            var page: [String] = []
            var pageBytes = 0
            for name in remaining.prefix(200) {
                let size = try JSONEncoder().encode(name).count
                guard pageBytes + size <= 64 * 1_024 else { break }
                page.append(name)
                pageBytes += size
            }
            var result: [String: Any] = ["path": path, "entries": page, "truncated": remaining.count > page.count]
            if remaining.count > page.count { result["next_after"] = page.last }
            return ToolResult(content: try json(result))
        case "pen_read_file":
            try validateKeys(args, allowed: ["path", "start_line", "line_count"])
            let start = try integer(args, key: "start_line", fallback: 1, range: 1...Int.max)
            let count = try integer(args, key: "line_count", fallback: 200, range: 1...200)
            let (data, _) = try readFile(components(path))
            guard let content = String(data: data, encoding: .utf8) else { throw Failure("File is not UTF-8 text.") }
            let lines = Self.lines(content)
            guard start <= max(1, lines.count) else {
                throw Failure("start_line exceeds this file's \(lines.count) lines.")
            }
            var excerpt = ""
            var end = start - 1
            for line in lines.dropFirst(start - 1).prefix(count) {
                guard line.utf8.count <= Self.maximumReadBytes else {
                    if excerpt.isEmpty {
                        throw Failure(
                            "Line \(start) exceeds the 32 KiB read limit. Use pen_search to locate a smaller source file; this may be generated or minified content."
                        )
                    }
                    break
                }
                guard excerpt.utf8.count + line.utf8.count <= Self.maximumReadBytes else { break }
                excerpt += line
                end += 1
            }
            var result: [String: Any] = [
                "path": path, "content": excerpt, "start_line": start,
                "end_line": end, "total_lines": lines.count, "truncated": end < lines.count,
            ]
            if end < lines.count { result["next_start_line"] = end + 1 }
            return ToolResult(
                content: try json(result),
                diagnostic: ToolExecutionDiagnostic(fileObservations: [
                    FileOperationObservation(
                        workspaceIdentity: workspaceIdentity, relativePath: path, kind: .read,
                        outcome: .succeeded, afterDigest: Self.digest(data))
                ]))
        case "pen_search":
            try validateKeys(args, allowed: ["path", "query", "file_glob", "case_sensitive", "max_results"])
            guard let query = args["query"] as? String, !query.isEmpty, query.unicodeScalars.count <= 512 else {
                throw Failure("query must be literal text between 1 and 512 characters.")
            }
            let glob = args["file_glob"] as? String ?? "*"
            guard args["file_glob"] == nil || args["file_glob"] is String, glob.utf8.count <= 1024, !glob.contains("\0")
            else {
                throw Failure("file_glob must be a filename pattern such as '*.swift'.")
            }
            var sensitive = true
            if let value = args["case_sensitive"] {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw Failure("case_sensitive must be true or false.")
                }
                sensitive = number.boolValue
            }
            return try search(
                path: path, query: query, glob: glob, sensitive: sensitive,
                limit: integer(args, key: "max_results", fallback: 50, range: 1...100))
        default: throw Failure("Unknown Pen read tool.")
        }
    }

    private struct DirectoryEntry {
        let name: String
        let directory: Bool
        let regular: Bool
        var displayName: String { name + (directory ? "/" : "") }
    }

    private func directoryEntries(_ parts: [String]) throws -> [DirectoryEntry] {
        let directory = try traverse(parts)
        let duplicate = openat(directory.raw, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard duplicate >= 0 else { throw failure("Open directory") }
        guard let stream = fdopendir(duplicate) else {
            Darwin.close(duplicate)
            throw failure("List directory")
        }
        defer { closedir(stream) }
        var entries: [DirectoryEntry] = []
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let item = readdir(stream) else {
                guard errno == 0 else { throw failure("List directory") }
                break
            }
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            guard entries.count < 20_000 else {
                throw Failure("Directory exceeds 20,000 entries. Narrow the path to a source directory.")
            }
            var info = stat()
            let known = fstatat(directory.raw, name, &info, AT_SYMLINK_NOFOLLOW) == 0
            entries.append(
                DirectoryEntry(
                    name: name, directory: known && (info.st_mode & S_IFMT) == S_IFDIR,
                    regular: known && (info.st_mode & S_IFMT) == S_IFREG && info.st_nlink == 1))
        }
        return entries.sorted { $0.displayName < $1.displayName }
    }

    private func search(path: String, query: String, glob: String, sensitive: Bool, limit: Int) throws -> ToolResult {
        let excluded: Set<String> = [
            ".git", "node_modules", ".build", "dist", "build", ".next", ".venv", "venv", "__pycache__",
        ]
        var directories = [try components(path, allowRoot: true)]
        var matches: [[String: Any]] = []
        var matchBytes = 0
        var scannedFiles = 0
        var scannedEntries = 0
        var readBytes = 0
        var skippedFiles = 0
        var truncated = false
        search: while let parts = directories.popLast() {
            try Task.checkCancellation()
            let entries: [DirectoryEntry]
            do { entries = try directoryEntries(parts) } catch is CancellationError { throw CancellationError() } catch
            {
                if parts == (try components(path, allowRoot: true)) { throw error }
                skippedFiles += 1
                continue
            }
            for entry in entries {
                try Task.checkCancellation()
                scannedEntries += 1
                guard scannedEntries <= 10_000, scannedFiles < 1_000, readBytes < 16 * 1_024 * 1_024 else {
                    truncated = true
                    break search
                }
                guard entry.name.lowercased() != ".git" else { continue }
                let child = parts + [entry.name]
                guard child.joined(separator: "/").utf8.count <= 4_096 else {
                    skippedFiles += 1
                    continue
                }
                if entry.directory {
                    if !excluded.contains(entry.name), child.count <= 32 {
                        directories.append(child)
                    } else {
                        skippedFiles += 1
                    }
                    continue
                }
                guard entry.regular, fnmatch(glob, entry.name, 0) == 0 else { continue }
                scannedFiles += 1
                let data: Data
                do { data = try readFile(child).0 } catch is CancellationError { throw CancellationError() } catch {
                    skippedFiles += 1
                    continue
                }
                readBytes += data.count
                guard let content = String(data: data, encoding: .utf8) else {
                    skippedFiles += 1
                    continue
                }
                for (index, line) in Self.lines(content).enumerated() {
                    if line.range(of: query, options: sensitive ? [.literal] : [.literal, .caseInsensitive]) != nil {
                        guard matches.count < limit else {
                            truncated = true
                            break search
                        }
                        let match: [String: Any] = [
                            "path": child.joined(separator: "/"), "line": index + 1,
                            "snippet": String(line.unicodeScalars.prefix(240)).trimmingCharacters(in: .newlines),
                        ]
                        let size = try JSONSerialization.data(withJSONObject: match).count
                        guard matchBytes + size <= 64 * 1_024 else {
                            truncated = true
                            break search
                        }
                        matches.append(match)
                        matchBytes += size
                    }
                }
            }
        }
        return ToolResult(
            content: try json([
                "matches": matches, "truncated": truncated,
                "scanned_files": scannedFiles, "skipped_entries": skippedFiles,
                "guidance":
                    "Search is literal and bounded. Read exact file content before editing; narrow path or query if truncated. Generated and dependency directories and .git are excluded.",
            ]))
    }

    private static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let pieces = text.utf8.split(separator: 10, omittingEmptySubsequences: false)
        return pieces.enumerated().compactMap { index, piece in
            if index == pieces.count - 1 { return piece.isEmpty ? nil : String(decoding: piece, as: UTF8.self) }
            return String(decoding: piece, as: UTF8.self) + "\n"
        }
    }

    private func validateKeys(_ args: [String: Any], allowed: Set<String>) throws {
        guard Set(args.keys).isSubset(of: allowed) else { throw Failure("Use only the documented tool fields.") }
    }

    private func integer(_ args: [String: Any], key: String, fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let value = args[key] else { return fallback }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
            number.doubleValue >= Double(range.lowerBound), number.doubleValue < Double(Int.max),
            range.contains(number.intValue)
        else { throw Failure("\(key) must be an integer in \(range).") }
        return number.intValue
    }

    public func prepare(tool: String, argumentsJSON: String) throws -> PreparedWrite {
        try Task.checkCancellation()
        try validateRoot()
        let editing = tool == "pen_edit_file"
        guard editing || tool == "pen_write_file" else { throw Failure("Unknown Pen write tool.") }
        let keys: Set<String> = editing ? ["path", "old_text", "new_text"] : ["path", "content"]
        let args = try arguments(argumentsJSON, keys: keys)
        let path = try required("path", args)
        let parts = try components(path)
        let original: Data?
        let replacement: Data
        let mode: mode_t
        if editing {
            let (data, permissions) = try readFile(parts)
            guard let content = String(data: data, encoding: .utf8) else { throw Failure("File is not UTF-8 text.") }
            let old = try required("old_text", args)
            let new = try required("new_text", args)
            guard !old.utf8.elementsEqual(new.utf8) else {
                throw Failure(
                    "No change: old_text and new_text are identical. Nothing was written. Skip this edit if the file is already correct, or supply a replacement that changes the requested content.",
                    diagnostic: ToolExecutionDiagnostic(
                        fileObservations: [FileOperationObservation(
                            workspaceIdentity: workspaceIdentity, relativePath: path,
                            kind: .edit, outcome: .unchanged, beforeDigest: Self.digest(data))],
                        failureCategory: .fileUnchanged)
                )
            }
            guard !old.isEmpty, let match = content.range(of: old) else {
                throw Failure(
                    "old_text was not found. Nothing was written. Call pen_read_file for this path and copy an exact, unique fragment from its content; do not guess the existing text.",
                    diagnostic: ToolExecutionDiagnostic(fileObservations: [FileOperationObservation(
                        workspaceIdentity: workspaceIdentity, relativePath: path,
                        kind: .edit, outcome: .failed, beforeDigest: Self.digest(data))])
                )
            }
            guard content.range(of: old, range: content.index(after: match.lowerBound)..<content.endIndex) == nil else {
                throw Failure(
                    "old_text matches more than once. Nothing was written. Read the file and include more surrounding text to select one location.",
                    diagnostic: ToolExecutionDiagnostic(fileObservations: [FileOperationObservation(
                        workspaceIdentity: workspaceIdentity, relativePath: path,
                        kind: .edit, outcome: .failed, beforeDigest: Self.digest(data))])
                )
            }
            original = data
            replacement = Data(content.replacingCharacters(in: match, with: new).utf8)
            mode = permissions
        } else {
            original = nil
            replacement = Data(try required("content", args).utf8)
            mode = 0o644
        }
        guard replacement.count <= Self.maximumFileBytes else { throw Failure("File exceeds the 1 MiB limit.") }
        var preview: [String: Any] = args
        preview["workspace"] = rootPath
        return PreparedWrite(
            owner: identity, path: path, original: original, replacement: replacement, mode: mode,
            previewJSON: try json(preview))
    }

    /// Call only with host approval, either for this change or its chat/Pen. Revalidation always runs.
    public func commit(_ write: PreparedWrite) throws -> ToolResult {
        try Task.checkCancellation()
        try validateRoot()
        guard write.owner == identity else { throw Failure("Prepared write belongs to another Pen session.") }
        let parts = try components(write.path)
        guard let name = parts.last else { throw Failure("A file path is required.") }
        let parent = try traverse(Array(parts.dropLast()), create: write.original == nil)
        if let original = write.original {
            let (current, _) = try readFile(parts)
            guard current == original else {
                throw Failure("File changed during approval. Read it again before editing.")
            }
        }
        let temporary = ".goat-write-\(UUID().uuidString)"
        let fd = openat(parent.raw, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("Stage file") }
        let staged = Descriptor(fd)
        defer { unlinkat(parent.raw, temporary, 0) }
        try write.replacement.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                guard let address = bytes.baseAddress else { break }
                let count = Darwin.write(staged.raw, address.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw failure("Write file") }
                offset += count
            }
        }
        guard fchmod(staged.raw, write.mode) == 0 else { throw failure("Preserve file permissions") }
        guard fsync(staged.raw) == 0 else { throw failure("Save file") }
        try Task.checkCancellation()
        try validateRoot()
        if let original = write.original {
            let (current, _) = try readFile(parts)
            guard current == original else {
                throw Failure("File changed before saving. Read it again before editing.")
            }
        }
        let flags: UInt32 = write.original == nil ? UInt32(RENAME_EXCL) : 0
        guard renameatx_np(parent.raw, temporary, parent.raw, name, flags) == 0 else {
            if write.original == nil, errno == EEXIST {
                throw Failure(
                    "File already exists. Nothing was overwritten. Call pen_read_file for this path, then pen_edit_file with an exact fragment from that read. If the content is already correct, skip it; do not recreate completed files. Empty content does not delete a file.",
                    diagnostic: ToolExecutionDiagnostic(
                        fileObservations: [FileOperationObservation(
                            workspaceIdentity: workspaceIdentity, relativePath: write.path,
                            kind: .create, outcome: .alreadyExists)],
                        failureCategory: .fileAlreadyExists)
                )
            }
            throw failure("Save file")
        }
        return ToolResult(
            content: try json(["path": write.path, "bytes": write.replacement.count, "status": "saved"]),
            diagnostic: ToolExecutionDiagnostic(fileObservations: [
                FileOperationObservation(
                    workspaceIdentity: workspaceIdentity, relativePath: write.path,
                    kind: write.original == nil ? .create : .edit, outcome: .succeeded,
                    beforeDigest: Self.digest(write.original), afterDigest: Self.digest(write.replacement))
            ]))
    }

    private func validateRoot() throws {
        let current = try Self.openDirectory(rootPath)
        var expected = stat()
        var actual = stat()
        guard fstat(root.raw, &expected) == 0, fstat(current.raw, &actual) == 0,
            expected.st_dev == actual.st_dev, expected.st_ino == actual.st_ino
        else { throw Failure("Pen folder changed. Start a new turn to refresh its file tools.") }
    }

    private static func digest(_ data: Data?) -> String? {
        guard let data else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func openDirectory(_ path: String) throws -> Descriptor {
        let start = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard start >= 0 else { throw Failure("Cannot open filesystem root.") }
        var directory = Descriptor(start)
        for part in path.split(separator: "/") {
            let next = openat(directory.raw, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Failure("Cannot open Pen folder without following a symbolic link.") }
            directory = Descriptor(next)
        }
        return directory
    }

    private func traverse(_ parts: [String], create: Bool = false) throws -> Descriptor {
        var directory = root
        for part in parts {
            var next = openat(directory.raw, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT, create {
                guard mkdirat(directory.raw, part, 0o755) == 0 || errno == EEXIST else {
                    throw failure("Create directory")
                }
                next = openat(directory.raw, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else { throw failure("Open Pen directory (symbolic links are not followed)") }
            directory = Descriptor(next)
        }
        return directory
    }

    private func readFile(_ parts: [String]) throws -> (Data, mode_t) {
        guard let name = parts.last else { throw Failure("A file path is required.") }
        let parent = try traverse(Array(parts.dropLast()))
        let fd = openat(parent.raw, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("Read file") }
        let file = Descriptor(fd)
        var info = stat()
        guard fstat(file.raw, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
            throw Failure("Only regular files with one hard link are supported.")
        }
        guard info.st_size <= Self.maximumFileBytes else { throw Failure("File exceeds the 1 MiB limit.") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(file.raw, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw failure("Read file") }
            if count == 0 { break }
            guard data.count + count <= Self.maximumFileBytes else { throw Failure("File exceeds the 1 MiB limit.") }
            data.append(contentsOf: buffer.prefix(count))
        }
        return (data, info.st_mode & 0o777)
    }

    private func components(_ path: String, allowRoot: Bool = false) throws -> [String] {
        if allowRoot, path == "." { return [] }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.isEmpty, path.utf8.count <= 4096, !path.contains("\0"),
            parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" })
        else { throw Failure("Use a relative Pen path without '.', '..', empty segments or .git metadata.") }
        return parts
    }

    private func arguments(_ value: String, keys: Set<String>) throws -> [String: String] {
        guard value.utf8.count <= 65_536,
            let args = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: String],
            Set(args.keys) == keys
        else { throw Failure("Arguments must contain exactly the documented string fields.") }
        return args
    }

    private func required(_ key: String, _ args: [String: String]) throws -> String {
        guard let value = args[key] else { throw Failure("Missing \(key).") }
        return value
    }

    private func json(_ value: [String: Any]) throws -> String {
        String(
            decoding: try JSONSerialization.data(
                withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
            as: UTF8.self)
    }

    private func failure(_ operation: String) -> Failure {
        Failure("\(operation): \(String(cString: strerror(errno))).")
    }

    public struct Failure: LocalizedError, Sendable {
        public let message: String
        public let diagnostic: ToolExecutionDiagnostic?
        public init(_ message: String, diagnostic: ToolExecutionDiagnostic? = nil) {
            self.message = message
            self.diagnostic = diagnostic
        }
        public var errorDescription: String? { message }
    }

    private final class Descriptor {
        let raw: Int32
        init(_ raw: Int32) { self.raw = raw }
        deinit { Darwin.close(raw) }
    }
}
