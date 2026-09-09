import Foundation
import Testing

@testable import GOAT
@testable import Inference
@testable import Persistence

private func persistenceTestDatabase() throws -> ChatDatabase {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("goat-app-writer-\(UUID().uuidString).sqlite").path
    return try ChatDatabase(path: path)
}

private func persistenceChat(id: String = UUID().uuidString, penID: String? = nil) -> ChatRecord {
    ChatRecord(
        id: id, projectId: penID, title: "Test", pinned: false, modelId: nil,
        effort: "trot", createdAt: .now, updatedAt: .now)
}

@Test func equalOrOlderChatRevisionCannotReplayAfterDelete() async throws {
    let database = try persistenceTestDatabase()
    let writer = AppDatabaseWriter(database: database)
    let chat = persistenceChat()

    #expect(try await writer.saveChat(chat, revision: 1))
    #expect(try await writer.deleteChat(id: chat.id, revision: 2))
    #expect(!(try await writer.saveChat(chat, revision: 2)))
    #expect(!(try await writer.saveChat(chat, revision: 1)))
    #expect(try await database.chats().isEmpty)
}

@Test func stalePenDeletionCannotClearANewerRelink() async throws {
    let database = try persistenceTestDatabase()
    let writer = AppDatabaseWriter(database: database)
    let penID = UUID().uuidString
    var chat = persistenceChat(penID: penID)

    #expect(try await writer.saveChat(chat, revision: 1))
    chat.title = "Newer state"
    #expect(try await writer.saveChat(chat, revision: 3))

    #expect(
        !(try await writer.clearPenLinks(
            id: penID, revisions: [chat.id: 2])))
    #expect(try await database.chats().first?.projectId == penID)
}

@Test func newerEngineReloadRejectsOlderAndEqualWrites() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("goat-engine-writer-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("engines.json")
    let worker = AppFileWorker()

    let load = try await worker.loadEngineFile(from: fileURL, revision: 2)
    guard case .missing = load else {
        Issue.record("Expected a missing-file reload")
        return
    }
    let profile = EngineProfile(
        id: "local", name: "Local", url: "http://127.0.0.1:8000")
    let file = EngineStore.File(active: profile.id, engines: [profile])

    #expect(!(try await worker.saveEngineFile(file, to: fileURL, revision: 1)))
    #expect(!(try await worker.saveEngineFile(file, to: fileURL, revision: 2)))
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    #expect(try await worker.saveEngineFile(file, to: fileURL, revision: 3))
    let stored = try #require(try EngineStore.load(from: fileURL))
    #expect(stored.active == file.active)
    #expect(stored.engines == file.engines)
}

@Test func concurrentNewerDeleteCannotBeUndoneByAnOlderSave() async throws {
    for _ in 0..<20 {
        let database = try persistenceTestDatabase()
        let writer = AppDatabaseWriter(database: database)
        let chat = persistenceChat()

        let save = Task { try await writer.saveChat(chat, revision: 1) }
        await Task.yield()
        let delete = Task { try await writer.deleteChat(id: chat.id, revision: 2) }
        _ = try await (save.value, delete.value)

        #expect(try await database.chats().isEmpty)
    }
}

@Test func staleMessageRatingCannotOverwriteANewerChoice() async throws {
    let database = try persistenceTestDatabase()
    let writer = AppDatabaseWriter(database: database)
    let chat = persistenceChat()
    let messageID = UUID().uuidString
    try await database.save(chat)
    try await database.save(
        MessageRecord(
            id: messageID,
            chatId: chat.id,
            role: "assistant",
            text: "Answer",
            thinking: "",
            error: nil,
            statsTtft: nil,
            statsTokens: nil,
            statsDuration: nil,
            complete: true,
            position: 0,
            createdAt: .now))

    #expect(try await writer.setMessageRating(id: messageID, rating: 1, revision: 2))
    #expect(!(try await writer.setMessageRating(id: messageID, rating: -1, revision: 1)))
    let saved = try #require(try await database.messages(chatId: chat.id).first)
    #expect(saved.rating == 1)
}
