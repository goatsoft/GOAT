import CryptoKit
import Darwin
import Foundation

/// One server entry from mcp-servers.json (Claude Desktop-compatible, ADR-0009).
public struct MCPServerConfig: Identifiable, Sendable, Equatable {
    public enum Transport: Sendable, Equatable {
        case stdio(command: String, args: [String], env: [String: String])
        case http(url: URL, headers: [String: String])
    }

    public var name: String
    public var transport: Transport
    public var disabled: Bool
    /// Only app-owned integrations may opt in to plain HTTP on a literal private-network IPv4
    /// endpoint. Entries loaded from an MCP configuration file always use the secure default.
    public let allowsPrivateNetworkHTTP: Bool

    public var id: String { name }

    public init(
        name: String,
        transport: Transport,
        disabled: Bool = false,
        allowsPrivateNetworkHTTP: Bool = false
    ) {
        self.name = name
        self.transport = transport
        self.disabled = disabled
        self.allowsPrivateNetworkHTTP = allowsPrivateNetworkHTTP
    }

    public var summary: String {
        switch transport {
        case .stdio(let command, let args, _): ([command] + args).joined(separator: " ")
        case .http(let url, _): url.absoluteString
        }
    }

    /// A stable identity for permission grants. It intentionally includes credentials and other
    /// transport values, but exposes only their SHA-256 digest, so changing where or how a server
    /// runs invalidates grants issued to its previous configuration.
    public var permissionFingerprint: String {
        var fields = ["goat-mcp-permission-v1", "name", name]
        if allowsPrivateNetworkHTTP {
            fields.append(contentsOf: ["allows-private-network-http", "true"])
        }
        switch transport {
        case .stdio(let command, let args, let env):
            fields.append(contentsOf: ["transport", "stdio", "command", command])
            for argument in args { fields.append(contentsOf: ["argument", argument]) }
            for key in env.keys.sorted() {
                fields.append(contentsOf: ["environment-key", key, "environment-value", env[key] ?? ""])
            }
        case .http(let url, let headers):
            fields.append(contentsOf: ["transport", "http", "url", url.absoluteString])
            for key in headers.keys.sorted() {
                fields.append(contentsOf: ["header-name", key, "header-value", headers[key] ?? ""])
            }
        }
        var canonical = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            var byteCount = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &byteCount) { canonical.append(contentsOf: $0) }
            canonical.append(bytes)
        }
        let hexadecimal = Array("0123456789abcdef".utf8)
        let digestBytes = SHA256.hash(data: canonical).flatMap { byte in
            [hexadecimal[Int(byte >> 4)], hexadecimal[Int(byte & 0x0F)]]
        }
        return String(decoding: digestBytes, as: UTF8.self)
    }

    /// Validate values before persisting or launching a server. MCP server names are also used as
    /// routing and permission identifiers, so accepting names which normalize to the same token
    /// would let one server inherit another server's route or grant.
    public func validate() throws {
        guard Self.isValidName(name) else { throw MCPConfigFile.ConfigError.invalidServerName(name) }

        switch transport {
        case .stdio(let command, let args, let env):
            guard
                !command.isEmpty,
                command.utf8.count <= 4096,
                !command.hasPrefix("-"),
                !command.contains("="),
                !Self.containsNull(command)
            else {
                throw MCPConfigFile.ConfigError.invalidCommand(name)
            }
            guard
                args.count <= 1024,
                args.reduce(into: 0, { $0 += $1.utf8.count }) <= 1_048_576,
                args.allSatisfy({ $0.utf8.count <= 65_536 && !Self.containsNull($0) })
            else {
                throw MCPConfigFile.ConfigError.invalidCommand(name)
            }
            guard env.count <= 256,
                env.reduce(into: 0, { $0 += $1.key.utf8.count + $1.value.utf8.count }) <= 1_048_576
            else { throw MCPConfigFile.ConfigError.invalidEnvironment(name) }
            for (key, value) in env {
                guard
                    key.utf8.count <= 256,
                    value.utf8.count <= 65_536,
                    Self.isValidEnvironmentKey(key),
                    !Self.containsNull(value)
                else {
                    throw MCPConfigFile.ConfigError.invalidEnvironment(name)
                }
            }

        case .http(let url, let headers):
            guard
                let scheme = url.scheme?.lowercased(),
                let host = url.host,
                scheme == "https"
                    || (scheme == "http"
                        && (Self.isExplicitLoopbackHost(host)
                            || (allowsPrivateNetworkHTTP
                                && Self.isExplicitPrivateNetworkIPv4Host(host)))),
                url.user == nil,
                url.password == nil,
                url.port.map({ 1...65_535 ~= $0 }) ?? true,
                url.absoluteString.utf8.count <= 16_384
            else {
                throw MCPConfigFile.ConfigError.invalidHTTPURL(name)
            }
            guard
                headers.count <= 128,
                headers.reduce(into: 0, { $0 += $1.key.utf8.count + $1.value.utf8.count }) <= 1_048_576
            else { throw MCPConfigFile.ConfigError.invalidHTTPHeader(name) }
            var normalizedFields = Set<String>()
            for (field, value) in headers {
                guard
                    field.utf8.count <= 256,
                    value.utf8.count <= 65_536,
                    Self.isValidHTTPHeaderField(field),
                    Self.isValidHTTPHeaderValue(value)
                else {
                    throw MCPConfigFile.ConfigError.invalidHTTPHeader(name)
                }
                let normalizedField = field.lowercased()
                guard normalizedFields.insert(normalizedField).inserted else {
                    throw MCPConfigFile.ConfigError.invalidHTTPHeader(name)
                }
                guard !Self.transportOwnedHTTPHeaders.contains(normalizedField) else {
                    throw MCPConfigFile.ConfigError.reservedHTTPHeader(field)
                }
            }
        }
    }

    private static func isValidName(_ name: String) -> Bool {
        guard 1...64 ~= name.utf8.count else { return false }
        return name.unicodeScalars.allSatisfy {
            $0.isASCII
                && ((65...90).contains($0.value) || (97...122).contains($0.value)
                    || (48...57).contains($0.value) || $0 == "_" || $0 == "-")
        }
    }

    private static func isValidEnvironmentKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first,
            first.isASCII
                && ((65...90).contains(first.value) || (97...122).contains(first.value) || first == "_")
        else { return false }
        return key.unicodeScalars.dropFirst().allSatisfy {
            $0.isASCII
                && ((65...90).contains($0.value) || (97...122).contains($0.value)
                    || (48...57).contains($0.value) || $0 == "_")
        }
    }

    private static func isValidHTTPHeaderField(_ field: String) -> Bool {
        guard !field.isEmpty else { return false }
        let separators = CharacterSet(charactersIn: "()<>@,;:\\\"/[]?={} \t")
        return field.unicodeScalars.allSatisfy {
            $0.isASCII && $0.value > 31 && $0.value < 127 && !separators.contains($0)
        }
    }

    private static func isValidHTTPHeaderValue(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy {
            $0.value == 9 || ($0.value >= 32 && $0.value != 127)
        }
    }

    private static func containsNull(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value == 0 }
    }

    /// Plain HTTP is only safe for an explicitly local endpoint. Hostnames which merely resolve
    /// to loopback are intentionally excluded because their DNS answer can change after review.
    private static func isExplicitLoopbackHost(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }

        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            return UInt32(bigEndian: ipv4.s_addr) >> 24 == 127
        }

        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, host, &ipv6) == 1 else { return false }
        return withUnsafeBytes(of: &ipv6) { bytes in
            bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
        }
    }

    /// This accepts a numeric address only, rather than resolving a hostname that could be
    /// rebound after the user approved it. The ranges cover RFC 1918 and IPv4 link-local.
    private static func isExplicitPrivateNetworkIPv4Host(_ host: String) -> Bool {
        var ipv4 = in_addr()
        guard inet_pton(AF_INET, host, &ipv4) == 1 else { return false }
        let address = UInt32(bigEndian: ipv4.s_addr)
        let first = UInt8((address >> 24) & 0xFF)
        let second = UInt8((address >> 16) & 0xFF)
        return first == 10
            || (first == 172 && (16...31).contains(second))
            || (first == 192 && second == 168)
            || (first == 169 && second == 254)
    }

    private static let transportOwnedHTTPHeaders: Set<String> = [
        "accept", "connection", "content-length", "content-type", "host",
        "mcp-protocol-version", "mcp-session-id", "transfer-encoding",
    ]
}

