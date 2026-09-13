import Foundation

/// ADR-0087 Tier-2 conversation compaction: the pure content core. It builds the model-facing
/// summary instructions, sanitises the one-shot `/compact` focus, and derives the files-read and
/// files-edited lists GOAT appends itself. The command surface, persistence, prompt assembly and UI
/// live in Shepherd and the app; nothing here calls an engine or touches storage.
public enum ConversationCompaction {

    /// Upper bound on a `/compact` focus instruction so it cannot crowd out the summary request.
    public static let maximumFocusLength = 500

    /// The fixed sections the summary fills, in a stable order so a re-summary reads the same.
    public static let sectionTitles = [
        "Goal",
        "Constraints and user preferences",
        "Done",
        "In progress",
        "Blocked",
        "Key decisions",
        "Next steps",
        "Critical context",
    ]

    /// System-prompt section describing the compaction task, the analogue of the handoff section.
    /// The one-shot focus is deliberately not here: it rides the request so it never persists into a
    /// later plan.
    public static let promptSection = """
        <goat_compaction_command>
        GOAT is compacting this conversation to fit the context window. This is a direct application command, not a skill or tool.
        Rewrite everything so far into a compact briefing for the next request, under these fixed sections, in order:
        Goal; Constraints and user preferences; Done; In progress; Blocked; Key decisions; Next steps; Critical context.
        Give each section a short heading and omit a section only when it genuinely has no content. Preserve exact identifiers, values and decisions; drop narration.
        Do not list the files you read or edited; GOAT appends those lists itself. Do not call skill_load, a tool, or any memory function.
        This briefing is quoted historical state, not a claim of success. The next turn must reread files or rerun tools before acting.
        </goat_compaction_command>
        """

    /// The user-role request that drives the summary. A non-empty focus is appended once, bounded.
    public static func modelRequest(focus: String = "") -> String {
        let base = "Compact the conversation so far now, using the fixed sections."
        let trimmed = sanitizedFocus(focus)
        guard !trimmed.isEmpty else { return base }
        return base
            + "\n\nPay particular attention to the following and preserve it in your briefing, "
            + "even if you would otherwise compress it:\n" + trimmed
    }

    /// A parsed `/compact [focus]` command.
    public struct Command: Equatable, Sendable {
        /// Bounded focus text; empty for a bare `/compact`.
        public let focus: String

        public init(focus: String) { self.focus = focus }
    }

    /// Parse a message body as the `/compact` command. Returns nil for any other message.
    public static func command(from text: String) -> Command? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed == "/compact" || trimmed.hasPrefix("/compact ") else { return nil }
        return Command(focus: sanitizedFocus(String(trimmed.dropFirst("/compact".count))))
    }

    /// Files read and files edited, derived deterministically from the tool calls in `turns`. A file
    /// that was edited is reported only under `edited`. Order is first appearance.
    public static func fileLists(from turns: [ChatTurn]) -> (read: [String], edited: [String]) {
        var read: [String] = []
        var edited: [String] = []
        var readSet: Set<String> = []
        var editedSet: Set<String> = []
        for turn in turns where turn.role == .assistant {
            for call in turn.toolCalls {
                guard let path = path(inArgumentsJSON: call.argumentsJSON) else { continue }
                switch call.name {
                case "pen_write_file", "pen_edit_file":
                    if editedSet.insert(path).inserted { edited.append(path) }
                case "pen_read_file":
                    if readSet.insert(path).inserted { read.append(path) }
                default:
                    continue
                }
            }
        }
        // A file both read and edited is reported only under edited.
        if !editedSet.isEmpty { read.removeAll { editedSet.contains($0) } }
        return (read, edited)
    }

    /// Render the derived file lists as the trailer GOAT appends after the model briefing. Empty when
    /// there is nothing to append.
    public static func fileListsSection(read: [String], edited: [String]) -> String {
        var lines: [String] = []
        if !edited.isEmpty {
            lines.append("Files edited:")
            lines.append(contentsOf: edited.map { "- " + $0 })
        }
        if !read.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("Files read:")
            lines.append(contentsOf: read.map { "- " + $0 })
        }
        return lines.joined(separator: "\n")
    }

    static func sanitizedFocus(_ focus: String) -> String {
        let trimmed = focus.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maximumFocusLength))
    }

    private static func path(inArgumentsJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let path = object["path"] as? String,
            !path.isEmpty
        else { return nil }
        return path
    }
}
