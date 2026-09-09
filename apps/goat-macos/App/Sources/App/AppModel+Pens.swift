import Foundation
import Herd
import Pens

extension AppModel {
    // MARK: Pen CRUD (stored as folders under ~/.goat/projects - ADR-0019)

    @discardableResult
    func savePen(
        existing: Pen?, name: String, emoji: String, instructions: String,
        color: OKLCH, files: [PenFileRef]? = nil, workspace: PenWorkspace? = nil,
        replaceWorkspace: Bool = false
    ) async -> Pen? {
        let id: UUID
        let createdAt: Date
        let storedFiles: [PenFileRef]
        let storedWorkspace: PenWorkspace?
        if let existing {
            // A disappearing Pen view may try to flush after deletion. Never let that stale view
            // recreate the folder which deletePen has just removed.
            guard pens.contains(where: { $0.id == existing.id }),
                !deletingPenIDs.contains(existing.id)
            else { return nil }
            id = existing.id
            createdAt = existing.createdAt
            storedFiles = files ?? existing.files
            storedWorkspace = replaceWorkspace ? workspace : workspace ?? existing.workspace
        } else {
            id = UUID()
            createdAt = .now
            storedFiles = files ?? []
            storedWorkspace = workspace
        }
        let savedEmoji = emoji.isEmpty ? "🐐" : emoji
        let spec = PenSpec(
            id: id.uuidString, name: name, emoji: savedEmoji, color: color,
            createdAt: createdAt, files: storedFiles, workspace: storedWorkspace)
        let revision = nextPenStoreRevision(for: id)
        do {
            let saved = try await fileWorker.savePen(
                spec, instructions: instructions, revision: revision)
            guard saved, penStoreRevisions[id] == revision, !Task.isCancelled else { return nil }
            if let existing {
                existing.name = name
                existing.emoji = savedEmoji
                existing.instructions = instructions
                existing.color = color
                existing.files = storedFiles
                existing.workspace = storedWorkspace
                return existing
            }
            let pen = Pen(
                id: id, name: name, emoji: savedEmoji, instructions: instructions,
                color: color, files: storedFiles, workspace: storedWorkspace, createdAt: createdAt)
            pens.append(pen)
            return pen
        } catch {
            dbWarning = "Pen was not saved: \(error.localizedDescription)"
            return nil
        }
    }

    func deletePen(_ pen: Pen) async {
        guard let databaseWriter, pens.contains(where: { $0.id == pen.id }),
            deletingPenIDs.insert(pen.id).inserted
        else { return }
        defer { deletingPenIDs.remove(pen.id) }
        guard await filePermissions.reset(penID: pen.id) else { return }
        commandPermissions.reset(penID: pen.id)
        await toolRouter.stopCommands(penID: pen.id)
        let linkedChats = chats.filter { $0.projectID == pen.id }
        // Fence every chat, not only the currently linked ones. A move issued just before deletion
        // may already be durable but not yet published on MainActor; its older revision must not
        // restore the link after the global database clear.
        let chatRevisions = Dictionary(
            uniqueKeysWithValues: chats.map { chat in
                (chat.id.uuidString, nextChatStoreRevision(for: chat.id))
            })
        do {
            guard
                try await databaseWriter.clearPenLinks(
                    id: pen.id.uuidString, revisions: chatRevisions)
            else { return }
        } catch {
            dbWarning = "Pen was not deleted: \(error.localizedDescription)"
            return
        }
        // A chat may have been moved to another Pen while the global clear was queued. Preserve
        // that newer destination; only clear the link which this deletion actually targets.
        for chat in linkedChats where chat.projectID == pen.id { chat.projectID = nil }
        let penRevision = nextPenStoreRevision(for: pen.id)
        let penID = pen.id.uuidString
        do {
            let deleted = try await fileWorker.deletePen(id: penID, revision: penRevision)
            guard deleted, penStoreRevisions[pen.id] == penRevision else { return }
            pens.removeAll { $0.id == pen.id }
        } catch {
            dbWarning =
                "Chat links were cleared, but the Pen folder was not deleted: \(error.localizedDescription)"
        }
    }

    func penFolder(id: UUID) async -> URL? {
        do {
            return try await fileWorker.penFolder(id: id.uuidString)
        } catch {
            dbWarning = "Pen folder was not opened: \(error.localizedDescription)"
            return nil
        }
    }

    func setWorkspace(_ workspace: PenWorkspace?, for pen: Pen) async -> Bool {
        let previous = pen.workspace
        if previous != workspace {
            guard await filePermissions.reset(penID: pen.id) else { return false }
            commandPermissions.reset(penID: pen.id)
            await toolRouter.stopCommands(penID: pen.id)
        }
        pen.workspace = workspace
        let saved = await savePen(
            existing: pen, name: pen.name, emoji: pen.emoji,
            instructions: pen.instructions, color: pen.color, files: pen.files,
            workspace: workspace, replaceWorkspace: true)
        guard saved != nil else {
            pen.workspace = previous
            return false
        }
        return true
    }

    private func nextPenStoreRevision(for id: UUID) -> UInt64 {
        let revision = (penStoreRevisions[id] ?? 0) &+ 1
        penStoreRevisions[id] = revision
        return revision
    }

}
