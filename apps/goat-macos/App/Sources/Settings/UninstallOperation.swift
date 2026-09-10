import Darwin
import Foundation
import Security

enum UninstallError: LocalizedError {
    case unsafe(String)
    var errorDescription: String? {
        switch self {
        case .unsafe(let reason): reason
        }
    }
}

/// A checked filesystem identity, not permission to follow a replacement link.
struct UninstallIdentity: Codable, Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let kind: UInt16

    static func read(_ url: URL) throws -> Self {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid(), info.st_nlink > 0 else {
            throw UninstallError.unsafe("Cannot inspect an owned item: \(url.path)")
        }
        let kind = info.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFDIR, kind != S_IFREG || info.st_nlink == 1 else {
            throw UninstallError.unsafe("Keep linked or unsupported items: \(url.path)")
        }
        return Self(device: info.st_dev, inode: info.st_ino, kind: kind)
    }
}

struct UninstallRequest: Codable, Sendable {
    var parentPID: Int32
    var home: URL
    var support: URL
    var app: URL
    var cli: URL?
    var preferencesDomain: String
    var keepPreferences: Bool
    var removedGroups: Set<String>
    var protectedPaths: [URL]
    var recovery: URL
    var roots: [String: UninstallIdentity] = [:]

    func removes(_ group: DataManagementPlan.Group) -> Bool { removedGroups.contains(group.rawValue) }
    var removesHomeData: Bool {
        [.connections, .memory, .customizations, .pens].contains(where: removes)
    }

    mutating func captureRoots() throws {
        var paths = [app]
        if FileManager.default.fileExists(atPath: recovery.path) { paths.append(recovery) }
        if let cli { paths.append(cli) }
        if removesHomeData, FileManager.default.fileExists(atPath: home.path) { paths.append(home) }
        if removes(.chats), FileManager.default.fileExists(atPath: support.path) { paths.append(support) }
        for url in paths {
            guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
                throw UninstallError.unsafe("Automatic removal cannot follow a linked location: \(url.path)")
            }
            roots[url.path] = try UninstallIdentity.read(url)
        }
    }

    func validateRoots() throws {
        guard app.pathExtension == "app", app.lastPathComponent == "GOAT.app",
            preferencesDomain.hasPrefix("dev.leet.goat"),
            Bundle(url: app)?.bundleIdentifier == preferencesDomain
        else { throw UninstallError.unsafe("The selected copy could not be identified as GOAT.") }
        if let cli, cli.lastPathComponent != "goat" {
            throw UninstallError.unsafe("Select the installed goat command, or keep the CLI.")
        }
        if let cli {
            let cliSignature = try Self.signature(cli)
            let appSignature = try Self.signature(app)
            guard cliSignature.identifier == "goat", cliSignature.team == appSignature.team else {
                throw UninstallError.unsafe(
                    "The CLI signature does not match this GOAT installation. Keep it for manual review.")
            }
        }
        for (path, identity) in roots {
            let url = URL(fileURLWithPath: path)
            guard url.resolvingSymlinksInPath().standardizedFileURL.path == path,
                try UninstallIdentity.read(url) == identity
            else { throw UninstallError.unsafe("A reviewed location changed. Nothing more will be moved: \(path)") }
        }
        guard !removes(.pens) || removes(.chats) else {
            throw UninstallError.unsafe("Keep Pen metadata when keeping its chats.")
        }
        for source in [home, support, app] {
            guard !Self.contains(source, recovery) else {
                throw UninstallError.unsafe("Choose a recovery folder outside GOAT data and the app.")
            }
        }
        if FileManager.default.fileExists(atPath: recovery.path) {
            let permissions =
                try FileManager.default.attributesOfItem(atPath: recovery.path)[.posixPermissions] as? NSNumber
            guard permissions?.intValue == 0o700 else {
                throw UninstallError.unsafe("The recovery directory must remain private (owner access only).")
            }
        }
    }

    static func contains(_ root: URL, _ child: URL) -> Bool {
        child.resolvingSymlinksInPath().standardizedFileURL.pathComponents.starts(
            with: root.resolvingSymlinksInPath().standardizedFileURL.pathComponents)
    }

    static func physicalPath(_ url: URL) throws -> String {
        guard let result = realpath(url.path, nil) else {
            throw UninstallError.unsafe("Cannot resolve \(url.path)")
        }
        defer { free(result) }
        return String(cString: result)
    }

    private static func signature(_ url: URL) throws -> (identifier: String, team: String?) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
            SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess
        else {
            throw UninstallError.unsafe("Could not validate the selected executable: \(url.path)")
        }
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let values = information as? [String: Any],
            let identifier = values[kSecCodeInfoIdentifier as String] as? String
        else {
            throw UninstallError.unsafe("Could not inspect the selected executable signature.")
        }
        return (identifier, values[kSecCodeInfoTeamIdentifier as String] as? String)
    }
}

