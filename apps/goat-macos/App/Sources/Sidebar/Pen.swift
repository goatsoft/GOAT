import Foundation
import Herd
import Observation
import Pens

/// A Pen: a named enclosure grouping chats, with an OKLCH colour, an emoji, instructions,
/// references, and an optional user-owned workspace. Its GOAT-owned sidecar lives under
/// `~/.goat/projects/` (ADR-0019); the workspace is never silently moved or deleted.
/// This is the observable in-memory view. (The DB still calls the chat link `projectId`.)
@MainActor
@Observable
final class Pen: Identifiable {
    let id: UUID
    var name: String
    var emoji: String
    var instructions: String
    var color: OKLCH
    var files: [PenFileRef]
    var workspace: PenWorkspace?
    var isExpanded = true
    let createdAt: Date

    init(
        id: UUID = UUID(), name: String, emoji: String, instructions: String,
        color: OKLCH = .fallback, files: [PenFileRef] = [], workspace: PenWorkspace? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.instructions = instructions
        self.color = color
        self.files = files
        self.workspace = workspace
        self.createdAt = createdAt
    }

    /// The Pen's spec for persistence (prose is written separately as README.md).
    var spec: PenSpec {
        PenSpec(
            id: id.uuidString, name: name, emoji: emoji, color: color,
            createdAt: createdAt, files: files, workspace: workspace)
    }
}
