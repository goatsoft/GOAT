import Foundation
import GRDB

// Plain records - the app maps these to its view models. String ids keep the DB inspectable.

public struct ProjectRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "project"
    public var id: String
    public var name: String
    public var emoji: String
    public var instructions: String
    public var createdAt: Date

    public init(id: String, name: String, emoji: String, instructions: String, createdAt: Date) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.instructions = instructions
        self.createdAt = createdAt
    }
}

public struct ChatRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "chat"
    public var id: String
    public var projectId: String?
    public var title: String
    public var pinned: Bool
    public var modelId: String?
    public var effort: String
    public var createdAt: Date
    public var updatedAt: Date
    public var toolsEnabled: Bool
    public var disabledMCPServers: [String]

    public init(
        id: String, projectId: String?, title: String, pinned: Bool, modelId: String?,
        effort: String, createdAt: Date, updatedAt: Date, toolsEnabled: Bool = true,
        disabledMCPServers: [String] = []
    ) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.pinned = pinned
        self.modelId = modelId
        self.effort = effort
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.toolsEnabled = toolsEnabled
        self.disabledMCPServers = Array(Set(disabledMCPServers)).sorted()
    }
}

public struct MessageRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "message"
    public var id: String
    public var chatId: String
    public var role: String
    public var text: String
    public var thinking: String
    public var error: String?
    public var statsTtft: Double?
    public var statsTokens: Int?
    public var statsDuration: Double?
    public var statsGenerationTokensPerSecond: Double?
    public var statsTokensAreExact: Bool?
    public var complete: Bool
    public var position: Int
    public var createdAt: Date
    public var attachmentsJson: String?
    public var toolsJson: String?
    public var rating: Int?

    public init(
        id: String, chatId: String, role: String, text: String, thinking: String,
        error: String?, statsTtft: Double?, statsTokens: Int?, statsDuration: Double?,
        statsGenerationTokensPerSecond: Double? = nil, statsTokensAreExact: Bool? = nil,
        complete: Bool, position: Int, createdAt: Date, attachmentsJson: String? = nil,
        toolsJson: String? = nil, rating: Int? = nil
    ) {
        self.id = id
        self.chatId = chatId
        self.role = role
        self.text = text
        self.thinking = thinking
        self.error = error
        self.statsTtft = statsTtft
        self.statsTokens = statsTokens
        self.statsDuration = statsDuration
        self.statsGenerationTokensPerSecond = statsGenerationTokensPerSecond
        self.statsTokensAreExact = statsTokensAreExact
        self.complete = complete
        self.position = position
        self.createdAt = createdAt
        self.attachmentsJson = attachmentsJson
        self.toolsJson = toolsJson
        self.rating = rating
    }
}

public struct ToolGrantRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "tool_grant"
    public var server: String
    public var tool: String
    public var policy: String  // "always" is the only persisted policy; deny is always per-call
    /// Stable identity of the server command/URL/config which received this grant. Legacy rows are
    /// nil and must never authorize a current server until the user grants it again.
    public var configFingerprint: String?

    public init(
        server: String, tool: String, policy: String, configFingerprint: String? = nil
    ) {
        self.server = server
        self.tool = tool
        self.policy = policy
        self.configFingerprint = configFingerprint
    }
}

/// Native file authority is separate from external MCP grants. An empty chatID means the Pen.
public struct PenFileGrantRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "pen_file_grant"
    public var penID: String
    public var chatID: String
    public var workspaceIdentity: String

    public init(penID: String, chatID: String, workspaceIdentity: String) {
        self.penID = penID
        self.chatID = chatID
        self.workspaceIdentity = workspaceIdentity
    }
}

/// One tool invocation as stored on a message (message.toolsJson = [ToolEventSnapshot]).
public struct ToolEventSnapshot: Codable, Sendable, Equatable, Identifiable {
    public var id: String  // tool_call id from the model
    public var server: String
    public var tool: String
    public var arguments: String  // JSON
    public var result: String?
    public var isError: Bool
    public var denied: Bool

    public init(
        id: String, server: String, tool: String, arguments: String,
        result: String? = nil, isError: Bool = false, denied: Bool = false
    ) {
        self.id = id
        self.server = server
        self.tool = tool
        self.arguments = arguments
        self.result = result
        self.isError = isError
        self.denied = denied
    }
}
