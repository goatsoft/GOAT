import Foundation
import Herd
import Memory

extension MemoryModel {
    func remember(_ content: String, projectID: UUID?) async throws -> MemoryRememberReceipt {
        guard isEnabled(forProjectID: projectID) else {
            throw LocalStoreError.invalidData(
                path: Home.memoryDir.path,
                reason: "memory is disabled in Settings")
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalStoreError.invalidData(path: Home.memoryDir.path, reason: "memory cannot be empty")
        }
        let summary = String(trimmed.prefix(512))
        let request = MemoryRememberRequest(
            idempotencyKey: UUID(),
            title: "Remembered response",
            summary: summary,
            content: trimmed,
            context: storageContext(forProjectID: projectID))
        if isUsingHindsight(forProjectID: projectID) {
            return try await hindsightStore(forProjectID: projectID).remember(request)
        }
        return try await activeStore(forProjectID: projectID).remember(request)
    }

    /// Ratings use one stable note per assistant message. Updating or clearing a rating replaces
    /// or removes that note, so an old thumbs-up cannot survive a later thumbs-down or clear.
    func recordFeedback(
        messageID: UUID,
        rating: Int?,
        userPrompt: String,
        assistantResponse: String,
        projectID: UUID?
    ) async throws {
        guard rating == nil || rating == -1 || rating == 1 else {
            throw LocalStoreError.invalidData(
                path: Home.memoryDir.path,
                reason: "feedback rating must be -1, 1, or nil")
        }
        guard isEnabled(forProjectID: projectID) else { return }
        if isUsingHindsight(forProjectID: projectID) {
            // The managed contract is append-only. A clear cannot retract an already ingested
            // document, so it intentionally performs no new write; an explicit rating is durable.
            guard let rating else { return }
            let sentiment = rating > 0 ? "positive" : "negative"
            let prompt = Self.boundedFeedbackText(userPrompt, maximumBytes: 4 * 1_024)
            let response = Self.boundedFeedbackText(assistantResponse, maximumBytes: 16 * 1_024)
            _ = try await hindsightStore(forProjectID: projectID).remember(
                MemoryRememberRequest(
                    idempotencyKey: messageID,
                    title: "\(sentiment.capitalized) GOAT feedback",
                    summary: "Feedback for one assistant response",
                    content:
                        "User feedback: \(sentiment)\n\nUser prompt:\n\(prompt)\n\nAssistant response:\n\(response)",
                    context: storageContext(forProjectID: projectID)))
            return
        }
        let store = try await activeStore(forProjectID: projectID)
        let name = "feedback-\(messageID.uuidString.lowercased())"
        if let rating {
            let sentiment = rating > 0 ? "positive" : "negative"
            let prompt = Self.boundedFeedbackText(userPrompt, maximumBytes: 4 * 1_024)
            let response = Self.boundedFeedbackText(assistantResponse, maximumBytes: 16 * 1_024)
            let content = """
                User feedback: \(sentiment)

                User prompt:
                \(prompt.isEmpty ? "(No preceding user prompt was available.)" : prompt)

                Assistant response:
                \(response)
                """
            _ = try await store.write(
                MemoryNote(
                    name: name,
                    description: "\(sentiment.capitalized) feedback for one assistant response",
                    body: content),
                scope: .global,
                condition: .upsert)
        } else {
            _ = try await store.delete(name, scope: .global, ifRevision: nil)
        }
    }

    private nonisolated static func boundedFeedbackText(_ value: String, maximumBytes: Int) -> String {
        var result = ""
        var bytes = 0
        for character in value {
            let characterBytes = String(character).utf8.count
            guard bytes + characterBytes <= maximumBytes else { break }
            result.append(character)
            bytes += characterBytes
        }
        return result
    }
}
