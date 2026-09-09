import Darwin
import Foundation

/// The user-facing workspace convention for Pens. The configured Herd root is only the default
/// for newly created folders. Every Pen keeps its own absolute workspace binding.
public enum HerdWorkspace {
    public static var suggestedRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects", isDirectory: true)
    }

    public static func slug(for name: String) -> String {
        let latin = name.applyingTransform(.toLatin, reverse: false) ?? name
        let normalized = latin.applyingTransform(.stripCombiningMarks, reverse: false) ?? latin
        var result = ""
        var previousWasSeparator = false

        for scalar in normalized.lowercased().unicodeScalars {
            if scalar.isASCII, scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator, !result.isEmpty {
                result.append("-")
                previousWasSeparator = true
            }
        }

        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "pen" : String(trimmed.prefix(64))
    }

    static func nextAvailableFolder(for name: String, in root: URL) -> URL {
        let stem = slug(for: name)
        var index = 0
        var candidate = root.appendingPathComponent(stem, isDirectory: true)
        while FileManager.default.fileExists(atPath: candidate.path) {
            index += 1
            candidate = root.appendingPathComponent("\(stem)-\(index)", isDirectory: true)
        }
        return candidate
    }

    static func binding(for url: URL, wasCreatedByGOAT: Bool) -> PenWorkspace {
        // Store the resolved authority rather than a symlink spelling. That keeps a later Git
        // probe and the user-visible bookmark on the folder they actually selected, even when a
        // user moves a convenient alias under a different parent.
        let folder = url.standardizedFileURL.resolvingSymlinksInPath()
        return PenWorkspace(
            path: folder.path,
            bookmark: try? folder.bookmarkData(options: .withSecurityScope),
            wasCreatedByGOAT: wasCreatedByGOAT)
    }
}

/// File work for the optional user workspace stays off the UI executor. Creating a folder is the
/// only mutating operation here, and it happens solely after the user chooses that creation mode.
public actor HerdWorkspaceFileWorker {
    public static let shared = HerdWorkspaceFileWorker()

    public func createWorkspace(name: String, rootPath: String) throws -> PenWorkspace {
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = HerdWorkspace.nextAvailableFolder(for: name, in: root)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        return HerdWorkspace.binding(for: destination, wasCreatedByGOAT: true)
    }

    public func bindWorkspace(at url: URL) -> PenWorkspace {
        HerdWorkspace.binding(for: url, wasCreatedByGOAT: false)
    }
}

public struct GitInstallationStatus: Sendable, Equatable {
    public let version: String?
    public let hasIdentity: Bool
    public let detail: String

    public var isAvailable: Bool { version != nil }
}

public struct GitWorkspaceStatus: Sendable, Equatable {
    public let rootPath: String
    public let branch: String?
    public let isDetached: Bool
    public let stagedCount: Int
    public let modifiedCount: Int
    public let untrackedCount: Int
    public let conflictedCount: Int
    public let aheadCount: Int
    public let behindCount: Int

    public var isClean: Bool {
        stagedCount == 0 && modifiedCount == 0 && untrackedCount == 0 && conflictedCount == 0
    }
}

public enum GitWorkspaceProbe: Sendable, Equatable {
    case unavailable(String)
    case notRepository
    case repository(GitWorkspaceStatus)
    case failed(String)
}

public enum GitRepositoryInitialization: Sendable, Equatable {
    case initialized
    case alreadyRepository
    case failed(String)
}

