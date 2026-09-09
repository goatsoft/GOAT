import Foundation
import Herd

/// A referenced file on a Pen - a pointer, never a copy (keeps Pens small). The bookmark
/// lets us reopen it across launches even if the user moves it.
public struct PenFileRef: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var path: String
    public var bookmark: Data?

    public init(id: String = UUID().uuidString, name: String, path: String, bookmark: Data? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.bookmark = bookmark
    }
}

/// A Pen's metadata, persisted as `project.json` in its folder. The prose (instructions,
/// agent guide) lives beside it as README.md / AGENTS.md so it's yours to edit.
public struct PenSpec: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var emoji: String
    public var color: OKLCH
    public var createdAt: Date
    public var files: [PenFileRef]
    public var workspace: PenWorkspace?

    public init(
        id: String = UUID().uuidString, name: String, emoji: String,
        color: OKLCH, createdAt: Date = .now, files: [PenFileRef] = [],
        workspace: PenWorkspace? = nil
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.color = color
        self.createdAt = createdAt
        self.files = files
        self.workspace = workspace
    }
}

/// Pens live as folders you own under `~/.goat/projects/<slug>/` (ADR-0019):
/// `project.json` (metadata) · `README.md` (your instructions) · `AGENTS.md` (the agent
/// guide, referencing README) · `CLAUDE.md` (one line → AGENTS.md). GRDB keeps only the
/// chat→pen link. Everything here is plain files, inspectable and hand-editable.
public enum PenStore {
    public struct Snapshot: Sendable, Equatable {
        public let spec: PenSpec
        public let instructions: String

        public init(spec: PenSpec, instructions: String) {
            self.spec = spec
            self.instructions = instructions
        }
    }

    public static var root: URL {
        Home.url.appendingPathComponent("projects", isDirectory: true)
    }

    public static func skillsDir(forProjectID projectID: UUID) throws -> URL? {
        try PenStore.folder(for: projectID.uuidString)?
            .appendingPathComponent("skills", isDirectory: true)
    }

    // MARK: Read

    public static func all() throws -> [PenSpec] {
        try all(in: root)
    }

    static func all(in root: URL) throws -> [PenSpec] {
        let specs = try LocalFileStore.childDirectories(in: root).map {
            try spec(atFolder: $0, root: root)
        }
        try requireUniqueIDs(specs, root: root)
        return specs.sorted { $0.createdAt < $1.createdAt }
    }

    /// Loads metadata and instructions in one directory traversal so startup remains O(N).
    public static func snapshots() throws -> [Snapshot] {
        try snapshots(in: root)
    }

    static func snapshots(in root: URL) throws -> [Snapshot] {
        let values = try LocalFileStore.childDirectories(in: root).map { folder in
            Snapshot(
                spec: try spec(atFolder: folder, root: root),
                instructions: try read(file: "README.md", in: folder))
        }
        try requireUniqueIDs(values.map(\.spec), root: root)
        return values.sorted { $0.spec.createdAt < $1.spec.createdAt }
    }

    public static func folder(for id: String) throws -> URL? {
        try folder(for: id, in: root)
    }

    static func folder(for id: String, in root: URL) throws -> URL? {
        try validatePenID(id)
        return try findFolder(byID: id, root: root)
    }

    public static func instructions(id: String) throws -> String {
        try read(id: id, file: "README.md", root: root)
    }

    public static func agents(id: String) throws -> String {
        try read(id: id, file: "AGENTS.md", root: root)
    }

    // MARK: Write

    /// Create or update a Pen: writes `project.json`, and (re)writes README.md; scaffolds
    /// AGENTS.md + CLAUDE.md once (they're yours to edit afterward).
    public static func save(_ spec: PenSpec, instructions: String) throws {
        try save(spec, instructions: instructions, in: root)
    }

