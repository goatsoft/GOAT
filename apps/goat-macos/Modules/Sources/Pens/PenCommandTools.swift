import Darwin
import Foundation
import JUDAS
import Tools

/// Turn-owned, non-interactive commands. Seatbelt applies to the executable and its children.
/// No fallback to an unconfined process is allowed if sandbox-exec fails.
public actor PenCommandTools {
    public static let schemas: [ToolSchema] = [
        ToolSchema(
            name: "pen_run_command",
            description:
                "Run a non-interactive command in the Pen to completion (or its timeout) and return exit_code, timed_out and the combined stdout/stderr in one result. command is an executable name or path; args are literal arguments, not shell syntax. For shell scripts request command 'sh' with args ['-c', script]. Commands outside the owner's whitelist require approval. Filesystem access is confined to the Pen, private scratch and read-only toolchains. network defaults false; request true for dependency downloads or networking tests, subject to approval and JUDAS. Output over 32 KiB keeps the head and tail with a marker for the omitted middle; for the full log, redirect to a workspace file (for example command > out.log 2>&1) and read it with pen_read_file. Set background true for a server or watcher: it returns a job_id you poll with pen_command_status. Do not claim success before exit_code 0. Jobs stop at the turn end or their deadline. Use installed tools; explain missing executables.",
            inputSchemaJSON:
                #"{"type":"object","properties":{"command":{"type":"string","minLength":1,"maxLength":4096},"args":{"type":"array","items":{"type":"string"},"maxItems":128},"working_directory":{"type":"string","maxLength":4096},"network":{"type":"boolean"},"background":{"type":"boolean"},"timeout_seconds":{"type":"integer","minimum":1,"maximum":600}},"required":["command","args"],"additionalProperties":false}"#
        ),
        ToolSchema(
            name: "pen_command_status",
            description:
                "Wait briefly for a command in this turn and read its bounded combined stdout/stderr, exit code and running status. Output is a snapshot, not a new chunk. Continue polling while running. Truncated output is marked; use a project log file for large diagnostics.",
            inputSchemaJSON:
                #"{"type":"object","properties":{"job_id":{"type":"string"},"wait_seconds":{"type":"integer","minimum":0,"maximum":10}},"required":["job_id"],"additionalProperties":false}"#
        ),
        ToolSchema(
            name: "pen_stop_command",
            description:
                "Cancel an already running command using its exact returned job_id. This does not remove files; use pen_run_command with command rm and literal path arguments for an approved file deletion. Never invent job IDs. File changes are not rolled back.",
            inputSchemaJSON:
                #"{"type":"object","properties":{"job_id":{"type":"string"}},"required":["job_id"],"additionalProperties":false}"#
        ),
    ]

    public struct PreparedCommand: Sendable {
        fileprivate let owner: UUID
        fileprivate let executable: String
        fileprivate let arguments: [String]
        fileprivate let directory: String
        fileprivate let timeout: Int
        fileprivate let runtimeRoots: [String]
        fileprivate let background: Bool
        public var executablePath: String { executable }
        public let commandIdentity: String
        public let displayName: String
        public let network: Bool
        public let directRemovalObservation: FileOperationObservation?
        public let previewJSON: String
        public var isDefaultAllowed: Bool {
            !network
                && ["/bin/pwd", "/bin/ls", "/bin/cat", "/usr/bin/head", "/usr/bin/tail", "/usr/bin/wc"].contains(
                    executable)
        }
    }

    public struct ExecutableReview: Sendable, Equatable {
        public let path: String
        public let name: String
        public let identity: String
        public let workspaceIdentity: String
    }

    /// Read-only owner setup. Does not launch a process, connect or grant authority.
    public func reviewExecutable(_ command: String) async throws -> ExecutableReview {
        guard !closed, !command.isEmpty, command.utf8.count <= 4096, !command.contains("\0") else {
            throw Failure("Enter an executable name or path, without command arguments.")
        }
        try Task.checkCancellation()
        try await files.validateWorkspace()
        guard !closed else { throw Failure("Command authority expired.") }
        try Task.checkCancellation()
        try validateCommandWorkspace()
        let path = try resolveExecutable(command, directory: workspace.path)
        return ExecutableReview(
            path: path, name: URL(fileURLWithPath: path).lastPathComponent,
            identity: try Self.executableIdentity(path), workspaceIdentity: files.workspaceIdentity)
    }

    private struct Input: Decodable {
        let command: String
        let args: [String]
        var working_directory: String?
        var network: Bool?
        var background: Bool?
        var timeout_seconds: Int?
    }

    private struct Job {
        let pid: pid_t
        let outputFD: Int32
        let lifetimeFD: Int32
        let scratch: URL
        let deadline: Date
        let network: Bool
        var head = Data()
        var tail = Data()
        var totalBytes = 0
        var timedOut = false
        var exitCode: Int32?
        var stopped: String?
        var finished = false
        let directRemovalObservation: FileOperationObservation?
        var observationReported = false
        var monitor: Task<Void, Never>?
        var cancellation: UUID?
    }

    private let identity = UUID()
    private let workspace: URL
    private let files: PenFileTools
    private let judas: Judas
    private let searchPaths: [String]
    private let defaultTimeout: Int
    private var jobs: [String: Job] = [:]
    private var closed = false
    private var jobOrder: [String] = []

    public init(
        workspace: URL, files: PenFileTools, judas: Judas = .shared, searchPaths: [String]? = nil,
        defaultTimeout: Int = 120
    ) {
        self.defaultTimeout = min(600, max(1, defaultTimeout))
        self.workspace = URL(fileURLWithPath: files.workspacePath)
        self.files = files
        self.judas = judas
        self.searchPaths = searchPaths ?? Self.defaultSearchPaths()
    }

    public func prepare(argumentsJSON: String) async throws -> PreparedCommand {
        guard !closed, argumentsJSON.utf8.count <= 65_536 else {
            throw Failure("Command unavailable or arguments exceed 64 KiB.")
        }
        try Task.checkCancellation()
        try await files.validateWorkspace()
        // Actor reentrancy: Stop or workspace rebinding may have closed this turn while
        // workspace validation was awaited. Recheck before preparing or launching work.
        try Task.checkCancellation()
        guard !closed else { throw Failure("Command authority expired.") }
        try validateCommandWorkspace()
        let input = try JSONDecoder().decode(Input.self, from: Data(argumentsJSON.utf8))
        guard !input.command.isEmpty, !input.command.contains("\0"), input.args.count <= 128,
            input.args.allSatisfy({ !$0.contains("\0") }), (1...600).contains(input.timeout_seconds ?? defaultTimeout)
        else { throw Failure("Supply a command, literal args and a timeout between 1 and 600 seconds.") }
        let directory = try confinedDirectory(input.working_directory ?? ".")
        let executable = try resolveExecutable(input.command, directory: directory)
        let commandIdentity = try Self.executableIdentity(executable)
        let network = input.network ?? false
        let background = input.background ?? false
        try judas.authorizePenCommand(network: network)
        let roots = Self.runtimeRoots(executable: executable, searchPaths: searchPaths)
        let preview: [String: Any] = [
            "command": executable, "args": input.args, "working_directory": directory,
            "network": network ? "Allowed for this command and its children" : "Blocked",
            "filesystem":
                "Read and write inside this Pen and private scratch only; toolchains are read-only. Child commands inherit these restrictions.",
            "permission_scope":
                "Remembering this command permits any arguments and child commands under the same filesystem and network restrictions. File approvals do not grant command permission.",
            "timeout_seconds": input.timeout_seconds ?? defaultTimeout,
            "execution": background
                ? "Background job you poll with pen_command_status" : "Runs to completion in one result",
        ]
        return PreparedCommand(
            owner: identity, executable: executable, arguments: input.args, directory: directory,
            timeout: input.timeout_seconds ?? defaultTimeout, runtimeRoots: roots, background: background,
            commandIdentity: commandIdentity,
            displayName: URL(fileURLWithPath: executable).lastPathComponent, network: network,
            directRemovalObservation: Self.directRemovalObservation(
                executable: executable, arguments: input.args, workspaceIdentity: files.workspaceIdentity),
            previewJSON: try Self.json(preview))
    }

    public func start(_ command: PreparedCommand) async throws -> ToolResult {
        guard !closed, command.owner == identity else { throw Failure("Command authority expired.") }
        try Task.checkCancellation()
        try await files.validateWorkspace()
        // Actor reentrancy: Stop or workspace rebinding may have closed this turn while
        // workspace validation was awaited. Recheck before preparing or launching work.
        try Task.checkCancellation()
        guard !closed else { throw Failure("Command authority expired.") }
        try validateCommandWorkspace()
        guard command.commandIdentity == (try Self.executableIdentity(command.executable)),
            try confinedDirectory(command.directory, allowAbsolute: true) == command.directory
        else { throw Failure("Command or working directory changed during approval. Request it again.") }
        guard jobs.values.filter({ !$0.finished }).count < 4 else {
            throw Failure(
                "This turn has reached its command capacity. Finish or stop running commands before starting more.")
        }
        while jobs.count >= 100, let expired = jobOrder.first(where: { jobs[$0]?.finished == true }) {
            jobs.removeValue(forKey: expired)
            jobOrder.removeAll { $0 == expired }
        }
        try judas.authorizePenCommand(network: command.network)
        var scratch = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(
            "goat-command-\(UUID())")
        try FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        scratch = URL(fileURLWithPath: try Self.canonicalPath(scratch.path))
        var keepScratch = false
        defer { if !keepScratch { try? FileManager.default.removeItem(at: scratch) } }
        for name in ["home", "tmp", "cache"] {
            try FileManager.default.createDirectory(
                at: scratch.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        let profile = Self.profile(
            workspace: workspace.path, scratch: scratch.path, executable: command.executable,
            roots: command.runtimeRoots, network: command.network)
        let environment = [
            "PATH": searchPaths.joined(separator: ":"), "HOME": scratch.appendingPathComponent("home").path,
            "TMPDIR": scratch.appendingPathComponent("tmp").path + "/",
            "XDG_CACHE_HOME": scratch.appendingPathComponent("cache").path,
            "npm_config_cache": scratch.appendingPathComponent("cache/npm").path, "npm_config_update_notifier": "false",
            "npm_config_audit": "false", "npm_config_fund": "false", "CI": "1", "NO_COLOR": "1", "LANG": "en_US.UTF-8",
        ]
        try Task.checkCancellation()
        let spawned = try Self.spawn(command: command, profile: profile, environment: environment)
        keepScratch = true
        let id = UUID().uuidString
        jobOrder.append(id)
        jobs[id] = Job(
            pid: spawned.pid, outputFD: spawned.output, lifetimeFD: spawned.lifetime, scratch: scratch,
            deadline: Date().addingTimeInterval(TimeInterval(command.timeout)), network: command.network,
            directRemovalObservation: command.directRemovalObservation)
        if command.network {
            jobs[id]?.cancellation = judas.registerCancellation { [weak self] in
                Task { await self?.stop(id, reason: "Stopped because JUDAS policy changed.") }
            }
            // Close the registration/check race with a policy change.
            if judas.mode != .configured { await stop(id, reason: "Stopped because JUDAS policy changed.") }
        }
        jobs[id]?.monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, await self.tick(id) else { return }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
        guard !command.background else { return try snapshot(id) }
        // Foreground: block until the command finishes or hits its deadline, then return one result.
        await jobs[id]?.monitor?.value
        if jobs[id]?.finished == false {
            await stop(id, reason: "Stopped before completion. File changes were not rolled back.")
        }
        let result = try snapshot(id)
        jobs.removeValue(forKey: id)
        jobOrder.removeAll { $0 == id }
        return result
    }

    public func invoke(tool: String, argumentsJSON: String) async throws -> ToolResult {
        struct StatusInput: Decodable {
            let job_id: String
            var wait_seconds: Int?
        }
        let input = try JSONDecoder().decode(StatusInput.self, from: Data(argumentsJSON.utf8))
        guard jobs[input.job_id] != nil else {
            throw Failure(
                "Unknown command job for this turn. Check the exact job_id returned by pen_run_command; do not invent or alter a job ID."
            )
        }
        if tool == "pen_stop_command" {
            await stop(input.job_id, reason: "Stopped by request. File changes were not rolled back.")
        } else if tool == "pen_command_status" {
            let wait = input.wait_seconds ?? 1
            guard (0...10).contains(wait) else { throw Failure("wait_seconds must be between 0 and 10.") }
            let until = Date().addingTimeInterval(TimeInterval(wait))
            while jobs[input.job_id]?.finished == false, Date() < until {
                try await Task.sleep(for: .milliseconds(100))
            }
        } else {
            throw Failure("Unknown command tool.")
        }
        return try snapshot(input.job_id)
    }

    public func runningCount() -> Int { jobs.values.filter { !$0.finished }.count }

    public func stopAll() async {
        closed = true
        for id in Array(jobs.keys) {
            await stop(id, reason: "Stopped when this turn ended. File changes were not rolled back.")
        }
    }

    private func tick(_ id: String) async -> Bool {
        guard var job = jobs[id], !job.finished else { return false }
        Self.drain(&job)
        var status: Int32 = 0
        let result = waitpid(job.pid, &status, WNOHANG)
        if result == job.pid {
            // Do not leave ordinary descendants running after their command leader exits.
            kill(-job.pid, SIGKILL)
            job.exitCode = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            finish(&job)
        } else if result < 0 && errno != EINTR {
            job.stopped = "Command status became unavailable. Inspect files before retrying."
            kill(-job.pid, SIGKILL)
            finish(&job)
        }
        jobs[id] = job
        if !job.finished && Date() >= job.deadline {
            jobs[id]?.timedOut = true
            await stop(
                id, reason: "Command timed out. File changes were not rolled back; inspect state before retrying.")
        }
        return jobs[id]?.finished == false
    }

    private func stop(_ id: String, reason: String) async {
        guard var job = jobs[id], !job.finished else { return }
        job.stopped = reason
        // Kill the entire spawned process group, including package scripts and build children.
        kill(-job.pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(job.pid, &status, 0) < 0 && errno == EINTR {}
        job.exitCode = 128 + SIGKILL
        finish(&job)
        jobs[id] = job
    }

    private func finish(_ job: inout Job) {
        Self.drain(&job)
        Darwin.close(job.outputFD)
        Darwin.close(job.lifetimeFD)
        job.finished = true
        job.monitor?.cancel()
        job.monitor = nil
        if let registration = job.cancellation { judas.unregister(registration) }
        job.cancellation = nil
        try? FileManager.default.removeItem(at: job.scratch)
    }

    private func snapshot(_ id: String) throws -> ToolResult {
        guard var job = jobs[id] else { throw Failure("Unknown command job.") }
        let elided = job.totalBytes > job.head.count + job.tail.count
        let output: String
        if elided {
            let omitted = job.totalBytes - job.head.count - job.tail.count
            output =
                String(decoding: job.head, as: UTF8.self)
                + "\n...[\(omitted) bytes omitted; redirect to a file and pen_read_file it for the full log]...\n"
                + String(decoding: job.tail, as: UTF8.self)
        } else {
            output = String(decoding: job.head + job.tail, as: UTF8.self)
        }
        var object: [String: Any] = [
            "job_id": id, "running": !job.finished,
            "output": output, "output_truncated": elided, "timed_out": job.timedOut,
        ]
        object["exit_code"] = job.exitCode
        object["notice"] = job.stopped
        let succeeded = job.finished && job.exitCode == 0 && job.stopped == nil
        var diagnostic: ToolExecutionDiagnostic?
        if succeeded, let observation = job.directRemovalObservation, !job.observationReported {
            diagnostic = ToolExecutionDiagnostic(fileObservations: [observation])
            job.observationReported = true
            jobs[id] = job
        }
        return ToolResult(
            content: try Self.json(object), isError: job.finished && !succeeded, diagnostic: diagnostic)
    }

    private static func directRemovalObservation(
        executable: String, arguments: [String], workspaceIdentity: String
    ) -> FileOperationObservation? {
        guard ["/bin/rm", "/usr/bin/rm"].contains(executable), arguments.count == 2,
            arguments[0] == "--"
        else { return nil }
        let path = arguments[1]
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.contains("*") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, !components.contains(".."), !components.contains(where: { $0.hasPrefix("-") }) else {
            return nil
        }
        return FileOperationObservation(
            workspaceIdentity: workspaceIdentity, relativePath: components.joined(separator: "/"),
            kind: .remove, outcome: .succeeded)
    }

    private static func drain(_ job: inout Job) {
        var buffer = [UInt8](repeating: 0, count: 8_192)
        for _ in 0..<16 {
            let count = Darwin.read(job.outputFD, &buffer, buffer.count)
            guard count > 0 else { return }
            job.totalBytes += count
            let chunk = buffer.prefix(count)
            let headRoom = max(0, 16 * 1_024 - job.head.count)
            if headRoom > 0 {
                job.head.append(contentsOf: chunk.prefix(headRoom))
                Self.appendTail(&job, chunk.dropFirst(headRoom))
            } else {
                Self.appendTail(&job, chunk)
            }
        }
    }

    /// Retains only the most recent 16 KiB beyond the head so the failing tail of long output stays
    /// visible while total memory stays bounded regardless of how much the command prints.
    private static func appendTail(_ job: inout Job, _ bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty else { return }
        job.tail.append(contentsOf: bytes)
        if job.tail.count > 16 * 1_024 { job.tail.removeFirst(job.tail.count - 16 * 1_024) }
    }

    /// Reject a broad root that would give a command authority over its own permission store.
    /// Shared hard links can change files outside the project even when accessed inside it.
    private func validateCommandWorkspace() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let protected = [
            home + "/Library/Preferences", home + "/Library/Application Support/GOAT", home + "/.goat/config",
        ]
        guard
            !protected.contains(where: {
                $0 == workspace.path || $0.hasPrefix(workspace.path + "/") || workspace.path.hasPrefix($0 + "/")
            })
        else {
            throw Failure(
                "Choose a dedicated project folder. This workspace includes GOAT's settings or permission storage.")
        }
        var scanFailed = false
        guard
            let entries = FileManager.default.enumerator(
                at: workspace, includingPropertiesForKeys: nil,
                errorHandler: { _, _ in
                    scanFailed = true
                    return false
                })
        else { throw Failure("Could not inspect command workspace.") }
        var shared: [String: (count: Int, expected: Int)] = [:]
        var count = 0
        for case let file as URL in entries {
            try Task.checkCancellation()
            count += 1
            guard count <= 200_000 else {
                throw Failure("Workspace exceeds 200,000 entries. Choose a smaller project folder for commands.")
            }
            var info = stat()
            guard lstat(file.path, &info) == 0 else {
                throw Failure("Workspace changed while preparing the command. Try again.")
            }
            if info.st_mode & S_IFMT == S_IFREG && info.st_nlink > 1 {
                let key = "\(info.st_dev):\(info.st_ino)"
                let previous = shared[key]?.count ?? 0
                shared[key] = (previous + 1, Int(info.st_nlink))
            }
        }
        guard !scanFailed, shared.values.allSatisfy({ $0.count == $0.expected }) else {
            throw Failure(
                "The workspace contains unreadable entries or hard links shared outside the Pen. Use independent project files before running commands."
            )
        }
    }

    private func confinedDirectory(_ value: String, allowAbsolute: Bool = false) throws -> String {
        guard !value.contains("\0"), !value.split(separator: "/").contains(".."), allowAbsolute || !value.hasPrefix("/")
        else {
            throw Failure("working_directory must be relative to the Pen, without parent traversal.")
        }
        let supplied = allowAbsolute ? URL(fileURLWithPath: value) : workspace.appendingPathComponent(value)
        let url = URL(fileURLWithPath: try Self.canonicalPath(supplied.path))
        var directory: ObjCBool = false
        guard url.path == workspace.path || url.path.hasPrefix(workspace.path + "/"),
            FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue
        else {
            throw Failure("Working directory is unavailable or outside this Pen.")
        }
        return url.path
    }

    private func resolveExecutable(_ command: String, directory: String) throws -> String {
        let candidates =
            command.contains("/")
            ? [command.hasPrefix("/") ? command : URL(fileURLWithPath: directory).appendingPathComponent(command).path]
            : searchPaths.map { URL(fileURLWithPath: $0).appendingPathComponent(command).path }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw Failure(
                "Executable '\(command)' is not installed on the available PATH. Use an installed tool or ask the owner to install a runtime."
            )
        }
        return try Self.canonicalPath(path)
    }

    private static func canonicalPath(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else { throw Failure("Path is unavailable: \(path)") }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func executableIdentity(_ path: String) throws -> String {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw Failure("Executable is unavailable.")
        }
        return
            "\(path)|\(info.st_dev)|\(info.st_ino)|\(info.st_size)|\(info.st_mtimespec.tv_sec)|\(info.st_mtimespec.tv_nsec)|\(info.st_ctimespec.tv_sec)|\(info.st_ctimespec.tv_nsec)"
    }

    private static func defaultSearchPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let versions = home.appendingPathComponent(".nvm/versions/node")
        let node = ((try? FileManager.default.contentsOfDirectory(atPath: versions.path)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { versions.appendingPathComponent($0).appendingPathComponent("bin").path }
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen: Set<String> = []
        return (node + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] + inherited)
            .filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }

    private static func runtimeRoots(executable: String, searchPaths: [String]) -> [String] {
        var roots = [
            "/System", "/usr", "/bin", "/sbin", "/opt/homebrew", "/Library/Developer", "/Applications/Xcode.app",
        ]
        // Versioned Node toolchains contain npm's JS modules and shared libraries.
        for path in searchPaths where path.contains("/.nvm/versions/node/") && path.hasSuffix("/bin") {
            roots.append(URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath().path)
        }
        return roots
    }

    private static func profile(workspace: String, scratch: String, executable: String, roots: [String], network: Bool)
        -> String
    {
        func quote(_ value: String) -> String {
            "\""
                + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
        }
        let reads = (roots + [workspace, scratch]).map { "(subpath \(quote($0)))" }.joined(separator: " ")
        return """
            (version 1)
            (deny default)
            (allow process-fork process-exec)
            (allow signal (target self) (target children))
            (allow syscall-unix)
            (deny syscall-unix (syscall-number SYS_setsid) (syscall-number SYS_setpgid))
            (allow sysctl-read file-read-metadata)
            (allow file-read-data (literal "/"))
            (allow file-read* \(reads) (literal \(quote(executable))) (literal "/dev/null") (literal "/dev/random") (literal "/dev/urandom") (literal "/Library/Preferences/com.apple.dt.Xcode.plist"))
            (allow file-write* (subpath \(quote(workspace))) (subpath \(quote(scratch))) (literal "/dev/null"))
            \(network ? "(allow network-outbound)\n(allow mach-lookup (global-name \"com.apple.SystemConfiguration.configd\") (global-name \"com.apple.networkd\") (global-name \"com.apple.dnssd.service\"))\n(allow file-read* (literal \"/private/etc/resolv.conf\") (literal \"/private/etc/hosts\"))" : "")
            """
    }

    private static func spawn(command: PreparedCommand, profile: String, environment: [String: String]) throws -> (
        pid: pid_t, output: Int32, lifetime: Int32
    ) {
        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else { throw Failure("Could not create command output pipe.") }
        var lifetimeFDs: [Int32] = [0, 0]
        guard pipe(&lifetimeFDs) == 0 else {
            Darwin.close(pipeFDs[0])
            Darwin.close(pipeFDs[1])
            throw Failure("Could not create command lifetime pipe.")
        }
        _ = fcntl(lifetimeFDs[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(lifetimeFDs[1], F_SETFD, FD_CLOEXEC)
        var keepReader = false
        defer {
            Darwin.close(pipeFDs[1])
            Darwin.close(lifetimeFDs[0])
            if !keepReader {
                Darwin.close(pipeFDs[0])
                Darwin.close(lifetimeFDs[1])
            }
        }
        _ = fcntl(pipeFDs[0], F_SETFL, O_NONBLOCK)
        _ = fcntl(pipeFDs[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(pipeFDs[1], F_SETFD, FD_CLOEXEC)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else {
            throw Failure("Could not initialize command launch.")
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
            posix_spawn_file_actions_adddup2(&actions, pipeFDs[1], STDOUT_FILENO) == 0,
            posix_spawn_file_actions_adddup2(&actions, pipeFDs[1], STDERR_FILENO) == 0,
            posix_spawn_file_actions_adddup2(&actions, lifetimeFDs[0], 3) == 0,
            posix_spawn_file_actions_addchdir(&actions, command.directory) == 0,
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
            posix_spawnattr_setpgroup(&attributes, 0) == 0
        else { throw Failure("Could not configure command isolation.") }
        // Trusted supervisor, outside the command sandbox. No model text is evaluated as shell
        // source: executable/profile/arguments are passed through "$@". FD 3 is closed before
        // invoking sandbox-exec, so command children cannot retain the host-liveness pipe.
        // Host crash/exit closes its only writer; the watcher then kills this process group.
        let supervisor = """
            owner=$$
            (IFS= read -r parent_alive <&3; kill -KILL -"$owner") &
            watcher=$!
            "$@" 3<&-
            result=$?
            kill -KILL "$watcher" 2>/dev/null
            wait "$watcher" 2>/dev/null
            exit "$result"
            """
        let arguments =
            ["/bin/sh", "-c", supervisor, "goat-command", "/usr/bin/sandbox-exec", "-p", profile, command.executable]
            + command.arguments
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&pid, "/bin/sh", &actions, &attributes, args.baseAddress, env.baseAddress)
            }
        }
        guard status == 0 else {
            throw Failure("Could not launch confined command: \(String(cString: strerror(status))).")
        }
        keepReader = true
        return (pid, pipeFDs[0], lifetimeFDs[1])
    }

    private static func json(_ value: [String: Any]) throws -> String {
        String(
            decoding: try JSONSerialization.data(
                withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
