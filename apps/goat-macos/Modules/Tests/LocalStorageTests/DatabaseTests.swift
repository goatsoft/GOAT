import Foundation
import GRDB
import Testing

@testable import Persistence

private func tempDB() throws -> (ChatDatabase, String) {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("goat-test-\(UUID().uuidString).sqlite").path
    return (try ChatDatabase(path: path), path)
}

private func makeChat(id: String = UUID().uuidString, projectId: String? = nil) -> ChatRecord {
    ChatRecord(
        id: id, projectId: projectId, title: "Test", pinned: false, modelId: nil,
        effort: "trot", createdAt: .now, updatedAt: .now)
}

@Test func chatAndMessagesRoundTrip() async throws {
    let (db, _) = try tempDB()
    var chat = makeChat()
    chat.disabledMCPServers = ["zeta", "alpha"]
    try await db.save(chat)
    try await db.save(
        MessageRecord(
            id: "m1", chatId: chat.id, role: "assistant", text: "hi", thinking: "",
            error: nil, statsTtft: 1.25, statsTokens: 40, statsDuration: 2.25,
            statsGenerationTokensPerSecond: 41.5, statsTokensAreExact: true,
            statsCachedPromptTokens: 512,
            complete: true, position: 0, createdAt: .now))
    let chats = try await db.chats()
    let messages = try await db.messages(chatId: chat.id)
    #expect(chats.count == 1)
    #expect(chats.first?.disabledMCPServers == ["zeta", "alpha"])
    #expect(messages.first?.text == "hi")
    #expect(messages.first?.statsGenerationTokensPerSecond == 41.5)
    #expect(messages.first?.statsTokensAreExact == true)
    #expect(messages.first?.statsCachedPromptTokens == 512)
}

@Test func killedStreamIsSealedOnReopenKeepingCheckpointedText() async throws {
    let (db, path) = try tempDB()
    let chat = makeChat()
    try await db.save(chat)
    try await db.save(
        MessageRecord(
            id: "m1", chatId: chat.id, role: "assistant", text: "", thinking: "",
            error: nil, statsTtft: nil, statsTokens: nil, statsDuration: nil,
            complete: false, position: 0, createdAt: .now))
    try await db.checkpointMessage(id: "m1", text: "partial answer up to the crash", thinking: "hmm")
    // "Kill" the app: reopen the same file.
    let reopened = try ChatDatabase(path: path)
    let messages = try await reopened.messages(chatId: chat.id)
    #expect(messages.first?.complete == true)
    #expect(messages.first?.text == "partial answer up to the crash")
    #expect(messages.first?.thinking == "hmm")
    #expect(messages.first?.error == nil)
    #expect(messages.count == 2)
    #expect(messages.last?.error?.contains("interrupted") == true)
    let again = try ChatDatabase(path: path)
    #expect(try await again.messages(chatId: chat.id) == messages)
}

@Test func messageRatingPersistsWithoutRewritingContent() async throws {
    let (db, _) = try tempDB()
    let chat = makeChat()
    try await db.save(chat)
    try await db.save(
        MessageRecord(
            id: "m1", chatId: chat.id, role: "assistant", text: "answer", thinking: "", error: nil, statsTtft: nil,
            statsTokens: nil, statsDuration: nil, complete: true, position: 0, createdAt: .now))
    try await db.setMessageRating(id: "m1", rating: 1)
    let saved = try #require(try await db.messages(chatId: chat.id).first)
    #expect(saved.rating == 1)
    #expect(saved.text == "answer")
}

@Test func deletingChatCascadesToMessages() async throws {
    let (db, _) = try tempDB()
    let chat = makeChat()
    try await db.save(chat)
    try await db.save(
        MessageRecord(
            id: "m1", chatId: chat.id, role: "user", text: "x", thinking: "",
            error: nil, statsTtft: nil, statsTokens: nil, statsDuration: nil,
            complete: true, position: 0, createdAt: .now))
    try await db.deleteChat(id: chat.id)
    #expect(try await db.messages(chatId: chat.id).isEmpty)
    #expect(try await db.chats().isEmpty)
}

