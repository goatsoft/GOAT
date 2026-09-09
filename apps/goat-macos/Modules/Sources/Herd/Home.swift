import Foundation

/// The GOAT home: files the user owns (ADR-0009).
/// Resolution: GOAT_HOME env → Settings override → ~/.goat
public enum Home {
    public static var url: URL {
        if let env = ProcessInfo.processInfo.environment["GOAT_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let custom = UserDefaults.standard.string(forKey: "goat.home"), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".goat", isDirectory: true)
    }

    public static var configDir: URL {
        url.appendingPathComponent("config", isDirectory: true)
    }

    public static var mcpServersFile: URL {
        configDir.appendingPathComponent("mcp-servers.json")
    }

    public static var enginesFile: URL {
        configDir.appendingPathComponent("engines.json")
    }

    public static var memoryConfigurationFile: URL {
        configDir.appendingPathComponent("memory.json")
    }

    public static var memoryConfigurationMarker: URL {
        configDir.appendingPathComponent(".memory-v1-initialized")
    }

    public static var themesDir: URL {
        configDir.appendingPathComponent("themes", isDirectory: true)
    }

    public static var memoryDir: URL {
        url.appendingPathComponent("memory", isDirectory: true)
    }

    public static var skillsDir: URL {
        url.appendingPathComponent("skills", isDirectory: true)
    }

    /// Pens are folder-backed. Their local Wiki memory belongs beside the Pen, not in a shared
    /// application database. UUIDs are used because Pen display names are mutable and unsafe as
    /// path components.
    public static var projectsDir: URL {
        url.appendingPathComponent("projects", isDirectory: true)
    }

    public static func memoryDir(forProjectID projectID: UUID) -> URL {
        projectsDir
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
    }

}

/// Stores local credentials in an owner-only file (0600).
/// Ad-hoc signing changes app identity between builds, causing repeated Keychain prompts (ADR-0012).
public enum CredentialStore {
    private static var file: URL { Home.configDir.appendingPathComponent("credentials.json") }

    /// Missing is an empty store. An existing unreadable or malformed file throws so a later set
    /// cannot silently replace every credential with a one-key dictionary.
    public static func load() throws -> [String: String] {
        try load(from: file)
    }

    static func load(from file: URL) throws -> [String: String] {
        guard let data = try LocalFileStore.ownerOnlyDataIfPresent(at: file) else { return [:] }
        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            throw LocalStoreError.invalidData(
                path: file.path, reason: error.localizedDescription)
        }
    }

    public static func get(_ key: String) throws -> String? {
        let v = try load()[key]
        return (v?.isEmpty ?? true) ? nil : v
    }

    public static func set(_ value: String, for key: String) throws {
        try set(value, for: key, in: file)
    }

    static func set(_ value: String, for key: String, in file: URL) throws {
        var dict = try load(from: file)
        if value.isEmpty { dict.removeValue(forKey: key) } else { dict[key] = value }
        let data: Data
        do {
            data = try JSONEncoder().encode(dict)
        } catch {
            throw LocalStoreError.invalidData(
                path: file.path, reason: error.localizedDescription)
        }
        try LocalFileStore.writeOwnerOnly(data, to: file)
    }

    public static func delete(_ key: String) throws { try set("", for: key) }
}
