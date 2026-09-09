import Foundation
import Herd
import Hindsight
import MCPClient
import Memory
import Tools

/// Decodes and dispatches memory tools after the model resolves current scope and authority.
@MainActor
struct MemoryToolHandler {
    let model: MemoryModel
    private static let maximumToolResultBytes = 16 * 1_024

    func invoke(
        tool: String,
        argumentsJSON: String,
        context: MemoryContext
    ) async throws -> ToolResult {
        guard model.isEnabled(forProjectID: context.projectID) else {
            throw LocalStoreError.invalidData(
                path: Home.memoryDir.path,
                reason: "memory is disabled in Settings")
        }
        guard argumentsJSON.utf8.count <= 32 * 1_024,
            let data = argumentsJSON.data(using: .utf8)
        else {
            throw MCPError.invalidArguments
        }
        let decoder = JSONDecoder()
        if model.isUsingHindsight(forProjectID: context.projectID) {
            let providerID = model.providerID(forProjectID: context.projectID)
            let client = model.hindsightClient(for: providerID)
            switch tool {
            case "hindsight_sync_status", "hindsight_diagnose":
                try decodeEmptyObject(data, decoder: JSONDecoder())
                return try await client.invoke(providerID: providerID, tool: "get_bank", argumentsJSON: "{}")
            case "hindsight_search_memories":
                return try await client.invoke(
                    providerID: providerID, tool: "recall", argumentsJSON: argumentsJSON)
            case "hindsight_list_memories":
                try decodeEmptyObject(data, decoder: JSONDecoder())
                return try await client.invoke(
                    providerID: providerID, tool: "list_memories", argumentsJSON: #"{"limit":100}"#)
            case "hindsight_read_memory":
                return try await client.invoke(
                    providerID: providerID, tool: "get_memory", argumentsJSON: argumentsJSON)
            case "hindsight_reflect":
                return try await client.invoke(providerID: providerID, tool: "reflect", argumentsJSON: argumentsJSON)
            case "hindsight_capture_initiative":
                let arguments = try decoder.decode(HindsightInitiativeArguments.self, from: data)
                let payload = try JSONEncoder().encode(
                    HindsightRetainArguments(
                        content: "Initiative: \(arguments.title)\n\n\(arguments.summary)",
                        context: "GOAT initiative",
                        tags: ["source:goat", "type:initiative"],
                        metadata: ["title": arguments.title, "source": "GOAT"]))
                return try await client.invoke(
                    providerID: providerID,
                    tool: "retain",
                    argumentsJSON: String(decoding: payload, as: UTF8.self))
            case "hindsight_ingest_document":
                let arguments = try decoder.decode(IngestSourceArguments.self, from: data)
                let receipt = try await model.hindsightStore(forProjectID: context.projectID).remember(
                    MemoryRememberRequest(
                        idempotencyKey: UUID(),
                        title: arguments.title,
                        summary: String(arguments.content.prefix(512)),
                        content: arguments.content,
                        context: model.storageContext(forProjectID: context.projectID)))
                return try result(["status": receipt.status.rawValue])
            default:
                throw MCPError.unknownTool(tool)
            }
        }
        switch tool {
        case "wiki_ingest_source":
            let arguments = try decoder.decode(IngestSourceArguments.self, from: data)
            let store = try await requireLLMWiki(forProjectID: context.projectID)
            let id = try await store.ingest(
                title: arguments.title,
                content: arguments.content,
                context: model.storageContext(forProjectID: context.projectID))
            return try result(["sourceID": id.rawValue])
        case "wiki_list_sources":
            try decodeEmptyObject(data, decoder: decoder)
            let store = try await requireLLMWiki(forProjectID: context.projectID)
            let entries = try await store.sourceEntries(for: model.storageContext(forProjectID: context.projectID)).map
            {
                ToolListEntry(id: $0.id.rawValue, title: $0.title, summary: $0.summary)
            }
            return try result(entries)
        case "wiki_read_source":
            let arguments = try decoder.decode(ReadArguments.self, from: data)
            let store = try await requireLLMWiki(forProjectID: context.projectID)
            let document = try await store.sourceDocument(
                MemoryEntryID(rawValue: arguments.id),
                context: model.storageContext(forProjectID: context.projectID))
            return try result(
                ToolDocument(id: document.entry.id.rawValue, title: document.entry.title, content: document.content))
        case "wiki_query":
            let arguments = try decoder.decode(QueryArguments.self, from: data)
            let entries =
                try await requireLLMWiki(forProjectID: context.projectID).query(
                    arguments.query,
                    context: model.storageContext(forProjectID: context.projectID))
            return try result(
                entries.map {
                    ToolListEntry(id: $0.id.rawValue, title: $0.title, summary: $0.summary)
                })
        case "wiki_lint":
            try decodeEmptyObject(data, decoder: decoder)
            let report = try await requireLLMWiki(forProjectID: context.projectID).lint(
                for: model.storageContext(forProjectID: context.projectID))
            return try result(
                LintResult(
                    pageCount: report.pageCount,
                    sourceCount: report.sourceCount,
                    orphanPages: report.orphanPages,
                    pagesMissingSourceCitations: report.pagesMissingSourceCitations,
                    uncitedSources: report.uncitedSources,
                    invalidWikiLinks: report.invalidWikiLinks,
                    malformedLogRecords: report.malformedLogRecords,
                    missingAuthorities: report.missingAuthorities,
                    schemaIsValid: report.schemaIsValid,
                    indexIsFresh: report.indexIsFresh,
                    isHealthy: report.isHealthy))
        case "memory_list":
            try decodeEmptyObject(data, decoder: decoder)
            let store = try await model.activeStore(forProjectID: context.projectID)
            let storageContext = model.storageContext(forProjectID: context.projectID)
            let entries = try await store.browserEntries(for: storageContext).map {
                ToolListEntry(id: $0.id.rawValue, title: $0.title, summary: $0.summary)
            }
            return try result(entries)
        case "memory_read":
            let arguments = try decoder.decode(ReadArguments.self, from: data)
            let document = try await model.activeStore(forProjectID: context.projectID).browserDocument(
                MemoryEntryID(rawValue: arguments.id), context: model.storageContext(forProjectID: context.projectID))
            return try result(
                ToolDocument(
                    id: document.entry.id.rawValue,
                    title: document.entry.title,
                    content: document.content))
        case "memory_write":
            let arguments = try decoder.decode(WriteArguments.self, from: data)
            let store = try await model.activeStore(forProjectID: context.projectID)
            let stored = try await store.write(
                MemoryNote(name: arguments.name, description: arguments.description, body: arguments.body),
                scope: .global,
                condition: .upsert)
            let entry = try await store.browserEntries(for: model.storageContext(forProjectID: context.projectID))
                .first(where: { $0.title == stored.note.name })
            guard let entry else { throw MCPError.failed("memory note was stored but cannot be safely addressed") }
            return try result(
                ToolListEntry(
                    id: entry.id.rawValue,
                    title: stored.note.name,
                    summary: stored.note.description))
        case "memory_delete":
            let arguments = try decoder.decode(DeleteArguments.self, from: data)
            let deleted = try await model.activeStore(forProjectID: context.projectID).delete(
                arguments.name,
                scope: .global,
                ifRevision: nil)
            return try result(["deleted": deleted])
        case "memory_capture_session":
            let arguments = try decoder.decode(SessionCaptureArguments.self, from: data)
            let content = arguments.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { throw MCPError.invalidArguments }
            let receipt = try await model.activeStore(forProjectID: context.projectID).remember(
                MemoryRememberRequest(
                    idempotencyKey: UUID(),
                    title: "Session capture",
                    summary: String(arguments.summary.prefix(512)),
                    content: content,
                    context: model.storageContext(forProjectID: context.projectID)))
            return try result(["status": receipt.status.rawValue])
        default:
            throw MCPError.unknownTool(tool)
        }
    }

    private struct ReadArguments: Decodable {
        let id: String
    }

    private struct IngestSourceArguments: Decodable {
        let title: String
        let content: String
    }

    private struct HindsightInitiativeArguments: Decodable {
        let title: String
        let summary: String
    }

    private struct HindsightRetainArguments: Encodable {
        let content: String
        let context: String
        let tags: [String]
        let metadata: [String: String]
    }

    private struct QueryArguments: Decodable {
        let query: String
    }

    private struct WriteArguments: Decodable {
        let name: String
        let description: String
        let body: String
    }

    private struct DeleteArguments: Decodable {
        let name: String
    }

    private struct SessionCaptureArguments: Decodable {
        let summary: String
        let content: String
    }

    private struct ToolListEntry: Encodable {
        let id: String
        let title: String
        let summary: String
    }

    private struct ToolDocument: Encodable {
        let id: String
        let title: String
        let content: String
    }

    private struct LintResult: Encodable {
        let pageCount: Int
        let sourceCount: Int
        let orphanPages: [String]
        let pagesMissingSourceCitations: [String]
        let uncitedSources: [String]
        let invalidWikiLinks: [String]
        let malformedLogRecords: [Int]
        let missingAuthorities: [String]
        let schemaIsValid: Bool
        let indexIsFresh: Bool
        let isHealthy: Bool
    }

    private func decodeEmptyObject(_ data: Data, decoder: JSONDecoder) throws {
        let object = try decoder.decode([String: String].self, from: data)
        guard object.isEmpty else { throw MCPError.invalidArguments }
    }

    private func requireLLMWiki(forProjectID projectID: UUID?) async throws -> LLMWikiMemoryStore {
        guard model.usesLLMWiki(forProjectID: projectID) else {
            throw LocalStoreError.invalidData(
                path: Home.memoryDir.path,
                reason:
                    "LLM Wiki tools are unavailable while \(model.providerName(forProjectID: projectID)) is selected")
        }
        return try await model.llmWikiStore(forProjectID: projectID)
    }

    private func result<T: Encodable>(_ value: T) throws -> ToolResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumToolResultBytes,
            let content = String(data: data, encoding: .utf8)
        else {
            throw LocalStoreError.invalidData(
                path: Home.memoryDir.path,
                reason: "memory tool result exceeds \(Self.maximumToolResultBytes) bytes")
        }
        return ToolResult(content: content, isError: false)
    }

}
