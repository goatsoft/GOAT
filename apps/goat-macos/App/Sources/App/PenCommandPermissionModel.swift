import Foundation
import Observation
import Pens

/// Owner-managed command whitelist. Stored outside every command's filesystem authority.
@MainActor @Observable
final class PenCommandPermissionModel {
    struct Grant: Codable, Equatable, Identifiable {
        let id: UUID
        let penID: UUID
        let chatID: UUID?
        let workspaceIdentity: String
        let commandIdentity: String
        let name: String
        let network: Bool
        var executablePath: String? = nil
    }

    private(set) var grants: [Grant] = []
    private(set) var revision: UInt64 = 0
    private(set) var error: String?
    private(set) var reviewError: String?
    private let defaults: UserDefaults
    private static let key = "herder.commandGrants.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key) {
            do { grants = try JSONDecoder().decode([Grant].self, from: data) } catch {
                self.error = "Command permissions could not be loaded. Commands will ask for approval."
            }
        }
    }

    func allows(_ command: PenCommandTools.PreparedCommand, penID: UUID, chatID: UUID, workspaceIdentity: String)
        -> Bool
    {
        if command.isDefaultAllowed { return true }
        guard error == nil else { return false }
        return grants.contains {
            $0.penID == penID && ($0.chatID == nil || $0.chatID == chatID) && $0.workspaceIdentity == workspaceIdentity
                && $0.commandIdentity == command.commandIdentity && (!command.network || $0.network)
        }
    }

    func remember(_ command: PenCommandTools.PreparedCommand, penID: UUID, chatID: UUID?, workspaceIdentity: String)
        -> Bool
    {
        var updated = grants.filter {
            !($0.penID == penID && $0.chatID == chatID && $0.workspaceIdentity == workspaceIdentity
                && $0.commandIdentity == command.commandIdentity)
        }
        guard updated.count < 1_000 else {
            error = "Remove old command permissions before adding more."
            return false
        }
        updated.append(
            Grant(
                id: UUID(), penID: penID, chatID: chatID, workspaceIdentity: workspaceIdentity,
                commandIdentity: command.commandIdentity, name: command.displayName, network: command.network,
                executablePath: command.executablePath))
        return save(updated)
    }

    struct Review: Sendable {
        let executable: PenCommandTools.ExecutableReview
        let workspace: URL
        let revision: UInt64
    }

    func review(command: String, workspace: URL) async throws -> Review {
        let revision = self.revision
        let files = try await Task.detached { try PenFileTools(workspace: workspace) }.value
        let runner = PenCommandTools(workspace: workspace, files: files)
        let executable = try await runner.reviewExecutable(command.trimmingCharacters(in: .whitespacesAndNewlines))
        guard revision == self.revision else { throw CancellationError() }
        return Review(executable: executable, workspace: workspace, revision: revision)
    }

    /// Recheck the reviewed executable/folder and revision before publishing an owner change.
    func saveReviewed(_ reviewed: Review, penID: UUID, chatID: UUID?, network: Bool, replacing id: UUID?) async -> Bool
    {
        reviewError = nil
        guard reviewed.revision == revision else { return false }
        if let id, !grants.contains(where: { $0.id == id && $0.penID == penID }) { return false }
        do {
            let current = try await review(command: reviewed.executable.path, workspace: reviewed.workspace)
            guard current.executable == reviewed.executable, reviewed.revision == revision else {
                reviewError = "The executable or Pen folder changed. Check the command again."
                return false
            }
            var updated = grants.filter {
                $0.id != id
                    && !($0.penID == penID && $0.chatID == chatID
                        && $0.workspaceIdentity == current.executable.workspaceIdentity
                        && $0.commandIdentity == current.executable.identity)
            }
            guard updated.count < 1000 else {
                reviewError = "Remove old command permissions before adding more."
                return false
            }
            updated.append(
                Grant(
                    id: id ?? UUID(), penID: penID, chatID: chatID,
                    workspaceIdentity: current.executable.workspaceIdentity,
                    commandIdentity: current.executable.identity,
                    name: current.executable.name, network: network, executablePath: current.executable.path))
            return save(updated)
        } catch {
            reviewError = "The command could not be checked. Check its path and try again."
            return false
        }
    }

    func revoke(_ id: UUID) { _ = save(grants.filter { $0.id != id }) }
    func reset(penID: UUID, chatID: UUID? = nil) {
        _ = save(grants.filter { $0.penID != penID || (chatID != nil && $0.chatID != chatID) })
    }

    private func save(_ updated: [Grant]) -> Bool {
        revision &+= 1
        do {
            let data = try JSONEncoder().encode(updated)
            defaults.set(data, forKey: Self.key)
            guard defaults.data(forKey: Self.key) == data else { throw CocoaError(.fileWriteUnknown) }
            grants = updated
            error = nil
            return true
        } catch {
            grants = []
            self.error = "Command permissions could not be saved. GOAT will ask for approval."
            return false
        }
    }
}
