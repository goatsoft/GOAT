import Darwin
import Foundation

/// Reads MCP servers from OpenAI Codex CLI's `~/.codex/config.toml` (`[mcp_servers.NAME]` tables).
/// A deliberately small TOML reader for just the shapes Codex writes: command/args/env for stdio,
/// url/headers for HTTP. Anything it can't parse is skipped, never fatal.
public enum CodexConfig {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
    }

    public static func load(from url: URL) throws -> [MCPServerConfig] {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw MCPConfigFile.ConfigError.unsafeConfigFile }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var shouldCloseDescriptor = true
        defer {
            if shouldCloseDescriptor { close(descriptor) }
        }
        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard (fileInfo.st_mode & S_IFMT) == S_IFREG else {
            throw MCPConfigFile.ConfigError.unsafeConfigFile
        }
        guard fileInfo.st_uid == geteuid() else {
            throw MCPConfigFile.ConfigError.unsafeConfigFile
        }
        guard fileInfo.st_size <= 5 * 1024 * 1024 else {
            throw MCPConfigFile.ConfigError.configTooLarge
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        shouldCloseDescriptor = false
        let data = try handle.read(upToCount: 5 * 1024 * 1024 + 1) ?? Data()
        try handle.close()
        guard data.count <= 5 * 1024 * 1024 else {
            throw MCPConfigFile.ConfigError.configTooLarge
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return parse(text)
    }

    // MARK: Targeted TOML parse

    private struct Draft {
        var command: String?
        var args: [String] = []
        var url: String?
        var env: [String: String] = [:]
        var headers: [String: String] = [:]
    }

    static func parse(_ text: String) -> [MCPServerConfig] {
        var drafts: [String: Draft] = [:]
        var order: [String] = []
        var server: String?
        var sub: String?  // "env" / "headers" / nil (the server table itself)
        var arrayKey: String?  // accumulating a multi-line array value
        var arrayBuffer = ""

        for rawLine in text.components(separatedBy: .newlines) {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)

            // Continue accumulating a multi-line array until it closes (only `args` opens one).
            if arrayKey != nil {
                arrayBuffer += " " + line
                guard arrayBuffer.contains("]") else { continue }
                if let s = server { drafts[s]?.args = tomlStringArray(arrayBuffer) }
                arrayKey = nil
                arrayBuffer = ""
                continue
            }

            if line.isEmpty { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                let path = splitDottedKey(String(line.dropFirst().dropLast()))
                guard path.first == "mcp_servers", path.count >= 2 else {
                    server = nil
                    sub = nil
                    continue
                }
                let name = path[1]
                server = name
                sub = path.count >= 3 ? path[2] : nil
                if drafts[name] == nil {
                    drafts[name] = Draft()
                    order.append(name)
                }
                continue
            }

            guard let s = server, let (key, value) = splitKeyValue(line) else { continue }
            switch sub {
            case "env":
                if let v = tomlString(value) { drafts[s]?.env[key] = v }
            case "headers":
                if let v = tomlString(value) { drafts[s]?.headers[key] = v }
            default:
                switch key {
                case "command": drafts[s]?.command = tomlString(value)
                case "url": drafts[s]?.url = tomlString(value)
                case "env": drafts[s]?.env = tomlInlineTable(value)
                case "headers": drafts[s]?.headers = tomlInlineTable(value)
                case "args":
                    if value.contains("]") {
                        drafts[s]?.args = tomlStringArray(value)
                    } else {
                        arrayKey = "args"  // opens across lines; keep reading until ']'
                        arrayBuffer = value
                    }
                default: break
                }
            }
        }

        return order.compactMap { name in
            guard let d = drafts[name] else { return nil }
            if let command = d.command, !command.isEmpty {
                return MCPServerConfig(name: name, transport: .stdio(command: command, args: d.args, env: d.env))
            }
            if let raw = d.url, let u = URL(string: raw) {
                return MCPServerConfig(name: name, transport: .http(url: u, headers: d.headers))
            }
            return nil
        }
    }

    // MARK: Tiny TOML value helpers

    /// Drop a trailing `#` comment, respecting quoted strings.
    private static func stripComment(_ line: String) -> String {
        var out = ""
        var quote: Character?
        for ch in line {
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "#" {
                break
            }
            out.append(ch)
        }
        return out
    }

    /// Split a dotted key like `mcp_servers.name.env`, tolerating quoted segments.
    private static func splitDottedKey(_ s: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for ch in s.trimmingCharacters(in: .whitespaces) {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "." {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts.filter { !$0.isEmpty }
    }

    private static func splitKeyValue(_ line: String) -> (String, String)? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : (key, value)
    }

    private static func tomlString(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, let first = t.first, first == "\"" || first == "'", t.last == first else { return nil }
        let inner = String(t.dropFirst().dropLast())
        return
            inner
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func tomlStringArray(_ raw: String) -> [String] {
        guard let open = raw.firstIndex(of: "["), let close = raw.lastIndex(of: "]") else { return [] }
        let inner = String(raw[raw.index(after: open)..<close])
        return splitTopLevel(inner, separator: ",").compactMap { tomlString($0) }
    }

    private static func tomlInlineTable(_ raw: String) -> [String: String] {
        guard let open = raw.firstIndex(of: "{"), let close = raw.lastIndex(of: "}") else { return [:] }
        let inner = String(raw[raw.index(after: open)..<close])
        var dict: [String: String] = [:]
        for pair in splitTopLevel(inner, separator: ",") {
            if let (k, v) = splitKeyValue(pair), let value = tomlString(v) { dict[k] = value }
        }
        return dict
    }

    /// Split on `separator`, ignoring separators inside quotes.
    private static func splitTopLevel(_ s: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil }
                current.append(ch)
            } else if ch == "\"" || ch == "'" {
                quote = ch
                current.append(ch)
            } else if ch == separator {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { parts.append(last) }
        return parts
    }
}
