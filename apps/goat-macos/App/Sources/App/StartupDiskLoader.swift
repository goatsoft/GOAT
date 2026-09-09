import Caprine
import Foundation
import Herd
import Inference
import Pens
import Persistence

struct LegacyEngineSettings: Sendable {
    let endpoint: String?
    let presetID: String?
}

struct StartupPenSnapshot: Sendable {
    let spec: PenSpec
    let instructions: String
}

struct StartupDiskSnapshot: Sendable {
    let database: ChatDatabase?
    let databaseWarning: String?
    let persistenceReady: Bool
    let engineFile: EngineStore.File
    let engineStoreWritable: Bool
    let engineCredentials: [String: String]
    let installedApplicationPaths: Set<String>
    let themes: [ThemeSpec]
    let pens: [StartupPenSnapshot]
    let chats: [ChatRecord]
}

/// Loads and migrates local stores before publishing one immutable startup snapshot.
enum StartupDiskLoader {
    static func load(
        legacy: LegacyEngineSettings
    ) async -> StartupDiskSnapshot {
        var warnings: [String] = []
        let engineFile: EngineStore.File
        let engineStoreWritable: Bool
        do {
            let loaded = try loadOrMigrateEngines(legacy)
            engineFile = loaded.file
            if let warning = loaded.warning { warnings.append(warning) }
            engineStoreWritable = true
        } catch {
            warnings.append("Engine settings were not loaded: \(error.localizedDescription)")
            engineFile = fallbackEngineFile(legacy)
            let url = Home.enginesFile
            engineStoreWritable =
                !FileManager.default.fileExists(atPath: url.path)
                && (try? FileManager.default.attributesOfItem(atPath: url.path)) == nil
        }
        let credentialKeys = engineFile.engines.map { AppModel.keyStore($0.id) }
        let engineCredentials: [String: String]
        do {
            let stored = try CredentialStore.load()
            engineCredentials = credentialKeys.reduce(into: [:]) { result, key in
                if let value = stored[key], !value.isEmpty { result[key] = value }
            }
        } catch {
            warnings.append("Credentials were not loaded: \(error.localizedDescription)")
            engineCredentials = [:]
        }
        let applicationPaths = engineFile.engines.compactMap { profile -> String? in
            guard case .app(let path, _) = profile.preset.management else { return nil }
            return path
        }
        let installedApplicationPaths = Set(
            applicationPaths.filter { FileManager.default.fileExists(atPath: $0) })
        var persistenceReady = false
        let database: ChatDatabase?
        do {
            database = try ChatDatabase()
            dlog("startup: db open")
        } catch {
            database = nil
            warnings.append("Persistence unavailable: \(error.localizedDescription)")
            dlog("startup: db FAILED \(error)")
        }

        var chatRecords: [ChatRecord] = []
        if let database {
            do {
                try await migrateProjectsToPensIfNeeded(database)
            } catch {
                warnings.append("Legacy Pens were not migrated: \(error.localizedDescription)")
            }
            do {
                let stored = try await database.chats()
                chatRecords = stored.filter { Self.canonicalUUID($0.id) != nil }
                let invalidCount = stored.count - chatRecords.count
                if invalidCount > 0 {
                    warnings.append(
                        "Ignored \(invalidCount) chat record\(invalidCount == 1 ? "" : "s") with invalid IDs.")
                }
                persistenceReady = true
            } catch {
                warnings.append("Load failed: \(error.localizedDescription)")
            }
        }
        let penSnapshots: [StartupPenSnapshot]
        do {
            penSnapshots = try PenStore.snapshots().map { snapshot in
                StartupPenSnapshot(
                    spec: snapshot.spec, instructions: snapshot.instructions)
            }
        } catch {
            warnings.append("Pens were not loaded: \(error.localizedDescription)")
            penSnapshots = []
        }
        let themes: [ThemeSpec]
        do {
            try ThemeStore.migrateLegacyFileIfNeeded()
            themes = try ThemeStore.all()
        } catch {
            warnings.append("Themes were not loaded: \(error.localizedDescription)")
            themes = []
        }
        return StartupDiskSnapshot(
            database: database,
            databaseWarning: warnings.isEmpty ? nil : warnings.joined(separator: "\n"),
            persistenceReady: persistenceReady,
            engineFile: engineFile,
            engineStoreWritable: engineStoreWritable,
            engineCredentials: engineCredentials,
            installedApplicationPaths: installedApplicationPaths,
            themes: themes,
            pens: penSnapshots,
            chats: chatRecords)
    }