/// Reads/writes the config file. The file is the source of truth; edits go through
/// JSONSerialization so unknown keys and unknown servers survive round-trips untouched.
public enum MCPConfigFile {
    public static let maximumConfiguredServers = 128
    public static let maximumEnabledServers = 32

    public static func load(from url: URL) throws -> [MCPServerConfig] {
        guard try pathMode(url) != nil else {
            try writeRoot(["mcpServers": [String: Any]()], to: url)
            return []
        }
        let root = try readRoot(url)
        let servers = try serverDictionary(in: root)
        let configs = try parsedConfigs(in: servers)
        return configs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func upsert(_ config: MCPServerConfig, renamedFrom oldName: String? = nil, in url: URL) throws {
        try config.validate()
        if let oldName { try validateServerName(oldName) }
        var root = try rootForMutation(url)
        var servers = try serverDictionary(in: root)
        _ = try parsedConfigs(in: servers)
        if let oldName, oldName != config.name {
            guard servers[oldName] != nil else { throw ConfigError.serverNotFound(oldName) }
            guard servers[config.name] == nil else { throw ConfigError.serverAlreadyExists(config.name) }
            servers.removeValue(forKey: oldName)
        }
        servers[config.name] = entryDict(for: config)
        root["mcpServers"] = servers
        try writeRoot(root, to: url)
    }

    public static func remove(name: String, from url: URL) throws {
        try validateServerName(name)
        var root = try rootForMutation(url)
        var servers = try serverDictionary(in: root)
        _ = try parsedConfigs(in: servers)
        guard servers.removeValue(forKey: name) != nil else { throw ConfigError.serverNotFound(name) }
        root["mcpServers"] = servers
        try writeRoot(root, to: url)
    }

    public static func setDisabled(_ disabled: Bool, name: String, in url: URL) throws {
        try validateServerName(name)
        var root = try rootForMutation(url)
        var servers = try serverDictionary(in: root)
        _ = try parsedConfigs(in: servers)
        guard let rawEntry = servers[name] else { throw ConfigError.serverNotFound(name) }
        guard var entry = rawEntry as? [String: Any] else { throw ConfigError.invalidServerEntry(name) }
        guard let config = try parse(name: name, entry: entry) else {
            throw ConfigError.invalidServerEntry(name)
        }
        try config.validate()
        if disabled { entry["disabled"] = true } else { entry.removeValue(forKey: "disabled") }
        servers[name] = entry
        root["mcpServers"] = servers
        try writeRoot(root, to: url)
    }

    /// Merge servers from another Claude-Desktop-shaped JSON config. Existing names are kept.
    public static func importServers(from source: URL, into url: URL) throws -> [String] {
        try importParsed(loadImportSource(from: source), into: url)
    }

    /// Merge already-parsed servers (e.g. from Codex's TOML), keeping existing names. Imported
    /// servers are added **disabled** so nothing connects or spends context budget until the user
    /// reviews and enables it. Returns the names imported.
    public static func importParsed(_ configs: [MCPServerConfig], into url: URL) throws -> [String] {
        for config in configs { try config.validate() }
        var root = try rootForMutation(url)
        var servers = try serverDictionary(in: root)
        _ = try parsedConfigs(in: servers)
        var existing = Set(servers.keys)
        var imported: [String] = []
        for var config in configs where !existing.contains(config.name) {
            config.disabled = true
            servers[config.name] = entryDict(for: config)
            existing.insert(config.name)
            imported.append(config.name)
        }
        guard !imported.isEmpty else { return [] }
        root["mcpServers"] = servers
        try writeRoot(root, to: url)
        return imported
    }

    // MARK: Internals

    private static func loadImportSource(from url: URL) throws -> [MCPServerConfig] {
        let root = try readRoot(url, tightenPermissions: false)
        let configs = try parsedConfigs(in: serverDictionary(in: root))
        return configs.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func readRoot(
        _ url: URL, tightenPermissions: Bool = true
    ) throws -> [String: Any] {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw ConfigError.unsafeConfigFile }
            throw posixError()
        }
        var shouldCloseDescriptor = true
        defer {
            if shouldCloseDescriptor { close(descriptor) }
        }
        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0 else { throw posixError() }
        guard (fileInfo.st_mode & S_IFMT) == S_IFREG else {
            throw ConfigError.unsafeConfigFile
        }
        guard tightenPermissions || fileInfo.st_uid == geteuid() else {
            throw ConfigError.unsafeConfigFile
        }
        guard fileInfo.st_size <= 5 * 1024 * 1024 else { throw ConfigError.configTooLarge }
        if tightenPermissions {
            guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw posixError() }
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        shouldCloseDescriptor = false
        let data = try handle.read(upToCount: 5 * 1024 * 1024 + 1) ?? Data()
        try handle.close()
        guard data.count <= 5 * 1024 * 1024 else { throw ConfigError.configTooLarge }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigError.notAnObject
        }
        return root
    }

    private static func rootForMutation(_ url: URL) throws -> [String: Any] {
        guard try pathMode(url) != nil else { return [:] }
        return try readRoot(url)
    }

    private static func serverDictionary(in root: [String: Any]) throws -> [String: Any] {
        guard let raw = root["mcpServers"] else { return [:] }
        guard let servers = raw as? [String: Any] else { throw ConfigError.invalidServers }
        guard servers.count <= maximumConfiguredServers else {
            throw ConfigError.tooManyServers(maximumConfiguredServers)
        }
        return servers
    }

    private static func parsedConfigs(in servers: [String: Any]) throws -> [MCPServerConfig] {
        var configs: [MCPServerConfig] = []
        for (name, value) in servers {
            guard let entry = value as? [String: Any] else { throw ConfigError.invalidServerEntry(name) }
            guard let config = try parse(name: name, entry: entry) else { continue }
            try config.validate()
            configs.append(config)
        }
        guard configs.lazy.filter({ !$0.disabled }).count <= maximumEnabledServers else {
            throw ConfigError.tooManyEnabledServers(maximumEnabledServers)
        }
        return configs
    }

    private static func validateServerName(_ name: String) throws {
        let placeholder = MCPServerConfig(
            name: name,
            transport: .stdio(command: "validation", args: [], env: [:]))
        guard (try? placeholder.validate()) != nil else { throw ConfigError.invalidServerName(name) }
    }

    private static func writeRoot(_ root: [String: Any], to url: URL) throws {
        // Mutations can add an entry after the source file was validated, so enforce the same
        // admission limits again on the complete object immediately before serialization.
        _ = try parsedConfigs(in: serverDictionary(in: root))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        guard data.count <= 5 * 1024 * 1024 else { throw ConfigError.configTooLarge }
        if let mode = try pathMode(url), (mode & S_IFMT) != S_IFREG {
            throw ConfigError.unsafeConfigFile
        }

        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600))
        guard descriptor >= 0 else { throw posixError() }
        var shouldUnlink = true
        var shouldCloseDescriptor = true
        defer {
            if shouldCloseDescriptor { close(descriptor) }
            if shouldUnlink { unlink(temporaryURL.path) }
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw posixError() }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        shouldCloseDescriptor = false
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(temporaryURL.path, url.path) == 0 else { throw posixError() }
        shouldUnlink = false

        let directoryDescriptor = open(
            url.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC | O_DIRECTORY)
        if directoryDescriptor >= 0 {
            _ = fsync(directoryDescriptor)
            close(directoryDescriptor)
        }
    }

    private static func pathMode(_ url: URL) throws -> mode_t? {
        var fileInfo = stat()
        if lstat(url.path, &fileInfo) == 0 { return fileInfo.st_mode }
        guard errno == ENOENT else { throw posixError() }
        return nil
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    static func parse(name: String, entry: [String: Any]) throws -> MCPServerConfig? {
        let hasCommand = entry["command"] != nil
        let hasURL = entry["url"] != nil
        guard !(hasCommand && hasURL) else { throw ConfigError.invalidServerEntry(name) }
        let disabled: Bool
        if let rawDisabled = entry["disabled"] {
            guard let value = rawDisabled as? Bool else { throw ConfigError.invalidServerEntry(name) }
            disabled = value
        } else {
            disabled = false
        }

        if hasCommand {
            guard let command = entry["command"] as? String else {
                throw ConfigError.invalidServerEntry(name)
            }
            let args: [String]
            if let rawArgs = entry["args"] {
                guard let value = rawArgs as? [String] else { throw ConfigError.invalidServerEntry(name) }
                args = value
            } else {
                args = []
            }
            let env: [String: String]
            if let rawEnvironment = entry["env"] {
                guard let value = rawEnvironment as? [String: String] else {
                    throw ConfigError.invalidServerEntry(name)
                }
                env = value
            } else {
                env = [:]
            }
            return MCPServerConfig(
                name: name,
                transport: .stdio(command: command, args: args, env: env),
                disabled: disabled
            )
        }
        if hasURL {
            guard let raw = entry["url"] as? String, let url = URL(string: raw) else {
                throw ConfigError.invalidServerEntry(name)
            }
            let headers: [String: String]
            if let rawHeaders = entry["headers"] {
                guard let value = rawHeaders as? [String: String] else {
                    throw ConfigError.invalidServerEntry(name)
                }
                headers = value
            } else {
                headers = [:]
            }
            return MCPServerConfig(
                name: name,
                transport: .http(url: url, headers: headers),
                disabled: disabled
            )
        }
        return nil
    }

    static func entryDict(for config: MCPServerConfig) -> [String: Any] {
        var entry: [String: Any] = [:]
        switch config.transport {
        case .stdio(let command, let args, let env):
            entry["command"] = command
            if !args.isEmpty { entry["args"] = args }
            if !env.isEmpty { entry["env"] = env }
        case .http(let url, let headers):
            entry["url"] = url.absoluteString
            if !headers.isEmpty { entry["headers"] = headers }
        }
        if config.disabled { entry["disabled"] = true }
        return entry
    }

    public enum ConfigError: LocalizedError {
        case notAnObject
        case configTooLarge
        case invalidServers
        case invalidServerEntry(String)
        case invalidServerName(String)
        case invalidCommand(String)
        case invalidEnvironment(String)
        case invalidHTTPURL(String)
        case invalidHTTPHeader(String)
        case reservedHTTPHeader(String)
        case serverAlreadyExists(String)
        case serverNotFound(String)
        case tooManyServers(Int)
        case tooManyEnabledServers(Int)
        case unsafeConfigFile

        public var errorDescription: String? {
            switch self {
            case .notAnObject:
                "mcp-servers.json is not a JSON object"
            case .configTooLarge:
                "MCP configuration exceeds the 5 MB safety limit"
            case .invalidServers:
                "mcp-servers.json contains an invalid mcpServers value"
            case .invalidServerEntry(let name):
                "MCP server \"\(name)\" has an invalid transport configuration"
            case .invalidServerName(let name):
                "MCP server name \"\(name)\" must use 1-64 letters, numbers, underscores, or hyphens"
            case .invalidCommand(let name):
                "MCP server \"\(name)\" has an invalid command or argument"
            case .invalidEnvironment(let name):
                "MCP server \"\(name)\" has an invalid environment entry"
            case .invalidHTTPURL(let name):
                "MCP server \"\(name)\" must use HTTPS, or HTTP with an explicit loopback host or approved private-network IP, without embedded credentials"
            case .invalidHTTPHeader(let name):
                "MCP server \"\(name)\" has an invalid HTTP header"
            case .reservedHTTPHeader(let field):
                "HTTP header \"\(field)\" is owned by the MCP transport"
            case .serverAlreadyExists(let name):
                "MCP server \"\(name)\" already exists"
            case .serverNotFound(let name):
                "MCP server \"\(name)\" was not found"
            case .tooManyServers(let limit):
                "MCP configuration contains more than \(limit) servers"
            case .tooManyEnabledServers(let limit):
                "MCP configuration enables more than \(limit) servers"
            case .unsafeConfigFile:
                "MCP configuration must be a regular file, not a symbolic link or special file"
            }
        }
    }
}
