import Caprine
import Foundation
import Herd
import Inference
import Pens
import Persistence

enum EngineFileLoad: Sendable {
    case stale
    case missing
    case loaded(EngineStore.File)
}

enum ModelPreferencesFileLoad: Sendable {
    case stale
    case missing
    case loaded(ModelPreferencesFile)
}

struct ThemeMutationResult: Sendable {
    let themes: [ThemeSpec]
    let saved: ThemeSpec?
}

/// Serial executor for GOAT Home stores used by `AppModel` after startup.
///
/// Store types remain synchronous because they are also used by command-line tests and migrations.
/// This actor keeps filesystem latency off `MainActor` and rejects outdated writes by revision.
actor AppFileWorker {
    static let shared = AppFileWorker()
    private var engineRevision: UInt64 = 0
    private var modelPreferencesRevision: UInt64 = 0
    private var credentialRevisions: [String: UInt64] = [:]
    private var themeRevision: UInt64 = 0
    private var penRevisions: [String: UInt64] = [:]

    func loadEngineFile(from url: URL, revision: UInt64) throws -> EngineFileLoad {
        guard revision > engineRevision else { return .stale }
        engineRevision = revision
        guard let file = try EngineStore.load(from: url) else { return .missing }
        return .loaded(file)
    }

    func saveEngineFile(_ file: EngineStore.File, to url: URL, revision: UInt64) throws -> Bool {
        guard revision > engineRevision else { return false }
        engineRevision = revision
        try EngineStore.save(file, to: url)
        return true
    }

    func loadModelPreferences(from url: URL, revision: UInt64) throws -> ModelPreferencesFileLoad {
        guard revision > modelPreferencesRevision else { return .stale }
        modelPreferencesRevision = revision
        guard let file = try ModelPreferencesStore.load(from: url) else { return .missing }
        return .loaded(file)
    }

    func saveModelPreferences(
        _ file: ModelPreferencesFile, to url: URL, revision: UInt64
    ) throws -> Bool {
        guard revision > modelPreferencesRevision else { return false }
        modelPreferencesRevision = revision
        try ModelPreferencesStore.save(file, to: url)
        return true
    }

    func credential(for key: String) throws -> String? {
        try CredentialStore.get(key)
    }

    func credentials(for keys: [String]) throws -> [String: String] {
        guard !keys.isEmpty else { return [:] }
        let store = try CredentialStore.load()
        return keys.reduce(into: [:]) { result, key in
            if let value = store[key], !value.isEmpty { result[key] = value }
        }
    }

    func setCredential(_ value: String, for key: String, revision: UInt64) throws -> Bool {
        guard revision > (credentialRevisions[key] ?? 0) else { return false }
        credentialRevisions[key] = revision
        try CredentialStore.set(value, for: key)
        return true
    }

    func deleteCredential(_ key: String, revision: UInt64) throws -> Bool {
        guard revision > (credentialRevisions[key] ?? 0) else { return false }
        credentialRevisions[key] = revision
        try CredentialStore.delete(key)
        return true
    }

    /// Deletes an engine key only when the actor's current durable engine file no longer contains
    /// that ID. Serial execution with engine saves prevents stale cleanup from stripping a key
    /// after a newer re-add has already committed.
    func deleteCredentialIfEngineAbsent(
        _ key: String, engineID: String, engineFileURL: URL, revision: UInt64
    ) throws -> Bool? {
        guard revision > (credentialRevisions[key] ?? 0) else { return nil }
        credentialRevisions[key] = revision
        if let file = try EngineStore.load(from: engineFileURL),
            file.engines.contains(where: { $0.id == engineID })
        {
            return false
        }
        try CredentialStore.delete(key)
        return true
    }

    func loadThemes(revision: UInt64) throws -> [ThemeSpec]? {
        guard revision > themeRevision else { return nil }
        themeRevision = revision
        return try ThemeStore.all()
    }

    func saveTheme(
        _ spec: ThemeSpec, previewData: Data?, revision: UInt64
    ) throws -> ThemeMutationResult? {
        guard revision > themeRevision else { return nil }
        themeRevision = revision
        let saved = try ThemeStore.save(spec, previewData: previewData)
        return ThemeMutationResult(themes: try ThemeStore.all(), saved: saved)
    }

    func deleteTheme(id: String, revision: UInt64) throws -> [ThemeSpec]? {
        guard revision > themeRevision else { return nil }
        themeRevision = revision
        try ThemeStore.delete(id: id)
        return try ThemeStore.all()
    }

    func makeImportableTheme(from json: String) throws -> ThemeSpec {
        try ThemeStore.makeImportable(from: json)
    }

    func prepareThemeDuplicate(
        of spec: ThemeSpec,
        appearance: ThemeSpec.Appearance
    ) throws -> ThemeSpec {
        try ThemeStore.prepareDuplicate(of: spec, appearance: appearance)
    }

    func duplicateAndSaveTheme(
        _ spec: ThemeSpec, appearance: ThemeSpec.Appearance, revision: UInt64
    ) throws -> ThemeMutationResult? {
        guard revision > themeRevision else { return nil }
        themeRevision = revision
        let copy = try ThemeStore.prepareDuplicate(of: spec, appearance: appearance)
        let saved = try ThemeStore.save(copy)
        return ThemeMutationResult(themes: try ThemeStore.all(), saved: saved)
    }

    func importAndSaveTheme(
        from json: String, revision: UInt64
    ) throws -> ThemeMutationResult? {
        guard revision > themeRevision else { return nil }
        themeRevision = revision
        let spec = try ThemeStore.makeImportable(from: json)
        let saved = try ThemeStore.save(spec)
        return ThemeMutationResult(themes: try ThemeStore.all(), saved: saved)
    }

    func savePen(_ spec: PenSpec, instructions: String, revision: UInt64) throws -> Bool {
        guard revision > (penRevisions[spec.id] ?? 0) else { return false }
        penRevisions[spec.id] = revision
        try PenStore.save(spec, instructions: instructions)
        return true
    }

    func deletePen(id: String, revision: UInt64) throws -> Bool {
        guard revision > (penRevisions[id] ?? 0) else { return false }
        penRevisions[id] = revision
        try PenStore.delete(id: id)
        return true
    }

    func penFolder(id: String) throws -> URL? {
        try PenStore.folder(for: id)
    }

    func applicationExists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func existingApplications(in paths: [String]) -> Set<String> {
        Set(paths.filter { FileManager.default.fileExists(atPath: $0) })
    }
}

