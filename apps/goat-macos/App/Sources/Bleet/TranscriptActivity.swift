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
        let isActivity: Bool
    }

    static func rows(_ messages: ArraySlice<ChatMessage>) -> [Row] {
        var rows: [Row] = []
        for message in messages {
            if message.role == .tool { continue }  // Results are already attached to their calls.
            let activity = message.role == .assistant && !message.toolEvents.isEmpty
            if activity, let last = rows.indices.last, rows[last].isActivity {
                rows[last].messages.append(message)
            } else {
                rows.append(Row(id: message.id, messages: [message], isActivity: activity))
            }
        }
        return rows
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

enum ToolActivityLabel {
    static func title(_ event: ToolEventSnapshot) -> String {
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
}
