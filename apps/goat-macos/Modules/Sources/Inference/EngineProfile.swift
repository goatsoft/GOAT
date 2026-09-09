import Foundation
import Herd

/// Engine settings persisted in `~/.goat/config/engines.json` (ADR-0021).
/// The active profile supplies the generation endpoint. API keys are stored separately
/// in `credentials.json`, keyed by profile ID (ADR-0012).
public struct EngineProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var url: String
    /// The preset this profile follows, for its blurb + "manage models" affordance; nil = custom.
    public var presetID: String?
    /// Explicit request semantics for this engine. Existing configs decode as `.automatic`.
    public var requestStyle: EngineRequestStyle

    public init(
        id: String = UUID().uuidString, name: String, url: String, presetID: String? = nil,
        requestStyle: EngineRequestStyle = .automatic
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.presetID = presetID
        self.requestStyle = requestStyle
    }

    /// The preset backing this profile (custom when it follows none).
    public var preset: EnginePreset { EnginePreset.management(forPresetID: presetID) }

    /// A fresh profile seeded from a built-in preset (custom presets get a typed URL later).
    public init(preset: EnginePreset) {
        self.init(
            id: preset.id == "custom" ? UUID().uuidString : preset.id,
            name: preset.name,
            url: preset.url ?? "http://127.0.0.1:8000",
            presetID: preset.id == "custom" ? nil : preset.id)
    }

    private enum CodingKeys: String, CodingKey { case id, name, url, presetID, requestStyle }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(String.self, forKey: .url)
        presetID = try container.decodeIfPresent(String.self, forKey: .presetID)
        requestStyle =
            try container.decodeIfPresent(EngineRequestStyle.self, forKey: .requestStyle)
            ?? .automatic
    }
}

extension EnginePreset {
    /// The preset for a profile's stored id, falling back to `custom` (not the recommended one)
    /// so a hand-made engine keeps its neutral identity.
    public static func management(forPresetID id: String?) -> EnginePreset {
        all.first { $0.id == id } ?? .custom
    }
}

/// Reads and writes the engine list at `~/.goat/config/engines.json`. Plain, hand-editable JSON (
/// `{ "active": "<id>", "engines": [ … ] }`) mirroring how MCP servers are stored (ADR-0021).
public enum EngineStore {
    public struct File: Codable, Sendable {
        public var active: String?
        public var engines: [EngineProfile]

        public init(active: String?, engines: [EngineProfile]) {
            self.active = active
            self.engines = engines
        }
    }

    /// Missing is first-run state. Existing malformed or invalid JSON throws so startup never
    /// migrates over a hand-edited file that needs repair.
    public static func load(from url: URL) throws -> File? {
        guard let data = try LocalFileStore.dataIfPresent(at: url) else { return nil }
        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: data)
        } catch {
            throw LocalStoreError.invalidData(
                path: url.path, reason: error.localizedDescription)
        }
        try validate(file, at: url)
        return file
    }

    public static func save(_ file: File, to url: URL) throws {
        try validate(file, at: url)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(file)
        } catch {
            throw LocalStoreError.invalidData(
                path: url.path, reason: error.localizedDescription)
        }
        guard data.count <= LocalFileStore.maximumManagedFileBytes else {
            throw LocalStoreError.invalidData(
                path: url.path, reason: "engine configuration exceeds the permitted byte count")
        }
        try LocalFileStore.write(data, to: url)
    }

    private static func validate(_ file: File, at url: URL) throws {
        let ids = file.engines.map(\.id)
        guard ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else {
            throw LocalStoreError.invalidData(
                path: url.path, reason: "engine IDs must be non-empty and unique")
        }
        guard
            file.engines.allSatisfy({ profile in
                guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    let endpoint = URL(string: profile.url),
                    let scheme = endpoint.scheme?.lowercased(), endpoint.user == nil,
                    endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil
                else { return false }
                return (scheme == "http" || scheme == "https") && endpoint.host != nil
            })
        else {
            throw LocalStoreError.invalidData(
                path: url.path,
                reason:
                    "every engine needs a name and credential-free absolute HTTP endpoint without query or fragment"
            )
        }
        if let active = file.active, !ids.contains(active) {
            throw LocalStoreError.invalidData(
                path: url.path, reason: "the active engine does not exist in the engine list")
        }
    }
}