/// Revision-aware database writer for UI mutations. Calls may be launched from separate tasks, so
/// each chat carries a MainActor-issued revision and stale saves cannot resurrect a deleted chat or
/// restore an old Pen link after a newer mutation.
actor AppDatabaseWriter {
    private let database: ChatDatabase
    private var chatRevisions: [String: UInt64] = [:]
    private var messageRatingRevisions: [String: UInt64] = [:]
    private var mutationTail: Task<Void, Never>?

    init(database: ChatDatabase) {
        self.database = database
    }

    func saveChat(_ record: ChatRecord, revision: UInt64) async throws -> Bool {
        guard accept(revision, for: record.id) else { return false }
        let database = database
        try await serializeMutation {
            try await database.save(record)
        }
        return true
    }

    func deleteChat(id: String, revision: UInt64) async throws -> Bool {
        guard accept(revision, for: id) else { return false }
        let database = database
        try await serializeMutation {
            try await database.deleteChat(id: id)
        }
        return true
    }

    func clearPenLinks(id: String, revisions: [String: UInt64]) async throws -> Bool {
        guard
            revisions.allSatisfy({ chatID, revision in
                revision > (chatRevisions[chatID] ?? 0)
            })
        else { return false }
        for (chatID, revision) in revisions {
            chatRevisions[chatID] = revision
        }
        let database = database
        _ = try await serializeMutation {
            try await database.clearPenLinks(id: id)
        }
        return true
    }

    func saveMessage(_ record: MessageRecord) async throws {
        let database = database
        try await serializeMutation {
            try await database.save(record)
        }
    }

    func checkpointMessage(id: String, text: String, thinking: String) async throws {
        let database = database
        try await serializeMutation {
            try await database.checkpointMessage(id: id, text: text, thinking: thinking)
        }
    }

    func setMessageRating(id: String, rating: Int?, revision: UInt64) async throws -> Bool {
        guard revision > (messageRatingRevisions[id] ?? 0) else { return false }
        messageRatingRevisions[id] = revision
        let database = database
        try await serializeMutation {
            try await database.setMessageRating(id: id, rating: rating)
        }
        return true
    }

    func deleteMessage(id: String) async throws {
        let database = database
        try await serializeMutation {
            try await database.deleteMessage(id: id)
        }
    }

    private func accept(_ revision: UInt64, for chatID: String) -> Bool {
        guard revision > (chatRevisions[chatID] ?? 0) else { return false }
        chatRevisions[chatID] = revision
        return true
    }

    /// Actor methods are reentrant at `await`. Chaining every admitted database mutation keeps
    /// their durable execution order identical to their revision-admission order.
    private func serializeMutation<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let predecessor = mutationTail
        let task = Task<T, Error> {
            await predecessor?.value
            return try await operation()
        }
        mutationTail = Task {
            _ = try? await task.value
        }
        return try await task.value
    }
}
