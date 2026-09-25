import Bleet
import Foundation
import Inference
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

// MARK: - Presentation and Caching

/// Pre-computed presentation data for a tool event snapshot.
struct ToolEventPresentation: Sendable, Equatable {
    let title: String
    let progressTitle: String
    let action: String
    let hasDetails: Bool
    let diff: ToolFileDiff?
}

/// Cache precomputed presentations across renders so views do not repeatedly parse JSON in body.
final class ToolEventPresentationCache: @unchecked Sendable {
    static let shared = ToolEventPresentationCache()

    private final class Box: @unchecked Sendable {
        let value: ToolEventPresentation
        init(_ value: ToolEventPresentation) { self.value = value }
    }

    private let cache = NSCache<NSString, Box>()

    init() {
        cache.countLimit = 500
    }

    private func makeKey(for event: ToolEventSnapshot, rootName: String?) -> NSString {
        "\(event.id):\(event.tool):\(event.arguments.hashValue):\(event.result != nil):\(event.isError):\(event.denied):\(rootName ?? "")"
            as NSString
    }

    func presentation(for event: ToolEventSnapshot, rootName: String? = nil) -> ToolEventPresentation {
        let key = makeKey(for: event, rootName: rootName)
        if let existing = cache.object(forKey: key) {
            return existing.value
        }
        let computed = compute(for: event, rootName: rootName)
        cache.setObject(Box(computed), forKey: key)
        return computed
    }

    private func compute(for event: ToolEventSnapshot, rootName: String?) -> ToolEventPresentation {
        let title = computeTitle(event, rootName: rootName)
        let progressTitle = computeProgressTitle(for: title)
        let action = event.server == "Memory" ? computeMemoryAction(event) : title
        let hasDetails = ToolCallPayload.containsValue(event.arguments) || ToolCallPayload.containsValue(event.result)
        let diff = ToolDiffParser.parse(tool: event.tool, arguments: event.arguments)
        return ToolEventPresentation(
            title: title,
            progressTitle: progressTitle,
            action: action,
            hasDetails: hasDetails,
            diff: diff
        )
    }

    private func computeTitle(_ event: ToolEventSnapshot, rootName: String?) -> String {
        if event.server == "Memory" { return "Memory · " + computeMemoryAction(event) }
        let action: String
        let key: String?
        switch event.tool {
        case "pen_list_files": (action, key) = ("List files", "path")
        case "pen_glob": (action, key) = ("Find files", "pattern")
        case "pen_read_file": (action, key) = ("Read file", "path")
        case "pen_search": (action, key) = ("Search files", "query")
        case "pen_write_file": (action, key) = ("Create file", "path")
        case "pen_edit_file": (action, key) = ("Edit file", "path")
        case "pen_run_command": (action, key) = ("Run command", "command")
        case "pen_command_status": (action, key) = ("Check command", "job_id")
        case "pen_stop_command": (action, key) = ("Stop command", "job_id")
        default: return "\(event.server) · \(event.tool)"
        }
        guard let key, event.arguments.utf8.count <= 65_536,
            let json = JSONValue.parse(event.arguments),
            case .object(let dict) = json
        else { return action }

        var rawDetail = dict[key]?.stringValue ?? ""
        if rawDetail.isEmpty && event.tool == "pen_glob", let fallback = dict["path"]?.stringValue {
            rawDetail = fallback
        }
        var detail = String(rawDetail.prefix(160))
        if event.tool == "pen_run_command", let args = dict["args"], case .array(let list) = args {
            let strArgs = list.compactMap(\.stringValue)
            if !strArgs.isEmpty {
                detail += " " + strArgs.prefix(4).map { String($0.prefix(80)) }.joined(separator: " ")
            }
        }
        detail = detail.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)

        if detail == "." || (detail.isEmpty && event.tool == "pen_list_files") {
            let pen = rootName?.trimmingCharacters(in: .whitespacesAndNewlines)
            detail = (pen?.isEmpty == false) ? pen! : "workspace"
        }

        return detail.isEmpty ? action : "\(action) · \(String(detail.prefix(240)))"
    }

    private func computeProgressTitle(for label: String) -> String {
        let replacements = [
            "List files": "Listing files", "Find files": "Finding files",
            "Read file": "Reading file", "Search files": "Searching files",
            "Create file": "Creating file", "Edit file": "Editing file",
            "Run command": "Running command", "Check command": "Checking command",
            "Stop command": "Stopping command", "Subagent": "Running subagent",
        ]
        for (action, progress) in replacements where label == action || label.hasPrefix(action + " · ") {
            return progress + label.dropFirst(action.count)
        }
        return "Using " + label
    }

    private func computeMemoryAction(_ event: ToolEventSnapshot) -> String {
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
            let json = JSONValue.parse(event.arguments),
            case .object(let dict) = json,
            let raw = dict[key]?.stringValue
        else { return action }
        let detail = raw.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return detail.isEmpty ? action : action + " · " + String(detail.prefix(160))
    }
}

enum ToolCallPayload {
    static func containsValue(_ text: String?) -> Bool {
        guard let text else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "null" || trimmed == "{}" || trimmed == "[]" {
            return false
        }
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) {
            if let parsed = JSONValue.parse(trimmed) {
                switch parsed {
                case .null: return false
                case .object(let d): return !d.isEmpty
                case .array(let a): return !a.isEmpty
                case .string(let s): return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .bool, .integer, .number: return true
                }
            }
        }
        return true
    }

    static func trimmed(_ text: String) -> String {
        var start = text.startIndex
        while start < text.endIndex {
            let newline = text[start...].firstIndex(of: "\n")
            let lineStart = newline.map { text.index(after: $0) } ?? text.endIndex
            guard text[start..<lineStart].allSatisfy(\.isWhitespace) else { break }
            start = lineStart
        }
        var end = text.endIndex
        while end > start {
            let newline = text[..<end].lastIndex(of: "\n")
            let lineStart = newline.map { text.index(after: $0) } ?? start
            guard text[lineStart..<end].allSatisfy(\.isWhitespace) else { break }
            end = newline ?? start
        }
        if start == text.startIndex && end == text.endIndex { return text }
        return String(text[start..<end])
    }
}

enum ToolActivityLabel {
    static func presentation(for event: ToolEventSnapshot, rootName: String? = nil) -> ToolEventPresentation {
        ToolEventPresentationCache.shared.presentation(for: event, rootName: rootName)
    }

    static func progressTitle(_ event: ToolEventSnapshot, rootName: String? = nil) -> String {
        presentation(for: event, rootName: rootName).progressTitle
    }

    static func title(_ event: ToolEventSnapshot, rootName: String? = nil) -> String {
        presentation(for: event, rootName: rootName).title
    }

    static func memoryAction(_ event: ToolEventSnapshot) -> String {
        presentation(for: event).action
    }
}
