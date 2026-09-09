import Foundation
import Herd
import MCPClient
import Memory
import Tools

/// A bounded browser and explicit-ingest facade over one server-managed Hindsight bank. It
/// deliberately does not claim local note edit/delete parity: Hindsight owns memory lifecycle.
public actor HindsightMemoryStore: BrowsableMemoryStore, RememberingMemoryStore {
    public nonisolated let capabilities = MemoryStoreCapabilities([
        .promptSnapshot, .browse, .remember, .backendTools,
    ])

    private struct MemoryList: Decodable {
        let items: [MemoryUnit]
    }

    private struct MemoryUnit: Decodable {
        let id: String
        let text: String
        let context: String?
        let factType: String?
        let updatedAt: String?
        let createdAt: String?

        enum CodingKeys: String, CodingKey {
            case id
            case text
            case context
            case factType = "fact_type"
            case updatedAt = "updated_at"
            case createdAt = "created_at"
        }
    }

    private struct RetainArguments: Encodable {
        let content: String
        let context: String
        let tags: [String]
        let metadata: [String: String]
        let documentID: String

        enum CodingKeys: String, CodingKey {
            case content
            case context
            case tags
            case metadata
            case documentID = "document_id"
        }
    }

    private let providerID: MemoryProviderID
    private let client: HindsightProviderClient

    public init(providerID: MemoryProviderID, client: HindsightProviderClient) {
        self.providerID = providerID
        self.client = client
    }

    public func promptSnapshot(for _: MemoryContext) async throws -> MemoryPromptSnapshot {
        let entries = try await browserEntries(for: MemoryContext())
        return MemoryPromptSnapshot(
            entries: entries.map {
                MemoryPromptEntry(
                    identifier: $0.id.rawValue,
                    title: $0.title,
                    summary: $0.summary,
                    scope: .shared,
                    modifiedAt: nil)
            })
    }

    public func browserEntries(for _: MemoryContext) async throws -> [MemoryBrowserEntry] {
        try await entries(limit: 100)
    }

    public func entries(limit: Int) async throws -> [MemoryBrowserEntry] {
        guard (1...100).contains(limit) else { throw HindsightControlError.invalidConfiguration }
        let result = try await invoke("list_memories", argumentsJSON: "{\"limit\":\(limit)}")
        let response = try Self.decode(MemoryList.self, from: result.content)
        guard response.items.count <= limit else {
            throw LocalStoreError.invalidData(
                path: "Hindsight",
                reason: "memory list exceeds the requested browse limit")
        }
        return try response.items.map { item in
            try Self.entry(from: item)
        }
    }

    public func browserDocument(
        _ id: MemoryEntryID,
        context _: MemoryContext
    ) async throws -> MemoryBrowserDocument {
        let memoryID = try Self.memoryID(from: id)
        let arguments = try JSONEncoder().encode(["memory_id": memoryID])
        guard let argumentsJSON = String(data: arguments, encoding: .utf8) else {
            throw LocalStoreError.invalidData(path: "Hindsight", reason: "memory request is not valid UTF-8")
        }
        let result = try await invoke("get_memory", argumentsJSON: argumentsJSON)
        let memory = try Self.decode(MemoryUnit.self, from: result.content)
        guard memory.id == memoryID else {
            throw LocalStoreError.invalidData(path: "Hindsight", reason: "memory identity changed")
        }
        return MemoryBrowserDocument(
            entry: try Self.entry(from: memory),
            content: memory.text)
    }

    public func remember(_ request: MemoryRememberRequest) async throws -> MemoryRememberReceipt {
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = request.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 512,
            !content.isEmpty, content.utf8.count <= 24 * 1_024
        else {
            throw LocalStoreError.invalidData(
                path: "Hindsight",
                reason: "document title or content exceeds Hindsight ingest limits")
        }
        let data = try JSONEncoder().encode(
            RetainArguments(
                content: content,
                context: request.kind == .session
                    ? "GOAT chat transcript: \(title). Sections labelled User are the human; sections labelled Assistant are the GOAT AI assistant. Preserve who performed each action. User preferences and external facts are world facts; actions actually performed and lessons learned by the Assistant are its experiences. Plans are not completed actions."
                    : "GOAT durable memory: \(title)",
                tags: ["source:goat", "type:\(request.kind.rawValue)"],
                metadata: ["title": title, "source": "GOAT", "kind": request.kind.rawValue],
                documentID: Self.documentID(for: request)))
        guard let argumentsJSON = String(data: data, encoding: .utf8) else {
            throw LocalStoreError.invalidData(path: "Hindsight", reason: "document request is not valid UTF-8")
        }
        _ = try await invoke("retain", argumentsJSON: argumentsJSON)
        return MemoryRememberReceipt(status: .queued)
    }

    public nonisolated static func documentID(for request: MemoryRememberRequest) -> String {
        "goat-\(request.kind.rawValue)-\(request.idempotencyKey.uuidString.lowercased())"
    }

    private func invoke(_ tool: String, argumentsJSON: String) async throws -> ToolResult {
        let result = try await client.invoke(
            providerID: providerID,
            tool: tool,
            argumentsJSON: argumentsJSON)
        guard !result.isError else {
            throw MCPError.failed("Hindsight rejected the managed provider request.")
        }
        return result
    }

    private nonisolated static func entry(from memory: MemoryUnit) throws -> MemoryBrowserEntry {
        let text = memory.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = String(text.prefix(4_000))
        guard memory.id.utf8.count <= 512,
            !memory.id.isEmpty,
            !memory.id.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
            !text.isEmpty,
            text.utf8.count <= 32 * 1_024,
            summary.utf8.count <= 16 * 1_024
        else {
            throw LocalStoreError.invalidData(path: "Hindsight", reason: "memory metadata is invalid")
        }
        return MemoryBrowserEntry(
            id: MemoryEntryID(rawValue: "hindsight:\(memory.id)"),
            title: MemoryBrowserEntry.displayTitle(for: text),
            summary: summary,
            scope: .shared,
            modifiedAt: memoryDate(memory.updatedAt ?? memory.createdAt),
            canEdit: false,
            canDelete: false)
    }

    private nonisolated static func memoryDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: value) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: value)
    }

    private nonisolated static func memoryID(from id: MemoryEntryID) throws -> String {
        guard id.rawValue.hasPrefix("hindsight:") else {
            throw MemoryStoreError.invalidEntryID(id.rawValue)
        }
        let memoryID = String(id.rawValue.dropFirst("hindsight:".count))
        guard !memoryID.isEmpty, memoryID.utf8.count <= 512,
            !memoryID.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
        else {
            throw MemoryStoreError.invalidEntryID(id.rawValue)
        }
        return memoryID
    }

    private nonisolated static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        guard text.utf8.count <= HindsightProviderClient.maximumResponseBytes,
            let data = text.data(using: .utf8)
        else {
            throw LocalStoreError.invalidData(path: "Hindsight", reason: "memory response is invalid")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw LocalStoreError.invalidData(path: "Hindsight", reason: "memory response has an unexpected shape")
        }
    }
}