@Test func chatKeepsSoftPenPointerWithNoForeignKey() async throws {
    // Pens are folders you own (ADR-0019), not DB rows: a chat may point at a pen id that has
    // no matching row in the legacy `project` table. Saving that must succeed, not trip a
    // FOREIGN KEY constraint (regression for the v5 migration).
    let (db, _) = try tempDB()
    var chat = makeChat()
    try await db.save(chat)

    chat.projectId = "pen-not-in-db"  // a folder-backed pen, absent from `project`
    try await db.save(chat)
    #expect(try await db.chats().first?.projectId == "pen-not-in-db")

    chat.projectId = nil  // moved out to "No Pen"
    try await db.save(chat)
    #expect(try await db.chats().first?.projectId == nil)
}

@Test func deletingAPenClearsEveryChatLinkInOneWrite() async throws {
    let (db, _) = try tempDB()
    let penID = UUID().uuidString
    let linkedA = makeChat(projectId: penID)
    let linkedB = makeChat(projectId: penID)
    let other = makeChat(projectId: UUID().uuidString)
    try await db.save(linkedA)
    try await db.save(linkedB)
    try await db.save(other)

    #expect(try await db.clearPenLinks(id: penID) == 2)

    let chats = try await db.chats()
    #expect(chats.first(where: { $0.id == linkedA.id })?.projectId == nil)
    #expect(chats.first(where: { $0.id == linkedB.id })?.projectId == nil)
    #expect(chats.first(where: { $0.id == other.id })?.projectId == other.projectId)
}

@Test func deletingAPenAlsoClearsLegacyLowercaseUUIDLinks() async throws {
    let (db, _) = try tempDB()
    let penID = UUID().uuidString
    let linked = makeChat(projectId: penID.lowercased())
    try await db.save(linked)

    #expect(try await db.clearPenLinks(id: penID) == 1)
    #expect(try await db.chats().first?.projectId == nil)
}

@Test func toolGrantFingerprintRoundTripsAndLegacyNilFailsClosed() async throws {
    let (db, _) = try tempDB()
    try await db.setGrant(
        ToolGrantRecord(
            server: "files", tool: "read", policy: "always",
            configFingerprint: "sha256:current"))
    try await db.setGrant(
        ToolGrantRecord(server: "legacy", tool: "read", policy: "always"))

    let grants = try await db.grants()
    #expect(
        grants.first(where: { $0.server == "files" })?.configFingerprint
            == "sha256:current")
    #expect(grants.first(where: { $0.server == "legacy" })?.configFingerprint == nil)
}

@Test func v5ToolGrantsMigrateWithANilFingerprint() async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("goat-v5-grant-\(UUID().uuidString).sqlite").path
    let legacy = try DatabaseQueue(path: path)
    try await legacy.write { db in
        try db.execute(
            sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
        for identifier in [
            "v1", "v2-attachments", "v3-tools", "v4-chat-tools-switch",
            "v5-pen-link-no-fk",
        ] {
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                arguments: [identifier])
        }
        try db.execute(
            sql: """
                CREATE TABLE message (
                    id TEXT PRIMARY KEY, chatId TEXT NOT NULL, role TEXT NOT NULL,
                    text TEXT NOT NULL, thinking TEXT NOT NULL, error TEXT,
                    statsTtft DOUBLE, statsTokens INTEGER, statsDuration DOUBLE,
                    complete INTEGER NOT NULL, position INTEGER NOT NULL, createdAt DATETIME NOT NULL,
                    attachmentsJson TEXT, toolsJson TEXT
                )
                """)
        try db.execute(
            sql: """
                CREATE TABLE chat (
                    id TEXT PRIMARY KEY,
                    projectId TEXT,
                    title TEXT NOT NULL,
                    pinned INTEGER NOT NULL DEFAULT 0,
                    modelId TEXT,
                    effort TEXT NOT NULL,
                    createdAt DATETIME NOT NULL,
                    updatedAt DATETIME NOT NULL,
                    toolsEnabled INTEGER NOT NULL DEFAULT 1
                )
                """)
        try db.execute(
            sql:
                "CREATE TABLE tool_grant (server TEXT NOT NULL, tool TEXT NOT NULL, policy TEXT NOT NULL, PRIMARY KEY (server, tool))"
        )
        try db.execute(
            sql: "INSERT INTO tool_grant (server, tool, policy) VALUES (?, ?, ?)",
            arguments: ["legacy", "read", "always"])
    }

    let migrated = try ChatDatabase(path: path)
    let grant = try #require(try await migrated.grants().first)
    #expect(grant.server == "legacy")
    #expect(grant.configFingerprint == nil)
}

