import Darwin
import Foundation

public actor FileSkillProvider: SkillProvider {
    public static let maximumSkillBytes = 256 * 1_024
    public static let maximumResourceBytes = 1 * 1_024 * 1_024
    public static let maximumSkills = 128

    public nonisolated let providerID: String
    private let root: URL
    private let source: SkillSource

    public init(providerID: String, root: URL, source: SkillSource) {
        self.providerID = providerID
        self.root = root
        self.source = source
    }

    public func listSkills() async throws -> [SkillCandidate] {
        guard let rootDescriptor = try Self.openDirectory(root) else { return [] }
        defer { Darwin.close(rootDescriptor) }
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        guard names.count <= Self.maximumSkills else {
            throw SkillError.invalidFrontmatter(
                "\(root.path) contains more than \(Self.maximumSkills) entries")
        }

        var candidates: [SkillCandidate] = []
        for folderName in names where !folderName.hasPrefix(".") {
            candidates.append(try skillCandidate(folderName, relativeTo: rootDescriptor))
        }
        return candidates
    }

    private func skillCandidate(_ folderName: String, relativeTo rootDescriptor: Int32) throws
        -> SkillCandidate
    {
        guard Self.isValidName(folderName) else {
            throw SkillError.invalidName(folderName)
        }
        guard let skillDescriptor = try Self.openDirectory(folderName, relativeTo: rootDescriptor) else {
            throw SkillError.unreadableResource(folderName)
        }
        defer { Darwin.close(skillDescriptor) }
        let document = try Self.readFile(
            "SKILL.md", relativeTo: skillDescriptor, maximumBytes: Self.maximumSkillBytes)
        let parsed = try Self.parse(document: document, expectedName: folderName)
        return SkillCandidate(
            name: parsed.name,
            description: parsed.description,
            source: source,
            invocation: parsed.invocation,
            providerID: providerID)
    }

    public func loadSkill(named name: String) async throws -> SkillDefinition {
        guard Self.isValidName(name) else { throw SkillError.invalidName(name) }
        guard let rootDescriptor = try Self.openDirectory(root) else {
            throw SkillError.notFound(name)
        }
        defer { Darwin.close(rootDescriptor) }
        guard let skillDescriptor = try Self.openDirectory(name, relativeTo: rootDescriptor) else {
            throw SkillError.notFound(name)
        }
        defer { Darwin.close(skillDescriptor) }
        let document = try Self.readFile(
            "SKILL.md", relativeTo: skillDescriptor, maximumBytes: Self.maximumSkillBytes)
        let parsed = try Self.parse(document: document, expectedName: name)
        let identity = SkillIdentity(
            extensionID: ExtensionID(rawValue: "unregistered"),
            scope: .application,
            providerID: providerID,
            name: parsed.name)
        return SkillDefinition(
            summary: SkillSummary(
                identity: identity,
                name: parsed.name,
                description: parsed.description,
                source: source,
                invocation: parsed.invocation),
            instructions: parsed.instructions)
    }

    public func readResource(skill name: String, path: String) async throws -> String {
        guard Self.isValidName(name) else { throw SkillError.invalidName(name) }
        let components = try Self.resourceComponents(path)
        guard let rootDescriptor = try Self.openDirectory(root) else {
            throw SkillError.notFound(name)
        }
        defer { Darwin.close(rootDescriptor) }
        guard let skillDescriptor = try Self.openDirectory(name, relativeTo: rootDescriptor) else {
            throw SkillError.notFound(name)
        }
        defer { Darwin.close(skillDescriptor) }

        var current = Darwin.dup(skillDescriptor)
        guard current >= 0 else { throw SkillError.unreadableResource(path) }
        defer { Darwin.close(current) }
        for component in components.dropLast() {
            guard let next = try Self.openDirectory(component, relativeTo: current) else {
                throw SkillError.unreadableResource(path)
            }
            Darwin.close(current)
            current = next
        }
        return try Self.readFile(
            try components.last.requireResourceComponent(path),
            relativeTo: current,
            maximumBytes: Self.maximumResourceBytes)
    }
}

extension FileSkillProvider {
    struct ParsedSkill: Sendable {
        let name: String
        let description: String
        let invocation: SkillInvocation
        let instructions: String
    }

