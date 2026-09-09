import Foundation

// Shared tool request and result types for provider implementations (ADR-0006).

public struct ToolSchema: Sendable {
    public var name: String
    public var description: String
    public var inputSchemaJSON: String
    public init(name: String, description: String, inputSchemaJSON: String) {
        self.name = name
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
    }
}

public struct ToolCallRequest: Sendable {
    public var tool: String
    public var argumentsJSON: String
    public init(tool: String, argumentsJSON: String) {
        self.tool = tool
        self.argumentsJSON = argumentsJSON
    }
}

public struct ToolResult: Sendable {
    public var content: String
    public var isError: Bool
    public init(content: String, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }
}

public protocol ToolProvider: Sendable {
    func availableTools() async -> [ToolSchema]
    func invoke(_ call: ToolCallRequest) async throws -> ToolResult
}
