import Foundation
import Hindsight
import Inference
import Memory
import Shepherd

extension MemoryModel {
    func promptEntries(forProjectID projectID: UUID?) async throws -> [PromptMemoryEntry] {
        guard isEnabled(forProjectID: projectID) else { return [] }
        let context = storageContext(forProjectID: projectID)
        let snapshot: MemoryPromptSnapshot
        if isUsingHindsight(forProjectID: projectID) {
            let providerID = providerID(forProjectID: projectID)
            do {
                snapshot = try await hindsightStore(forProjectID: projectID).promptSnapshot(for: context)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                // Never publish raw remote text or silently switch to another memory provider.
                // A tool-level failure (busy bank, malformed result, timeout with recovered transport)
                // is not proof the provider is offline. Publish the client's actual session health.
                hindsightStatuses[providerID] = await hindsightClient(for: providerID).status(for: providerID)
                activity.log(.warn, "Hindsight context could not be loaded; this chat continues without memory.")
                throw ShepherdMemoryContextError.optionalProviderUnavailable
            }
        } else {
            snapshot = try await activeStore(forProjectID: projectID).promptSnapshot(for: context)
        }
        return snapshot.entries.map {
            PromptMemoryEntry(identifier: $0.identifier, title: $0.title, summary: $0.summary)
        }
    }

    func hindsightLifecyclePromptSection(forProjectID projectID: UUID?) -> String? {
        guard isUsingHindsight(forProjectID: projectID) else { return nil }
        return """
            <hindsight_lifecycle>
            GOAT automatically submits the completed, durably persisted chat transcript to the active Hindsight bank after each turn.
            This lifecycle write-back is owned by the application. Do not call a tool merely to duplicate the transcript, and do not claim whether the background extraction succeeded.
            Use Hindsight tools only for explicit searches, reflections, curated documents, or initiatives requested by the user.
            </hindsight_lifecycle>
            """
    }

    /// Persisted-turn write-back is deliberately outside the model tool loop. Hindsight receives
    /// one stable document per chat, while local providers receive only explicit handoff snapshots.
    func retainPersistedTurn(_ turn: ShepherdPersistedTurn) async -> ShepherdPersistedTurnReceipt? {
        guard isEnabled(forProjectID: turn.projectID) else {
            return turn.kind == .handoff
                ? ShepherdPersistedTurnReceipt(
                    message: "Handover not saved because memory is off",
                    isError: true)
                : nil
        }
        let context = storageContext(forProjectID: turn.projectID)
        let title = Self.boundedUTF8(
            (turn.title == "New chat" || turn.title == "New Chat") ? "GOAT chat transcript" : turn.title,
            maximumBytes: 512)
        do {
            if isUsingHindsight(forProjectID: turn.projectID) {
                _ = try await hindsightStore(forProjectID: turn.projectID).remember(
                    MemoryRememberRequest(
                        idempotencyKey: turn.chatID,
                        title: title,
                        summary: "Completed GOAT chat transcript",
                        content: Self.persistedTranscript(turn),
                        context: context,
                        kind: .session,
                        sourceIdentifier: "goat-chat:\(turn.chatID.uuidString.lowercased())"))
                activity.log(.memory, "Hindsight transcript → queued")
                return ShepherdPersistedTurnReceipt(
                    message: "Handover queued in Hindsight",
                    isError: false)
            }
            guard turn.kind == .handoff,
                let handover = turn.messages.last(where: { $0.role == .assistant })?.text
            else { return nil }
            _ = try await activeStore(forProjectID: turn.projectID).remember(
                MemoryRememberRequest(
                    idempotencyKey: turn.commandMessageID ?? turn.chatID,
                    title: "Session handover",
                    summary: Self.boundedUTF8(handover, maximumBytes: 512),
                    content: Self.boundedUTF8(handover, maximumBytes: 24 * 1_024),
                    context: context,
                    kind: .session,
                    sourceIdentifier: "goat-handoff:\((turn.commandMessageID ?? turn.chatID).uuidString.lowercased())"))
            activity.log(.memory, "Session handover → stored")
            return ShepherdPersistedTurnReceipt(
                message: "Handover saved to \(providerName(forProjectID: turn.projectID))",
                isError: false)
        } catch {
            let providerID = providerID(forProjectID: turn.projectID)
            if provider(forProjectID: turn.projectID)?.kind == .hindsight {
                hindsightStatuses[providerID] = await hindsightClient(for: providerID).status(for: providerID)
            }
            activity.log(.warn, "memory lifecycle: \(error.localizedDescription)")
            return turn.kind == .handoff
                ? ShepherdPersistedTurnReceipt(
                    message:
                        "Handover memory write failed: \(Self.boundedUTF8(error.localizedDescription, maximumBytes: 240))",
                    isError: true)
                : nil
        }
    }

    nonisolated static func persistedTranscript(
        _ turn: ShepherdPersistedTurn,
        maximumBytes: Int = 24 * 1_024
    ) -> String {
        guard maximumBytes > 0 else { return "" }
        let title = boundedUTF8(turn.title, maximumBytes: min(512, maximumBytes))
        let header = "# GOAT chat transcript\n\nChat: \(title)\nChat ID: \(turn.chatID.uuidString.lowercased())\n"
        let sections = turn.messages.map { message in
            let label = message.role == .user ? "User" : "Assistant"
            return "## \(label)\n\n\(boundedUTF8(message.text, maximumBytes: 8 * 1_024))\n"
        }
        let omission = "\n[Earlier completed exchanges omitted to fit the retention limit.]\n"
        var selected: [String] = []
        var bytes = header.utf8.count + omission.utf8.count
        var omitted = false
        for section in sections.reversed() {
            if bytes + section.utf8.count <= maximumBytes {
                selected.insert(section, at: 0)
                bytes += section.utf8.count
            } else {
                omitted = true
            }
        }
        let rendered = header + (omitted ? omission : "\n") + selected.joined(separator: "\n")
        return boundedUTF8(rendered, maximumBytes: maximumBytes)
    }

    nonisolated private static func boundedUTF8(_ value: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0, value.utf8.count > maximumBytes else {
            return maximumBytes > 0 ? value : ""
        }
        var result = ""
        result.reserveCapacity(maximumBytes)
        var used = 0
        for character in value {
            let text = String(character)
            let bytes = text.utf8.count
            guard used + bytes <= maximumBytes else { break }
            result.append(character)
            used += bytes
        }
        return result
    }

}