@Test func checkpointsOnlyUpdateStreamContentAndNeverResurrectDeletedMessages() async throws {
    let (db, _) = try tempDB()
    let chat = makeChat()
    try await db.save(chat)
    var message = MessageRecord(
        id: "checkpoint", chatId: chat.id, role: "assistant", text: "", thinking: "",
        error: nil, statsTtft: nil, statsTokens: nil, statsDuration: nil,
        complete: false, position: 0, createdAt: .now)
    message.rating = 1
    message.complete = true
    message.toolsJson = "[]"
    message.attachmentsJson = "[]"
    message.error = "retained error"
    try await db.save(message)
    try await db.checkpointMessage(id: message.id, text: "updated", thinking: "reasoning")
    let updated = try #require(try await db.messages(chatId: chat.id).first)
    #expect(updated.text == "updated" && updated.thinking == "reasoning")
    #expect(updated.rating == 1 && updated.complete && updated.error == message.error)
    #expect(updated.toolsJson == "[]" && updated.attachmentsJson == "[]")
    try await db.deleteMessage(id: message.id)
    try await db.checkpointMessage(id: message.id, text: "late", thinking: "")
    #expect(try await db.messages(chatId: chat.id).isEmpty)
}

@Test func reportCheckpointCostAgainstWholeRecordBaseline() async throws {
    let (db, path) = try tempDB()
    let chat = makeChat()
    try await db.save(chat)
    let message = MessageRecord(
        id: "benchmark", chatId: chat.id, role: "assistant", text: String(repeating: "answer ", count: 32_768),
        thinking: "reasoning", error: nil, statsTtft: nil, statsTokens: nil, statsDuration: nil,
        complete: false, position: 0, createdAt: .now,
        toolsJson: String(repeating: "tool result ", count: 8192))
    try await db.save(message)
    let baseline = try DatabasePool(path: path)
    var old: [Double] = []
    var narrow: [Double] = []
    func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
    for index in 0..<25 {
        let baselineText = message.text + "\(index)a"
        let narrowText = message.text + "\(index)b"
        let start = ContinuousClock.now
        try await baseline.write { connection in
            if var record = try MessageRecord.fetchOne(connection, key: message.id) {
                record.text = baselineText
                record.thinking = message.thinking
                try record.save(connection)
            }
        }
        old.append(ms(start.duration(to: .now)))
        let next = ContinuousClock.now
        try await db.checkpointMessage(id: message.id, text: narrowText, thinking: message.thinking)
        narrow.append(ms(next.duration(to: .now)))
    }
    print(
        "GOAT_BENCH checkpoint baseline_median_ms=\(old.sorted()[12]) narrow_median_ms=\(narrow.sorted()[12]) samples=25/25"
    )
    let plan = try await baseline.read { connection in
        try Row.fetchAll(
            connection, sql: "EXPLAIN QUERY PLAN SELECT * FROM message WHERE chatId = ? ORDER BY position",
            arguments: [chat.id]
        ).map { row -> String in row["detail"] }
    }
    #expect(plan.contains { $0.contains("USING INDEX") })
    #expect(!plan.contains { $0.contains("TEMP B-TREE") })
}

