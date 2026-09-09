import Foundation

public struct PackageManifest: Codable, Sendable {
    public let formatVersion: Int
    public let apiVersion: Int
    public let id: String
    public let name: String
    public let version: String
    public let author: String
    public let description: String
    public let permissions: [String]
    public let skills: [String]
    public let prompts: [String]
    public let mcp: [PackageMCPConnection]
}

/// Inert setup suggestions. The host's MCP editor owns validation, testing and saving.
/// Credentials are deliberately excluded from portable package manifests.
public struct PackageMCPConnection: Codable, Sendable, Identifiable {
    public let name: String
    public let command: String?
    public let arguments: [String]?
    public let url: String?
    public var id: String { name }
}

/// Validated immutable review content. Import and activation use these exact bytes, never reopen
/// the selected source file after the user has reviewed it. All resources stay in memory.
public struct ExtensionPackage: Sendable {
    public let manifest: PackageManifest
    public let archive: Data
    public let fileNames: [String]
    private let files: [String: String]
    private let definitions: [String: FileSkillProvider.ParsedSkill]

    public init(archive: Data) throws {
        let entries = try PackageArchive.files(in: archive)
        guard let json = entries["extension.json"], json.count <= 64 * 1_024,
            let object = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        else { throw PackageError.invalidManifest }
        let keys: Set<String> = [
            "formatVersion", "apiVersion", "id", "name", "version", "author", "description", "permissions", "skills",
            "prompts", "mcp",
        ]
        guard Set(object.keys) == keys else { throw PackageError.invalidManifest }
        let manifest: PackageManifest
        do { manifest = try JSONDecoder().decode(PackageManifest.self, from: json) } catch {
            throw PackageError.invalidManifest
        }
        guard manifest.formatVersion == 1, manifest.apiVersion == 1 else { throw PackageError.unsupportedVersion }
        guard Self.validID(manifest.id), Self.shortText(manifest.name, maximum: 80),
            Self.shortText(manifest.author, maximum: 120), Self.shortText(manifest.description, maximum: 2_048),
            manifest.version.split(separator: ".", omittingEmptySubsequences: false).count == 3,
            manifest.version.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }),
            manifest.version.utf8.count <= 32,
            manifest.version.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }),
            manifest.skills.count <= 16, manifest.prompts.count <= 16, manifest.mcp.count <= 8,
            manifest.skills.count + manifest.prompts.count + manifest.mcp.count > 0,
            Set(manifest.skills).count == manifest.skills.count,
            Set(manifest.prompts).count == manifest.prompts.count,
            Set(manifest.mcp.map { $0.name.lowercased() }).count == manifest.mcp.count
        else { throw PackageError.invalidManifest }
        var required = Set<String>()
        if !manifest.skills.isEmpty { required.insert("skill-resources") }
        if !manifest.prompts.isEmpty { required.insert("prompt-context") }
        if !manifest.mcp.isEmpty { required.insert("mcp-setup") }
        guard Set(manifest.permissions) == required, manifest.permissions.count == required.count else {
            throw PackageError.invalidManifest
        }
        guard let connections = object["mcp"] as? [[String: Any]] else { throw PackageError.invalidManifest }
        for (connection, raw) in zip(manifest.mcp, connections) {
            guard Set(raw.keys).isSubset(of: ["name", "command", "arguments", "url"]),
                Self.shortText(connection.name, maximum: 80)
            else { throw PackageError.invalidManifest }
            if let url = connection.url {
                guard connection.command == nil, connection.arguments == nil,
                    let parsed = URLComponents(string: url), ["http", "https"].contains(parsed.scheme),
                    parsed.host != nil, parsed.user == nil, parsed.password == nil,
                    parsed.query == nil, parsed.fragment == nil, url.utf8.count <= 4_096
                else { throw PackageError.invalidManifest }
            } else {
                guard let command = connection.command, Self.shortText(command, maximum: 1_024),
                    !command.hasPrefix("-"), let arguments = connection.arguments, arguments.count <= 64,
                    arguments.allSatisfy({ $0.utf8.count <= 4_096 && !$0.contains("\0") })
                else { throw PackageError.invalidManifest }
            }
        }
        var textFiles: [String: String] = [:]
        for (path, bytes) in entries {
            guard let text = String(data: bytes, encoding: .utf8), !text.contains("\0") else {
                throw PackageError.invalidContents
            }
            guard
                path == "extension.json" || manifest.prompts.contains(path)
                    || manifest.skills.contains(where: { path.hasPrefix("skills/\($0)/") })
            else { throw PackageError.invalidContents }
            textFiles[path] = text
        }
        var definitions: [String: FileSkillProvider.ParsedSkill] = [:]
        for name in manifest.skills {
            guard PackageArchive.validPath(name), !name.contains("/"),
                let document = textFiles["skills/\(name)/SKILL.md"],
                document.utf8.count <= FileSkillProvider.maximumSkillBytes
            else { throw PackageError.invalidContents }
            do {
                definitions[name] = try FileSkillProvider.parse(document: document, expectedName: name)
            } catch {
                // Do not echo arbitrary frontmatter into an import error or alert.
                throw PackageError.invalidContents
            }
        }
        var promptBytes = 0
        for path in manifest.prompts {
            guard PackageArchive.validPath(path), path.hasPrefix("prompts/"), path.hasSuffix(".md"),
                let text = textFiles[path], !text.isEmpty
            else { throw PackageError.invalidContents }
            promptBytes += text.utf8.count
        }
        guard promptBytes <= 16 * 1_024 else { throw PackageError.invalidContents }
        self.manifest = manifest
        self.archive = archive
        self.fileNames = entries.keys.sorted()
        self.files = textFiles
        self.definitions = definitions
    }

    public func text(at path: String) -> String? { files[path] }

    public var extensionValue: some Extension {
        let provider = PackageSkillProvider(package: self, definitions: definitions)
        return DeclarativeExtension(
            manifest: ExtensionManifest(id: manifest.id, version: manifest.version),
            contributions: ExtensionContributions(
                prompts: manifest.prompts.isEmpty
                    ? [] : [PackagePrompt(text: manifest.prompts.compactMap { files[$0] }.joined(separator: "\n\n"))],
                skills: manifest.skills.isEmpty ? [] : [provider]))
    }

    public static func validID(_ id: String) -> Bool {
        id.utf8.count <= 100 && id.contains(".") && !id.hasPrefix("goat.") && !id.hasPrefix("dev.leet.")
            && id.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
                !part.isEmpty && part.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
            }
    }

    private static func shortText(_ text: String, maximum: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= maximum
            && !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}