struct UninstallMove: Codable, Sendable {
    let source: URL
    let destination: URL
    let identity: UninstallIdentity
}

/// Only allowlisted data entries are considered. Shared roots and links are always kept.
enum UninstallOperation {
    static func inventory(_ request: UninstallRequest) throws -> [UninstallMove] {
        try request.validateRoots()
        let fm = FileManager.default
        var candidates: [(URL, String)] = []
        var protected = request.protectedPaths
        let config = request.home.appendingPathComponent("config")
        if request.removes(.connections) {
            for name in [
                "engines.json", "mcp-servers.json", "memory.json", "credentials.json", ".memory-v1-initialized",
            ] {
                candidates.append((config.appendingPathComponent(name), "home/config/\(name)"))
            }
        }
        if request.removes(.memory) {
            candidates.append((request.home.appendingPathComponent("memory"), "home/memory"))
        }
        if request.removes(.customizations) {
            for name in ["skills", "extensions", "config/themes", "config/themes.json", "config/.themes-v1-migrated"] {
                candidates.append((request.home.appendingPathComponent(name), "home/\(name)"))
            }
        }
        let projects = request.home.appendingPathComponent("projects")
        if request.removesHomeData, fm.fileExists(atPath: projects.path) {
            _ = try UninstallIdentity.read(projects)
            guard projects.resolvingSymlinksInPath().path == projects.path else {
                throw UninstallError.unsafe("Pen folders are linked. Keep GOAT Home data for manual review.")
            }
            for folder in try fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) {
                let metadata = folder.appendingPathComponent("project.json")
                guard fm.fileExists(atPath: metadata.path) else { continue }
                _ = try UninstallIdentity.read(folder)
                _ = try UninstallIdentity.read(metadata)
                let size = try fm.attributesOfItem(atPath: metadata.path)[.size] as? NSNumber
                guard let size, size.intValue <= 1_048_576,
                    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any],
                    let id = json["id"] as? String, UUID(uuidString: id) != nil
                else { throw UninstallError.unsafe("Could not validate Pen metadata: \(folder.path)") }
                if let workspace = json["workspace"] as? [String: Any], let path = workspace["path"] as? String {
                    protected.append(URL(fileURLWithPath: path))
                }
                for file in json["files"] as? [[String: Any]] ?? [] {
                    if let path = file["path"] as? String { protected.append(URL(fileURLWithPath: path)) }
                }
                let base = "home/projects/\(folder.lastPathComponent)"
                if request.removes(.pens) {
                    for name in ["project.json", "README.md", "AGENTS.md", "CLAUDE.md"] {
                        candidates.append((folder.appendingPathComponent(name), "\(base)/\(name)"))
                    }
                }
                if request.removes(.memory) {
                    candidates.append((folder.appendingPathComponent("memory"), "\(base)/memory"))
                }
                if request.removes(.customizations) {
                    candidates.append((folder.appendingPathComponent("skills"), "\(base)/skills"))
                }
            }
        }
        if request.removes(.chats) {
            for name in ["goat.sqlite", "goat.sqlite-wal", "goat.sqlite-shm", "Attachments"] {
                candidates.append((request.support.appendingPathComponent(name), "application-support/\(name)"))
            }
        }
        if !request.keepPreferences {
            let state = fm.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Saved Application State/\(request.preferencesDomain).savedState")
            candidates.append((state, "saved-window-state"))
        }
        var result: [UninstallMove] = []
        let recoveryIdentity = try UninstallIdentity.read(request.recovery)
        for (source, relative) in candidates {
            try collect(
                source, relative: relative, request: request, protected: protected,
                device: recoveryIdentity.device, result: &result)
        }
        return result
    }

    private static func collect(
        _ source: URL, relative: String, request: UninstallRequest,
        protected: [URL], device: Int32, result: inout [UninstallMove]
    ) throws {
        var info = stat()
        guard lstat(source.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw UninstallError.unsafe("Cannot inspect \(source.path)")
        }
        // Never traverse a link, including one in an ancestor. Linked entries remain in place.
        guard info.st_mode & S_IFMT != S_IFLNK else { return }
        guard source.resolvingSymlinksInPath().standardizedFileURL.path == source.standardizedFileURL.path else {
            throw UninstallError.unsafe("A data location contains a link: \(source.path)")
        }
        guard
            !protected.contains(where: {
                UninstallRequest.contains($0, source) || UninstallRequest.contains(source, $0)
            })
        else {
            throw UninstallError.unsafe(
                "A selected data location overlaps an external project or referenced file. Keep that category: \(source.path)"
            )
        }
        let identity = try UninstallIdentity.read(source)
        guard identity.device == device else {
            throw UninstallError.unsafe("Choose a recovery folder on the same volume as the selected data.")
        }
        if identity.kind == S_IFDIR {
            for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try collect(
                    child, relative: "\(relative)/\(child.lastPathComponent)", request: request,
                    protected: protected, device: device, result: &result)
            }
        } else {
            result.append(
                UninstallMove(
                    source: source, destination: request.recovery.appendingPathComponent("data/\(relative)"),
                    identity: identity))
        }
    }

    /// Called only after the parent has exited and the exclusive maintenance lock is held.
    /// App/CLI trashing is injected so fixture tests never touch the user's Trash.
    static func execute(_ request: UninstallRequest, trash: (URL) throws -> Void) throws {
        guard kill(request.parentPID, 0) != 0, errno == ESRCH else {
            throw UninstallError.unsafe("GOAT is still running. No data has been moved.")
        }
        let moves = try inventory(request)
        let fm = FileManager.default
        let requestURL = request.recovery.appendingPathComponent("request.json")
        try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestURL.path)
        let manifest = request.recovery.appendingPathComponent("plan.json")
        try JSONEncoder().encode(moves).write(to: manifest, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
        var completed: [UninstallMove] = []
        for move in moves {
            try request.validateRoots()
            guard try UninstallIdentity.read(move.source) == move.identity,
                move.source.resolvingSymlinksInPath().standardizedFileURL.path == move.source.standardizedFileURL.path
            else {
                throw UninstallError.unsafe("A file changed after review. See the recovery plan: \(move.source.path)")
            }
            let parent = move.destination.deletingLastPathComponent()
            guard parent.resolvingSymlinksInPath().standardizedFileURL.path == parent.standardizedFileURL.path else {
                throw UninstallError.unsafe(
                    "A recovery directory was replaced by a link. No further files will be moved.")
            }
            try fm.createDirectory(
                at: parent, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            guard !fm.fileExists(atPath: move.destination.path), rename(move.source.path, move.destination.path) == 0
            else {
                throw UninstallError.unsafe(
                    "Could not move \(move.source.path). Earlier moves remain in the recovery folder.")
            }
            completed.append(move)
            try JSONEncoder().encode(completed).write(
                to: request.recovery.appendingPathComponent("completed.json"), options: .atomic)
        }
        if !request.keepPreferences {
            let defaults = UserDefaults.standard
            let values = defaults.persistentDomain(forName: request.preferencesDomain) ?? [:]
            let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
            let url = request.recovery.appendingPathComponent("preferences.plist")
            try data.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            defaults.removePersistentDomain(forName: request.preferencesDomain)
            guard defaults.synchronize() else {
                throw UninstallError.unsafe("Could not finish clearing app preferences.")
            }
        }
        try request.validateRoots()
        if let cli = request.cli { try trash(cli) }
        try trash(request.app)
    }
}