@Test func interruptedToolsKeepCompletedResultsAndDiscloseUnknownOutcomesAfterLead() async throws {
    let (db, path) = try tempDB()
    let chat = makeChat()
    try await db.save(chat)
    let events = [
        ToolEventSnapshot(id: "saved", server: "GOATed", tool: "pen_write_file", arguments: "{}", result: "saved"),
        ToolEventSnapshot(id: "pending", server: "GOATed", tool: "pen_edit_file", arguments: "{}"),
    ]
    let original = MessageRecord(
        id: "tools", chatId: chat.id, role: "assistant", text: "Editing your files", thinking: "",
        error: nil, statsTtft: nil, statsTokens: nil, statsDuration: nil,
        complete: true, position: 0, createdAt: .now,
        toolsJson: String(decoding: try JSONEncoder().encode(events), as: UTF8.self))
    try await db.save(original)
    let lead = MessageRecord(
        id: "lead", chatId: chat.id, role: "user", text: "Use Vue", thinking: "",
        error: nil, statsTtft: nil, statsTokens: nil, statsDuration: nil,
        complete: true, position: 1, createdAt: .now)
    try await db.save(lead)
    let storedLead = try #require(try await db.messages(chatId: chat.id).last)
    let reopened = try ChatDatabase(path: path)
    let messages = try await reopened.messages(chatId: chat.id)
    #expect(messages.count == 3)
    #expect(messages[0].text == original.text)
    #expect(messages[0].error == nil)
    #expect(messages[1] == storedLead)
    #expect(messages[2].error?.contains("interrupted") == true)
    let recovered = try JSONDecoder().decode(
        [ToolEventSnapshot].self, from: Data(try #require(messages[0].toolsJson).utf8))
    #expect(recovered[0] == events[0])
    #expect(recovered[1].result?.contains("outcome is unknown") == true)
    #expect(recovered[1].result?.contains("before retrying") == true)
    #expect(recovered[1].isError)
    #expect(!recovered[1].denied)
    let again = try ChatDatabase(path: path)
    #expect(try await again.messages(chatId: chat.id) == messages)
}

@Test func completedAndFailedResponsesDoNotAcquireRestartNotices() async throws {
    let (db, path) = try tempDB()
    let chat = makeChat()
    try await db.save(chat)
    for (index, error) in [nil, "The engine failed"].enumerated() {
        try await db.save(
            MessageRecord(
                id: "message-\(index)", chatId: chat.id, role: "assistant", text: "Saved response", thinking: "",
                error: error, statsTtft: nil, statsTokens: nil, statsDuration: nil,
                complete: true, position: index, createdAt: .now))
    }
    let before = try await db.messages(chatId: chat.id)
    let reopened = try ChatDatabase(path: path)
    #expect(try await reopened.messages(chatId: chat.id) == before)
}

@Test func interruptionBeforeTheFirstTokenGetsAVisibleNotice() async throws {
    let (db, path) = try tempDB()
    let chat = makeChat()
    try await db.save(chat)
    try await db.save(
        MessageRecord(
            id: "empty", chatId: chat.id, role: "assistant", text: "", thinking: "",
            error: nil, statsTtft: nil, statsTokens: nil, statsDuration: nil,
            complete: false, position: 0, createdAt: .now))
    let reopened = try ChatDatabase(path: path)
    let messages = try await reopened.messages(chatId: chat.id)
    #expect(messages.count == 2)
    #expect(messages.last?.error?.contains("Send a message to continue") == true)
}

@Test func restartExplainsACommandStillRunningBetweenToolRounds() async throws {
    let (db, path) = try tempDB()
    let chat = makeChat()
    try await db.save(chat)
    let result = #"{"job_id":"previous-job","running":true,"output":"build started"}"#
    let events = [
        ToolEventSnapshot(id: "start", server: "GOATed", tool: "pen_run_command", arguments: "{}", result: result)
    ]
    try await db.save(
        MessageRecord(
            id: "command", chatId: chat.id, role: "assistant", text: "Building", thinking: "",
            error: nil, statsTtft: nil, statsTokens: nil, statsDuration: nil, complete: true, position: 0,
            createdAt: .now,
            toolsJson: String(decoding: try JSONEncoder().encode(events), as: UTF8.self)))
    let reopened = try ChatDatabase(path: path)
    let messages = try await reopened.messages(chatId: chat.id)
    #expect(messages.count == 2)
    let restored = try JSONDecoder().decode(
        [ToolEventSnapshot].self, from: Data(try #require(messages[0].toolsJson).utf8))
    #expect(restored[0].result?.hasPrefix(result) == true)
    #expect(restored[0].result?.contains("outcome is unknown") == true)
    #expect(messages[0].error == nil)
    #expect(messages[1].error?.contains("interrupted") == true)
    #expect(try await ChatDatabase(path: path).messages(chatId: chat.id) == messages)
}