    /// Preserve an existing list or migrate an explicitly configured legacy connection.
    static func loadOrMigrateEngines(
        _ settings: LegacyEngineSettings, at url: URL = Home.enginesFile
    ) throws -> (file: EngineStore.File, warning: String?) {
        if let file = try EngineStore.load(from: url) {
            var warning: String?
            do {
                if let legacy = try CredentialStore.get("engine.apiKey"),
                    let profile = file.engines.first,
                    try CredentialStore.get(AppModel.keyStore(profile.id)) == legacy
                {
                    try CredentialStore.delete("engine.apiKey")
                }
            } catch {
                warning = "Legacy credential cleanup failed: \(error.localizedDescription)"
            }
            return (file, warning)
        }
        let file = fallbackEngineFile(settings)
        var migratedLegacyCredential = false
        if let legacy = try CredentialStore.get("engine.apiKey"), !legacy.isEmpty,
            let profile = file.engines.first
        {
            try CredentialStore.set(legacy, for: AppModel.keyStore(profile.id))
            migratedLegacyCredential = true
        }
        try EngineStore.save(file, to: url)
        var warning: String?
        if migratedLegacyCredential {
            do {
                try CredentialStore.delete("engine.apiKey")
            } catch {
                warning = "Engine migrated, but its legacy credential was not removed: \(error.localizedDescription)"
            }
        }
        return (file, warning)
    }

    static func fallbackEngineFile(
        _ settings: LegacyEngineSettings
    ) -> EngineStore.File {
        let preset = EnginePreset.management(forPresetID: settings.presetID)
        let endpoint = settings.endpoint?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidate = endpoint.flatMap({ $0.isEmpty ? nil : $0 }) ?? preset.url else {
            return EngineStore.File(active: nil, engines: [])
        }
        let oldURL = safeEngineEndpoint(candidate)
        let profile = EngineProfile(
            id: preset.id == "custom" ? "engine" : preset.id,
            name: preset.id == "custom" ? "Custom" : preset.name,
            url: oldURL,
            presetID: preset.id == "custom" ? nil : preset.id)
        return EngineStore.File(active: profile.id, engines: [profile])
    }

    private static func safeEngineEndpoint(_ candidate: String?) -> String {
        guard let candidate, let url = URL(string: candidate),
            let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            url.host != nil, url.user == nil, url.password == nil,
            url.query == nil, url.fragment == nil
        else { return "http://127.0.0.1:8000" }
        return candidate
    }

    /// Resume the one-time move of DB projects into Pen folders by creating every missing ID.
    /// Legacy rows remain in place, so a launch interrupted after one folder can continue safely.
    private static func migrateProjectsToPensIfNeeded(_ db: ChatDatabase) async throws {
        let records = try await db.projects()
        guard !records.isEmpty else { return }
        var existingIDs = Set(try PenStore.all().map(\.id))
        var migrated = 0
        for (i, record) in records.enumerated() {
            guard let canonicalID = UUID(uuidString: record.id)?.uuidString else {
                throw LocalStoreError.invalidData(
                    path: record.id, reason: "legacy Pen ID must be a UUID")
            }
            guard !existingIDs.contains(canonicalID) else { continue }
            let spec = PenSpec(
                id: canonicalID, name: record.name, emoji: record.emoji,
                color: OKLCH.palette[i % OKLCH.palette.count], createdAt: record.createdAt)
            try PenStore.save(spec, instructions: record.instructions)
            existingIDs.insert(canonicalID)
            migrated += 1
        }
        if migrated > 0 { dlog("migrated \(migrated) project(s) to ~/.goat/projects") }
    }

    private static func canonicalUUID(_ value: String) -> UUID? {
        guard let id = UUID(uuidString: value), id.uuidString == value else { return nil }
        return id
    }
}