    static func parse(document: String, expectedName: String) throws -> ParsedSkill {
        guard !document.contains("\r") else {
            throw SkillError.invalidFrontmatter("carriage returns are not supported")
        }
        let lines = document.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == "---",
            let closing = lines.dropFirst().firstIndex(of: "---")
        else {
            throw SkillError.invalidFrontmatter("SKILL.md requires bounded YAML frontmatter")
        }

        var values: [String: String] = [:]
        for line in lines[1..<closing] {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"),
                let separator = line.firstIndex(of: ":")
            else {
                throw SkillError.invalidFrontmatter("only top-level scalar metadata is supported")
            }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, values[key] == nil else {
                throw SkillError.invalidFrontmatter("duplicate or empty metadata key")
            }
            values[key] = try scalar(rawValue)
        }

        guard let name = values["name"], isValidName(name), name == expectedName else {
            throw SkillError.invalidName(values["name"] ?? expectedName)
        }
        guard let description = values["description"], !description.isEmpty,
            description.utf8.count <= 1_024
        else {
            throw SkillError.invalidFrontmatter("description is missing or too large")
        }
        let modelInvocable =
            try boolean(
                values["disable-model-invocation"], default: false, key: "disable-model-invocation") == false
        let userInvocable = try boolean(
            values["user-invocable"], default: true, key: "user-invocable")
        let instructions = lines[(closing + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedSkill(
            name: name,
            description: description,
            invocation: SkillInvocation(
                modelInvocable: modelInvocable,
                userInvocable: userInvocable),
            instructions: instructions)
    }

    fileprivate static func scalar(_ raw: String) throws -> String {
        guard raw != "|", raw != ">", !raw.isEmpty else {
            throw SkillError.invalidFrontmatter("multiline or empty scalar metadata is unsupported")
        }
        if raw.hasPrefix("\"") || raw.hasSuffix("\"") {
            guard raw.hasPrefix("\""), raw.hasSuffix("\""),
                let data = raw.data(using: .utf8),
                let decoded = try? JSONDecoder().decode(String.self, from: data)
            else {
                throw SkillError.invalidFrontmatter("invalid quoted scalar")
            }
            return decoded
        }
        if raw.hasPrefix("'") || raw.hasSuffix("'") {
            guard raw.hasPrefix("'"), raw.hasSuffix("'"), raw.count >= 2 else {
                throw SkillError.invalidFrontmatter("invalid quoted scalar")
            }
            return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return raw
    }

    fileprivate static func boolean(_ value: String?, default defaultValue: Bool, key: String) throws -> Bool {
        guard let value else { return defaultValue }
        switch value {
        case "true": return true
        case "false": return false
        default: throw SkillError.invalidFrontmatter("\(key) must be true or false")
        }
    }

    fileprivate static func isValidName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64,
            value.first != "-", value.last != "-"
        else { return false }
        var previousWasHyphen = false
        for scalar in value.unicodeScalars {
            let validAlpha = scalar.value >= 97 && scalar.value <= 122
            let validDigit = scalar.value >= 48 && scalar.value <= 57
            if scalar == "-" {
                if previousWasHyphen { return false }
                previousWasHyphen = true
            } else if validAlpha || validDigit {
                previousWasHyphen = false
            } else {
                return false
            }
        }
        return true
    }

    fileprivate static func resourceComponents(_ path: String) throws -> [String] {
        guard !path.isEmpty, !path.hasPrefix("/"), path.utf8.count <= 1_024 else {
            throw SkillError.invalidResourcePath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.count <= 16 else {
            throw SkillError.invalidResourcePath(path)
        }
        for component in components {
            let allowed = component.unicodeScalars.allSatisfy { scalar in
                CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "-" || scalar == "_" || scalar == "."
            }
            guard !component.isEmpty, component != ".", component != "..",
                !component.hasPrefix("."), component.utf8.count <= 128, allowed
            else {
                throw SkillError.invalidResourcePath(path)
            }
        }
        return components
    }

    fileprivate static func openDirectory(_ url: URL) throws -> Int32? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw SkillError.unreadableResource(url.path)
        }
        return descriptor
    }

    fileprivate static func openDirectory(_ name: String, relativeTo parent: Int32) throws -> Int32? {
        let descriptor = Darwin.openat(
            parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw SkillError.unreadableResource(name)
        }
        return descriptor
    }

    fileprivate static func readFile(
        _ name: String,
        relativeTo parent: Int32,
        maximumBytes: Int
    ) throws -> String {
        let descriptor = Darwin.openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw SkillError.unreadableResource(name) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG,
            status.st_size >= 0,
            UInt64(status.st_size) <= UInt64(maximumBytes)
        else {
            throw SkillError.unreadableResource(name)
        }
        do {
            let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            guard data.count <= maximumBytes, let value = String(data: data, encoding: .utf8) else {
                throw SkillError.unreadableResource(name)
            }
            return value
        } catch let error as SkillError {
            throw error
        } catch {
            throw SkillError.unreadableResource(name)
        }
    }
}

extension Optional where Wrapped == String {
    fileprivate func requireResourceComponent(_ path: String) throws -> String {
        guard let self else { throw SkillError.invalidResourcePath(path) }
        return self
    }
}