private struct DeclarativeExtension: Extension {
    let manifest: ExtensionManifest
    let contributions: ExtensionContributions
}

private struct PackagePrompt: PromptProvider {
    let text: String
    func prompt(for context: ExtensionContext) async throws -> String { text }
}

private struct PackageSkillProvider: SkillProvider {
    let package: ExtensionPackage
    let definitions: [String: FileSkillProvider.ParsedSkill]
    var providerID: String { package.manifest.id + ".skills" }
    var source: SkillSource { .runtime(package.manifest.name) }

    func listSkills() async throws -> [SkillCandidate] {
        definitions.values.sorted { $0.name < $1.name }.map {
            SkillCandidate(
                name: $0.name, description: $0.description, source: source, invocation: $0.invocation,
                providerID: providerID)
        }
    }

    func loadSkill(named name: String) async throws -> SkillDefinition {
        guard let skill = definitions[name] else { throw SkillError.notFound(name) }
        return SkillDefinition(
            summary: SkillSummary(
                identity: SkillIdentity(
                    extensionID: ExtensionID(rawValue: package.manifest.id), scope: .application,
                    providerID: providerID, name: name),
                name: name, description: skill.description, source: source, invocation: skill.invocation),
            instructions: skill.instructions)
    }

    func readResource(skill name: String, path: String) async throws -> String {
        guard definitions[name] != nil, PackageArchive.validPath(path),
            let text = package.text(at: "skills/\(name)/\(path)")
        else { throw SkillError.unreadableResource(path) }
        return text
    }
}