/// A narrow reader for Git's porcelain-v2 output. GOAT asks Git, rather than interpreting .git
/// itself, so linked worktrees and other valid repository layouts retain Git's own semantics.
enum GitPorcelainParser {
    static func parse(_ output: String, rootPath: String) -> GitWorkspaceStatus {
        var branch: String?
        var isDetached = false
        var stagedCount = 0
        var modifiedCount = 0
        var untrackedCount = 0
        var conflictedCount = 0
        var aheadCount = 0
        var behindCount = 0

        for line in output.split(whereSeparator: \.isNewline) {
            let value = String(line)
            if value.hasPrefix("# branch.head ") {
                let head = String(value.dropFirst("# branch.head ".count))
                isDetached = head == "(detached)"
                branch = isDetached ? nil : head
            } else if value.hasPrefix("# branch.ab ") {
                let fields = value.split(separator: " ")
                for field in fields.dropFirst(2) {
                    if field.first == "+" { aheadCount = Int(field.dropFirst()) ?? 0 }
                    if field.first == "-" { behindCount = Int(field.dropFirst()) ?? 0 }
                }
            } else if value.hasPrefix("1 ") || value.hasPrefix("2 ") {
                let fields = value.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard let status = fields.dropFirst().first, status.count >= 2 else { continue }
                let codes = Array(status)
                if codes[0] != "." { stagedCount += 1 }
                if codes[1] != "." { modifiedCount += 1 }
            } else if value.hasPrefix("u ") {
                conflictedCount += 1
            } else if value.hasPrefix("? ") {
                untrackedCount += 1
            }
        }

        return GitWorkspaceStatus(
            rootPath: rootPath,
            branch: branch,
            isDetached: isDetached,
            stagedCount: stagedCount,
            modifiedCount: modifiedCount,
            untrackedCount: untrackedCount,
            conflictedCount: conflictedCount,
            aheadCount: aheadCount,
            behindCount: behindCount)
    }
}

