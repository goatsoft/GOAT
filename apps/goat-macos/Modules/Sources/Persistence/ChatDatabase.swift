import Foundation
import GRDB
import Herd

/// SQLite operations stay inside Persistence; the pool schedules reads and writes off the UI actor.
public final class ChatDatabase: Sendable {
    private let pool: DatabasePool

    /// Default location: ~/Library/Application Support/GOAT/goat.sqlite
    public convenience init() throws {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GOAT", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try self.init(path: dir.appendingPathComponent("goat.sqlite").path)
    }

    public init(path: String) throws {
        pool = try DatabasePool(path: path)
        try Self.migrator.migrate(pool)
        try pool.write { db in try Self.recoverInterruptedResponses(db) }
    }

    private static func recoverInterruptedResponses(_ db: Database) throws {
        // A tool response is sealed before its tools run. Inspect each chat's last assistant
        // as well as incomplete streams, including when a queued Lead is the final user row.
        let candidates = try MessageRecord.fetchAll(
            db,
            sql: """
                SELECT * FROM message
                WHERE complete = 0 OR (
                    role = 'assistant' AND toolsJson IS NOT NULL AND position = (
                        SELECT MAX(latest.position) FROM message AS latest
                        WHERE latest.chatId = message.chatId AND latest.role = 'assistant'
                    )
                )
                """)
        var interruptedChats = Set<String>()
        for var message in candidates {
            var interrupted = !message.complete && message.role == "assistant"
            if let raw = message.toolsJson?.data(using: .utf8),
                var events = try? JSONDecoder().decode([ToolEventSnapshot].self, from: raw)
            {
                // Starting a command is a completed tool call, but its process may still be
                // running. A crash between tool rounds must not leave that snapshot silent.
                var pendingJobs: [String: Int] = [:]
                for index in events.indices {
                    let event = events[index]
                    guard event.server == "GOATed",
                        ["pen_run_command", "pen_command_status", "pen_stop_command"].contains(event.tool),
                        let text = event.result,
                        let result = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                        let id = result["job_id"] as? String, let running = result["running"] as? Bool
                    else { continue }
                    pendingJobs[id] = running ? index : nil
                }
                for index in pendingJobs.values {
                    events[index].result =
                        (events[index].result ?? "")
                        + "\n[GOAT restarted before this command's final status was saved. Its outcome is unknown. This old job ID cannot resume; inspect files before running a replacement command.]"
                    events[index].isError = true
                }
                let pendingTools = events.indices.filter { events[$0].result == nil }
                for index in pendingTools {
                    events[index].result =
                        "GOAT was interrupted before this tool's result was saved. Its outcome is unknown. Inspect the affected files or state before retrying; the action may already have completed."
                    events[index].isError = true
                }
                if !pendingJobs.isEmpty || !pendingTools.isEmpty {
                    message.toolsJson = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
                    interrupted = true
                }
            }
            message.complete = true
            try message.update(db)
            if interrupted { interruptedChats.insert(message.chatId) }
        }
        // A separate error notice leaves original text and successful tool results in model
        // history. Putting an error on the original response would drop those results on resume.
        for chatID in interruptedChats {
            let position =
                (try Int.fetchOne(db, sql: "SELECT MAX(position) FROM message WHERE chatId = ?", arguments: [chatID])
                    ?? -1) + 1
            let notice = MessageRecord(
                id: UUID().uuidString, chatId: chatID, role: "assistant", text: "", thinking: "",
                error:
                    "This response was interrupted when GOAT closed or restarted. Saved text and completed tool results were kept. Check any tool marked as having an unknown outcome before retrying. Send a message to continue.",
                statsTtft: nil, statsTokens: nil, statsDuration: nil,
                complete: true, position: position, createdAt: .now)
            try notice.insert(db)
        }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "project") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("emoji", .text).notNull().defaults(to: "📁")
                t.column("instructions", .text).notNull().defaults(to: "")
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "chat") { t in
                t.primaryKey("id", .text)
                t.belongsTo("project", onDelete: .setNull)
                t.column("title", .text).notNull()
                t.column("pinned", .boolean).notNull().defaults(to: false)
                t.column("modelId", .text)
                t.column("effort", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "message") { t in
                t.primaryKey("id", .text)
                t.belongsTo("chat", onDelete: .cascade).notNull()
                t.column("role", .text).notNull()
                t.column("text", .text).notNull().defaults(to: "")
                t.column("thinking", .text).notNull().defaults(to: "")
                t.column("error", .text)
                t.column("statsTtft", .double)
                t.column("statsTokens", .integer)
                t.column("statsDuration", .double)
                t.column("complete", .boolean).notNull().defaults(to: false)
                t.column("position", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(indexOn: "message", columns: ["chatId", "position"])
            try db.create(indexOn: "chat", columns: ["updatedAt"])
        }
        migrator.registerMigration("v2-attachments") { db in
            try db.alter(table: "message") { t in
                t.add(column: "attachmentsJson", .text)
            }
        }
        migrator.registerMigration("v3-tools") { db in
            try db.create(table: "tool_grant") { t in
                t.column("server", .text).notNull()
                t.column("tool", .text).notNull()
                t.column("policy", .text).notNull()
                t.primaryKey(["server", "tool"])
            }
            try db.alter(table: "message") { t in
                t.add(column: "toolsJson", .text)
            }
        }
        migrator.registerMigration("v4-chat-tools-switch") { db in
            try db.alter(table: "chat") { t in
                t.add(column: "toolsEnabled", .boolean).notNull().defaults(to: true)
            }
        }
        // Pens became folders you own (ADR-0019), not DB rows - so a chat's `projectId` is a
        // soft pointer to a pen id, not a foreign key into the (now legacy) `project` table.
        // Recreate `chat` without the constraint; deferred FK checks let us swap the table
        // while `message` still references it.
        migrator.registerMigration("v5-pen-link-no-fk", foreignKeyChecks: .deferred) { db in
            try db.create(table: "chat_new") { t in
                t.primaryKey("id", .text)
                t.column("projectId", .text)
                t.column("title", .text).notNull()
                t.column("pinned", .boolean).notNull().defaults(to: false)
                t.column("modelId", .text)
                t.column("effort", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("toolsEnabled", .boolean).notNull().defaults(to: true)
            }
            try db.execute(
                sql: """
                    INSERT INTO chat_new
                        (id, projectId, title, pinned, modelId, effort, createdAt, updatedAt, toolsEnabled)
                    SELECT id, projectId, title, pinned, modelId, effort, createdAt, updatedAt, toolsEnabled
                    FROM chat
                    """)
            try db.drop(table: "chat")
            try db.rename(table: "chat_new", to: "chat")
            try db.create(indexOn: "chat", columns: ["updatedAt"])
        }
        migrator.registerMigration("v6-tool-grant-config-fingerprint") { db in
            // Existing grants intentionally migrate to NULL. Permission code must require an
            // exact, non-nil match before honoring Always Allow for the current server config.
            try db.alter(table: "tool_grant") { table in
                table.add(column: "configFingerprint", .text)
            }
        }
        migrator.registerMigration("v7-message-feedback") { db in
            try db.alter(table: "message") { table in
                // A user rating is independent of streamed content. Updates use a narrow SQL
                // statement below so a late checkpoint cannot erase a just-clicked rating.
                table.add(column: "rating", .integer)
            }
        }
        migrator.registerMigration("v8-chat-mcp-server-selection") { db in
            try db.alter(table: "chat") { table in
                table.add(column: "disabledMCPServers", .text).notNull().defaults(to: "[]")
            }
        }
        migrator.registerMigration("v9-generation-throughput") { db in
            try db.alter(table: "message") { table in
                table.add(column: "statsGenerationTokensPerSecond", .double)
                table.add(column: "statsTokensAreExact", .boolean)
            }
        }
        migrator.registerMigration("v10-pen-file-grants") { db in
            try db.create(table: "pen_file_grant") { table in
                table.column("penID", .text).notNull()
                table.column("chatID", .text).notNull()
                table.column("workspaceIdentity", .text).notNull()
                table.primaryKey(["penID", "chatID", "workspaceIdentity"])
            }
        }
        migrator.registerMigration("v11-message-generation-provenance") { db in
            try db.alter(table: "message") { table in
                table.add(column: "generationProvenanceJson", .text)
                table.add(column: "statsFinishReason", .text)
            }
        }
        return migrator
    }

    // MARK: Reads

    public func projects() async throws -> [ProjectRecord] {
        try await pool.read { db in
            try ProjectRecord.order(Column("createdAt")).fetchAll(db)
        }
    }

    public func chats() async throws -> [ChatRecord] {
        try await pool.read { db in
            try ChatRecord.order(Column("updatedAt").desc).fetchAll(db)
        }
    }

    public func messages(chatId: String) async throws -> [MessageRecord] {
        try await pool.read { db in
            try MessageRecord.filter(Column("chatId") == chatId).order(Column("position")).fetchAll(db)
        }
    }

    // MARK: Writes

    public func save(_ record: ProjectRecord) async throws {
        try await pool.write { db in try record.save(db) }
    }

    public func save(_ record: ChatRecord) async throws {
        try await pool.write { db in
            if let previous = try ChatRecord.fetchOne(db, key: record.id), previous.projectId != record.projectId {
                _ = try PenFileGrantRecord.filter(Column("chatID") == record.id).deleteAll(db)
            }
            try record.save(db)
        }
    }

    public func save(_ record: MessageRecord) async throws {
        try await pool.write { db in try record.save(db) }
    }

    /// Streaming checkpoint: update partial content without touching completion state.
    public func checkpointMessage(id: String, text: String, thinking: String) async throws {
        try await pool.write { db in
            let statement = try db.cachedStatement(sql: "UPDATE message SET text = ?, thinking = ? WHERE id = ?")
            try statement.execute(arguments: [text, thinking, id])
        }
    }

    /// Persists a user feedback choice without rewriting the streamed message record.
    public func setMessageRating(id: String, rating: Int?) async throws {
        guard rating == nil || rating == -1 || rating == 1 else {
            throw LocalStoreError.invalidData(path: "message", reason: "rating must be -1, 1, or nil")
        }
        try await pool.write { db in
            try db.execute(sql: "UPDATE message SET rating = ? WHERE id = ?", arguments: [rating, id])
        }
    }

    public func deleteProject(id: String) async throws {
        try await pool.write { db in _ = try ProjectRecord.deleteOne(db, key: id) }
    }

    public func deleteChat(id: String) async throws {
        try await pool.write { db in
            _ = try PenFileGrantRecord.filter(Column("chatID") == id).deleteAll(db)
            _ = try ChatRecord.deleteOne(db, key: id)
        }
    }

    public func deleteMessage(id: String) async throws {
        try await pool.write { db in _ = try MessageRecord.deleteOne(db, key: id) }
    }

    /// Pens are file-backed, so deleting one clears every soft chat link in one DB transaction.
    @discardableResult
    public func clearPenLinks(id: String) async throws -> Int {
        try await pool.write { db in
            _ = try PenFileGrantRecord.filter(Column("penID") == id).deleteAll(db)
            // UUIDs written by older/manual clients may differ only in case. Treat those as the
            // same soft link so deleting a canonical Pen cannot leave a lowercase link behind.
            try db.execute(
                sql: "UPDATE chat SET projectId = NULL WHERE projectId = ? COLLATE NOCASE",
                arguments: [id])
            return db.changesCount
        }
    }

    // MARK: Tool grants (security state stays in the DB, never in the config file - ADR-0009)

    public func penFileGrants() async throws -> [PenFileGrantRecord] {
        try await pool.read { db in try PenFileGrantRecord.fetchAll(db) }
    }

    public func setPenFileGrant(_ grant: PenFileGrantRecord) async throws {
        try await pool.write { db in try grant.save(db) }
    }

    /// A composer choice replaces the selected scope atomically, so a downgrade cannot leave
    /// a Pen-wide grant active or resurrect previously granted chat permissions.
    public func replacePenFileGrant(
        penID: String, chatID: String, workspaceIdentity: String, allow: Bool, wholePen: Bool
    ) async throws {
        try await pool.write { db in
            let pen = PenFileGrantRecord.filter(Column("penID") == penID)
            if wholePen {
                _ = try pen.deleteAll(db)
            } else {
                _ = try pen.filter(Column("chatID") == chatID).deleteAll(db)
            }
            if allow {
                try PenFileGrantRecord(penID: penID, chatID: chatID, workspaceIdentity: workspaceIdentity).save(db)
            }
        }
    }

    /// Omitting chatID clears every native file grant in the Pen, including chat grants.
    public func deletePenFileGrants(penID: String, chatID: String? = nil) async throws {
        try await pool.write { db in
            let pen = PenFileGrantRecord.filter(Column("penID") == penID)
            if let chatID {
                _ = try pen.filter(Column("chatID") == chatID).deleteAll(db)
            } else {
                _ = try pen.deleteAll(db)
            }
        }
    }

    public func grants() async throws -> [ToolGrantRecord] {
        try await pool.read { db in try ToolGrantRecord.fetchAll(db) }
    }

    public func setGrant(_ grant: ToolGrantRecord) async throws {
        try await pool.write { db in try grant.save(db) }
    }

    public func deleteGrants(server: String) async throws {
        try await pool.write { db in
            _ = try ToolGrantRecord.filter(Column("server") == server).deleteAll(db)
        }
    }
}
