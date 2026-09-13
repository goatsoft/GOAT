import Bleet
import Foundation
import Persistence

/// A display-only projection of the bounded message window. Stored messages and tool results
/// retain their original identities and order; user/Lead messages and final replies are boundaries.
@MainActor
enum TranscriptActivity {
    struct Row: Identifiable {
        let id: UUID
        var messages: [ChatMessage]
        let isContinuation: Bool
        var joinsPreviousTools = false
        var joinsNextTools = false
    }

    static func rows(_ messages: ArraySlice<ChatMessage>) -> [Row] {
        var rows: [Row] = []
        for message in messages {
            if message.role == .tool { continue }  // Results are already attached to their calls.
            // Message identity and view ancestry never depend on arriving tool events.
            // Adjacent assistant rounds share visual alignment, not a disclosure container.
            let continuation = message.role == .assistant && rows.last?.messages.last?.role == .assistant
            rows.append(Row(id: message.id, messages: [message], isContinuation: continuation))
        }
        for index in rows.indices where index > 0 {
            if let current = rows[index].messages.first, let previous = rows[index - 1].messages.last,
                isToolOnly(current), isToolOnly(previous)
            {
                rows[index].joinsPreviousTools = true
                rows[index - 1].joinsNextTools = true
            }
        }
        return rows
    }

    static func isToolOnly(_ message: ChatMessage) -> Bool {
        message.role == .assistant && !message.toolEvents.isEmpty
            && !TranscriptText.hasContent(message.text) && !TranscriptText.hasContent(message.thinking)
            && message.error == nil
    }

    static func isEmpty(_ message: ChatMessage) -> Bool {
        message.role == .assistant && message.toolEvents.isEmpty
            && !TranscriptText.hasContent(message.text) && !TranscriptText.hasContent(message.thinking)
            && message.error == nil
    }

    struct Summary {
        let count: Int
        let failed: Int
        let denied: Int
        let unresolved: Int
        let current: ToolEventSnapshot?

        var title: String {
            "\(current == nil ? "Used tools" : "Using tools") · \(count) \(count == 1 ? "action" : "actions")"
        }
        var issues: String {
            var parts: [String] = []
            if failed > 0 { parts.append("\(failed) failed") }
            if denied > 0 { parts.append("\(denied) denied") }
            if unresolved > 0, current == nil { parts.append("\(unresolved) without a result") }
            return parts.joined(separator: " · ")
        }
    }

    static func summary(_ messages: [ChatMessage], activeAssistantID: UUID?) -> Summary {
        let events = messages.flatMap(\.toolEvents)
        let current = messages.first(where: { $0.id == activeAssistantID })?.toolEvents.first(where: pending)
        return Summary(
            count: events.count,
            failed: events.filter { $0.isError && !$0.denied }.count,
            denied: events.filter(\.denied).count,
            unresolved: events.filter(pending).count,
            current: current
        )
    }

    private static func pending(_ event: ToolEventSnapshot) -> Bool {
        event.result == nil && !event.denied && !event.isError
    }
}

enum TranscriptText {
    static func hasContent(_ text: String) -> Bool { text.contains { !$0.isWhitespace } }

    /// Remove empty boundary lines for display while preserving code indentation and stored text.
    static func removingBoundaryBlankLines(_ text: String) -> String {
        var start = text.startIndex
        var end = text.endIndex
        while start < end {
            let lineEnd = text[start..<end].firstIndex(of: "\n") ?? end
            guard text[start..<lineEnd].allSatisfy(\.isWhitespace) else { break }
            start = lineEnd == end ? end : text.index(after: lineEnd)
        }
        while start < end {
            let newline = text[start..<end].lastIndex(of: "\n")
            let lineStart = newline.map { text.index(after: $0) } ?? start
            guard text[lineStart..<end].allSatisfy(\.isWhitespace) else { break }
            end = newline ?? start
        }
        if start == text.startIndex && end == text.endIndex { return text }
        return String(text[start..<end])
    }
}

enum ToolActivityLabel {
    static func progressTitle(_ event: ToolEventSnapshot) -> String {
        let label = title(event)
        let replacements = [
            "List files": "Listing files", "Read file": "Reading file",
            "Search files": "Searching files", "Create file": "Creating file",
            "Edit file": "Editing file", "Run command": "Running command",
            "Check command": "Checking command", "Stop command": "Stopping command",
        ]
        for (action, progress) in replacements where label == action || label.hasPrefix(action + " · ") {
            return progress + label.dropFirst(action.count)
        }
        return "Using " + label
    }

    static func title(_ event: ToolEventSnapshot) -> String {
        if event.server == "Memory" { return "Memory · " + memoryAction(event) }
        let action: String
        let key: String?
        switch event.tool {
        case "pen_list_files": (action, key) = ("List files", "path")
        case "pen_read_file": (action, key) = ("Read file", "path")
        case "pen_search": (action, key) = ("Search files", "query")
        case "pen_write_file": (action, key) = ("Create file", "path")
        case "pen_edit_file": (action, key) = ("Edit file", "path")
        case "pen_run_command": (action, key) = ("Run command", "command")
        case "pen_command_status": (action, key) = ("Check command", "job_id")
        case "pen_stop_command": (action, key) = ("Stop command", "job_id")
        default: return "\(event.server) · \(event.tool)"
        }
        // Labels never include file contents or tool output. Raw payloads remain in the disclosure.
        guard let key, event.arguments.utf8.count <= 65_536,
            let data = event.arguments.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let value = object[key] as? String
        else { return action }
        var detail = String(value.prefix(160))
        if event.tool == "pen_run_command", let args = object["args"] as? [String] {
            detail += " " + args.prefix(4).map { String($0.prefix(80)) }.joined(separator: " ")
        }
        detail = detail.components(separatedBy: .newlines).joined(separator: " ")
        return detail.isEmpty ? action : "\(action) · \(String(detail.prefix(240)))"
    }

    static func memoryAction(_ event: ToolEventSnapshot) -> String {
        let action: String
        let key: String?
        switch event.tool {
        case "memory_list": (action, key) = ("Browse saved memories", nil)
        case "memory_read": (action, key) = ("Read memory", "id")
        case "memory_write": (action, key) = ("Save memory", "name")
        case "memory_capture_session": (action, key) = ("Save session", nil)
        case "memory_handoff": (action, key) = ("Save handover", nil)
        case "memory_delete": (action, key) = ("Remove memory", "name")
        case "wiki_ingest_source": (action, key) = ("Capture source", "title")
        case "wiki_list_sources": (action, key) = ("Browse source captures", nil)
        case "wiki_read_source": (action, key) = ("Read source", "id")
        case "wiki_query": (action, key) = ("Search knowledge", "query")
        case "wiki_lint": (action, key) = ("Check knowledge pages", nil)
        default: (action, key) = (event.tool.replacingOccurrences(of: "_", with: " ").capitalized, nil)
        }
        guard let key, event.arguments.utf8.count <= 65_536,
            let data = event.arguments.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let raw = object[key] as? String
        else { return action }
        let detail = raw.components(separatedBy: .newlines).joined(separator: " ")
        return detail.isEmpty ? action : action + " · " + String(detail.prefix(160))
    }
}