    static func save(_ spec: PenSpec, instructions: String, in root: URL) throws {
        try validatePenID(spec.id)
        guard !spec.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalStoreError.invalidData(
                path: spec.id, reason: "pen name cannot be empty")
        }
        let dir = try folderURL(name: spec.name, id: spec.id, root: root)
        try LocalFileStore.ensureDirectory(at: root)
        if try LocalFileStore.directoryExists(at: dir) {
            let staging = try LocalFileStore.makeStagingCopy(of: dir, in: root)
            do {
                try write(spec, instructions: instructions, to: staging)
                try LocalFileStore.commitReplacingDirectory(staging, at: dir, in: root)
            } catch {
                try? LocalFileStore.removeItem(at: staging)
                throw error
            }
            return
        }
        let staging = try LocalFileStore.makeStagingDirectory(in: root)
        do {
            try write(spec, instructions: instructions, to: staging)
            try LocalFileStore.commitNewDirectory(staging, to: dir, in: root)
        } catch {
            try? LocalFileStore.removeItem(at: staging)
            throw error
        }
    }

    private static func write(_ spec: PenSpec, instructions: String, to dir: URL) throws {
        try LocalFileStore.ensureDirectory(at: dir)
        try write(instructions, to: dir.appendingPathComponent("README.md"))
        let agents = dir.appendingPathComponent("AGENTS.md")
        if !(try LocalFileStore.regularFileExists(at: agents)) {
            try write(agentsTemplate(name: spec.name), to: agents)
        }
        let claude = dir.appendingPathComponent("CLAUDE.md")
        if !(try LocalFileStore.regularFileExists(at: claude)) {
            try write(
                "# CLAUDE.md\n\nInstructions live in **[AGENTS.md](AGENTS.md)** - single source.\n",
                to: claude)
        }
        // Metadata is the discovery marker. Write it last after the companion files succeed.
        try writeJSON(spec, to: dir.appendingPathComponent("project.json"))
    }

    public static func delete(id: String) throws {
        try delete(id: id, in: root)
    }

    static func delete(id: String, in root: URL) throws {
        try validatePenID(id)
        if let dir = try findFolder(byID: id, root: root) {
            try LocalFileStore.removeItem(at: dir)
        }
    }

    // MARK: Internals

    private static func folderURL(name: String, id: String, root: URL) throws -> URL {
        if let existing = try findFolder(byID: id, root: root) { return existing }
        var slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { acc, ch in
            if ch == "-" && acc.hasSuffix("-") { return }
            acc.append(ch)
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "pen" }
        // Keep the directory recognizable without making its identity depend on a mutable name.
        // Existing folders are found above and deliberately retain their historic names.
        let boundedSlug = String(slug.prefix(48))
        let folderName = "\(boundedSlug)_\(id.lowercased())"
        var candidate = root.appendingPathComponent(folderName, isDirectory: true)
        try LocalFileStore.requireContained(candidate, in: root)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let existing = try spec(atFolder: candidate, root: root)
            if existing.id == id { return candidate }
            candidate = root.appendingPathComponent("\(folderName)-\(n)", isDirectory: true)
            try LocalFileStore.requireContained(candidate, in: root)
            n += 1
        }
        return candidate
    }

    private static func findFolder(byID id: String, root: URL) throws -> URL? {
        var match: URL?
        for dir in try LocalFileStore.childDirectories(in: root) {
            if try spec(atFolder: dir, root: root).id == id {
                guard match == nil else {
                    throw LocalStoreError.invalidData(
                        path: root.path, reason: "duplicate pen ID \(id)")
                }
                match = dir
            }
        }
        return match
    }

    private static func spec(atFolder dir: URL, root: URL) throws -> PenSpec {
        try LocalFileStore.requireContained(dir, in: root)
        let json = dir.appendingPathComponent("project.json")
        guard let data = try LocalFileStore.dataIfPresent(at: json) else {
            throw LocalStoreError.invalidData(
                path: json.path, reason: "project.json is missing")
        }
        let spec: PenSpec
        do {
            spec = try JSONDecoder.pen.decode(PenSpec.self, from: data)
        } catch {
            throw LocalStoreError.invalidData(
                path: json.path, reason: error.localizedDescription)
        }
        try validatePenID(spec.id)
        return spec
    }

    private static func read(id: String, file: String, root: URL) throws -> String {
        guard let dir = try findFolder(byID: id, root: root) else { return "" }
        return try read(file: file, in: dir)
    }

    private static func read(file: String, in dir: URL) throws -> String {
        try LocalFileStore.validateComponent(file, label: "pen filename")
        let url = dir.appendingPathComponent(file)
        try LocalFileStore.requireContained(url, in: dir)
        guard let data = try LocalFileStore.dataIfPresent(at: url) else { return "" }
        guard let value = String(data: data, encoding: .utf8) else {
            throw LocalStoreError.invalidData(
                path: url.path, reason: "file is not valid UTF-8")
        }
        return value
    }

    private static func write(_ s: String, to url: URL) throws {
        let data = Data(s.utf8)
        guard data.count <= LocalFileStore.maximumManagedFileBytes else {
            throw LocalStoreError.invalidData(
                path: url.path, reason: "Pen text exceeds the permitted byte count")
        }
        try LocalFileStore.write(data, to: url)
    }

    private static func writeJSON(_ spec: PenSpec, to url: URL) throws {
        let data: Data
        do {
            data = try JSONEncoder.pen.encode(spec)
        } catch {
            throw LocalStoreError.invalidData(
                path: url.path, reason: error.localizedDescription)
        }
        guard data.count <= LocalFileStore.maximumManagedFileBytes else {
            throw LocalStoreError.invalidData(
                path: url.path, reason: "Pen metadata exceeds the permitted byte count")
        }
        try LocalFileStore.write(data, to: url)
    }

    private static func validatePenID(_ id: String) throws {
        guard let value = UUID(uuidString: id), value.uuidString == id else {
            throw LocalStoreError.invalidData(
                path: id, reason: "pen ID must be a canonical UUID string")
        }
    }

    private static func requireUniqueIDs(_ specs: [PenSpec], root: URL) throws {
        let ids = specs.map(\.id)
        guard Set(ids).count == ids.count else {
            throw LocalStoreError.invalidData(
                path: root.path, reason: "pen IDs must be unique")
        }
    }

    private static func agentsTemplate(name: String) -> String {
        """
        # AGENTS.md - \(name)

        This is the Pen's app-managed agent guide. GOAT includes this guide and the
        Pen's brief (stored beside it as README.md) in the chat's project context.
        These metadata files are separate from the configured workspace. Do not assume
        README.md or AGENTS.md exists in the workspace, or copy this guide there unless asked.

        ## Ground rules (GOATed methodology)

        - **Keep it small and optimised.** Prefer the lean solution; delete before you add.
        - **Protocols at the seams.** Cross module boundaries through a protocol, not a concrete type.
        - **Decisions get an ADR.** Non-obvious calls are recorded, not relitigated in code.
        - **Tests land with behaviour.** New logic ships with a test for its surface.
        - **Comments are usage or why, never banter.** No personal or session references.

        ## How to work

        1. Use the Pen brief supplied in context for what this project is and wants.
        2. Make the smallest change that solves the problem; verify it.
        3. Update docs when behaviour moves.

        _Inspect workspace files with the supplied tools. An empty workspace is valid._
        """
    }
}

extension JSONEncoder {
    fileprivate static var pen: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    fileprivate static var pen: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