/// A local Git adapter. Status calls are read-only; the single write operation is an explicit
/// `git init` for a just-created project folder. It never fetches, stages, commits, switches
/// branches, or prompts for credentials. All subprocess work is isolated from SwiftUI and
/// user-model state.
public actor GitWorkspaceWorker {
    public static let shared = GitWorkspaceWorker()

    private static let maximumOutputBytes = 64 * 1_024
    private static let commandTimeout: TimeInterval = 2
    private static let terminationGrace: TimeInterval = 0.25

    public func installation() -> GitInstallationStatus {
        let version = run(arguments: ["--version"])
        guard version.status == 0, version.output.hasPrefix("git version ") else {
            return GitInstallationStatus(
                version: nil,
                hasIdentity: false,
                detail: "Git is unavailable. Install Apple’s Command Line Tools to enable workspace status.")
        }

        let name = run(
            arguments: ["config", "--global", "--no-includes", "--get", "user.name"],
            policy: .globalIdentity)
        let email = run(
            arguments: ["config", "--global", "--no-includes", "--get", "user.email"],
            policy: .globalIdentity)
        return GitInstallationStatus(
            version: version.output.trimmingCharacters(in: .whitespacesAndNewlines),
            hasIdentity: name.status == 0 && email.status == 0
                && !name.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !email.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            detail: "Git is available for read-only workspace status.")
    }

    public func status(at workspace: PenWorkspace) -> GitWorkspaceProbe {
        let folder = URL(fileURLWithPath: workspace.path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            return .failed("The project folder is no longer available.")
        }
        let root = run(arguments: ["rev-parse", "--show-toplevel"], directory: folder)
        guard root.status == 0 else {
            if root.output.localizedCaseInsensitiveContains("not a git repository") {
                return .notRepository
            }
            if root.output.localizedCaseInsensitiveContains("xcrun") {
                return .unavailable("Git needs Apple’s Command Line Tools.")
            }
            return .failed(commandDetail(from: root.output, fallback: "Git could not inspect this folder."))
        }
        let rootPath = root.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rootPath.isEmpty else { return .notRepository }
        let status = run(
            arguments: [
                "status", "--porcelain=v2", "--branch", "--untracked-files=normal",
                "--ignore-submodules=all",
            ],
            directory: URL(fileURLWithPath: rootPath, isDirectory: true))
        guard status.status == 0 else {
            return .failed(commandDetail(from: status.output, fallback: "Git status could not be read."))
        }
        return .repository(GitPorcelainParser.parse(status.output, rootPath: rootPath))
    }

    /// Initializes an empty repository only after the person opted in while creating their
    /// project folder. No contents are added and no remote is created or contacted.
    public func initializeRepository(at workspace: PenWorkspace) -> GitRepositoryInitialization {
        guard workspace.wasCreatedByGOAT else {
            return .failed("GOAT only initializes project folders it just created.")
        }
        let folder = URL(fileURLWithPath: workspace.path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            return .failed("The project folder is no longer available.")
        }

        let existingRepository = run(arguments: ["rev-parse", "--is-inside-work-tree"], directory: folder)
        if existingRepository.status == 0 {
            return .alreadyRepository
        }

        let result = run(arguments: ["init", "--quiet", "--no-template"], directory: folder)
        guard result.status == 0 else {
            return .failed(commandDetail(from: result.output, fallback: "Git could not initialize this folder."))
        }
        return .initialized
    }

    private struct CommandResult: Sendable {
        let status: Int32
        let output: String
    }

    private enum CommandPolicy {
        /// Status and repository initialization must never inherit user or repository Git
        /// configuration. In particular, this disables fsmonitor hooks before Git reads a repo.
        case isolated
        /// This is the sole intentional read of the user's Git config, used only to disclose
        /// whether identity metadata is present. Includes are disabled and no repository is open.
        case globalIdentity
    }

    private enum CommandTermination {
        case exited
        case timedOut
        case exceededOutputLimit
    }

    private func run(
        arguments: [String],
        directory: URL? = nil,
        policy: CommandPolicy = .isolated
    ) -> CommandResult {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("goat-git-output-\(UUID().uuidString)", isDirectory: false)
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
            let output = try? FileHandle(forWritingTo: outputURL)
        else {
            return CommandResult(status: -1, output: "GOAT could not create a bounded Git output file.")
        }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = commandArguments(arguments, policy: policy)
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = output
        process.environment = commandEnvironment(policy: policy)

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in termination.signal() }
        do {
            try process.run()
            let outcome = waitForTermination(
                process,
                outputURL: outputURL,
                semaphore: termination)
            try? output.close()

            switch outcome {
            case .timedOut:
                return CommandResult(status: -1, output: "Git command timed out after 2 seconds.")
            case .exceededOutputLimit:
                return CommandResult(
                    status: -1,
                    output: "Git command exceeded GOAT's 64 KiB output limit.")
            case .exited:
                break
            }

            guard outputSize(at: outputURL) <= Self.maximumOutputBytes else {
                return CommandResult(
                    status: -1,
                    output: "Git command exceeded GOAT's 64 KiB output limit.")
            }
            return CommandResult(
                status: process.terminationStatus,
                output: boundedOutput(at: outputURL))
        } catch {
            return CommandResult(status: -1, output: error.localizedDescription)
        }
    }

    private func commandArguments(_ arguments: [String], policy: CommandPolicy) -> [String] {
        var result = ["--no-pager"]
        switch policy {
        case .isolated:
            result += [
                "-c", "core.fsmonitor=false",
                "-c", "core.hooksPath=/dev/null",
                "-c", "core.attributesfile=/dev/null",
                "-c", "diff.external=",
                "-c", "submodule.recurse=false",
            ]
        case .globalIdentity:
            break
        }
        result += arguments
        return result
    }

    private func commandEnvironment(policy: CommandPolicy) -> [String: String] {
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL": "C",
            "LANG": "C",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_PAGER": "cat",
            "GIT_EDITOR": "true",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_ATTR_NOSYSTEM": "1",
        ]
        switch policy {
        case .isolated:
            environment["HOME"] = "/var/empty"
            environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        case .globalIdentity:
            environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        }
        return environment
    }

    private func waitForTermination(
        _ process: Process,
        outputURL: URL,
        semaphore: DispatchSemaphore
    ) -> CommandTermination {
        let deadline = Date().addingTimeInterval(Self.commandTimeout)
        while Date() < deadline {
            if semaphore.wait(timeout: .now() + .milliseconds(25)) == .success {
                return .exited
            }
            if outputSize(at: outputURL) > Self.maximumOutputBytes {
                terminate(process, semaphore: semaphore)
                return .exceededOutputLimit
            }
        }
        terminate(process, semaphore: semaphore)
        return .timedOut
    }

    private func terminate(_ process: Process, semaphore: DispatchSemaphore) {
        guard process.isRunning else { return }
        process.terminate()
        if semaphore.wait(timeout: .now() + .milliseconds(Int(Self.terminationGrace * 1_000))) == .timedOut,
            process.isRunning
        {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            _ = semaphore.wait(timeout: .now() + .milliseconds(Int(Self.terminationGrace * 1_000)))
        }
    }

    private func outputSize(at url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .intValue ?? 0
    }

    private func boundedOutput(at url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: Self.maximumOutputBytes)
        return String(decoding: data, as: UTF8.self)
    }

    private func commandDetail(from output: String, fallback: String) -> String {
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? fallback : detail
    }
}
