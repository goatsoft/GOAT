import Bleet
import Foundation

extension AppModel {
    func rateMessage(_ message: ChatMessage, rating: Int) {
        guard rating == -1 || rating == 1 || rating == 0 else { return }
        let persistedRating = rating == 0 ? nil : rating
        guard
            let session = chats.first(where: { session in
                session.messages.contains(where: { $0.id == message.id })
            })
        else {
            activity.log(.warn, "message feedback: the message no longer belongs to an available chat")
            return
        }
        let projectID = session.projectID
        let prompt =
            session.messages
            .prefix { $0.id != message.id }
            .last(where: { $0.role == .user })?
            .text ?? ""
        let response = message.text
        let revision = (messageRatingRevisions[message.id] ?? 0) &+ 1
        messageRatingRevisions[message.id] = revision
        message.rating = persistedRating
        if presentation.isEnabled && animationsEnabled {
            if rating > 0 { goatCheerToken += 1 }
            if rating < 0 { goatWalkToken += 1 }
        }
        Task {
            do {
                guard let databaseWriter else {
                    activity.log(.warn, "message feedback: persistence is unavailable")
                    return
                }
                let persisted = try await databaseWriter.setMessageRating(
                    id: message.id.uuidString,
                    rating: persistedRating,
                    revision: revision)
                guard persisted, messageRatingRevisions[message.id] == revision else { return }
                try await memory.recordFeedback(
                    messageID: message.id,
                    rating: persistedRating,
                    userPrompt: prompt,
                    assistantResponse: response,
                    projectID: projectID)
                guard messageRatingRevisions[message.id] == revision else { return }
                activity.log(.memory, "message feedback → \(persistedRating == nil ? "cleared" : "stored")")
            } catch {
                activity.log(.warn, "message feedback: \(error.localizedDescription)")
            }
        }
    }

    func canRemember(_ message: ChatMessage, projectID: UUID?) -> Bool {
        messageMemorySaves[message.id]?.preventsRepeat != true
            && message.complete
            && !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && memory.isEnabled(forProjectID: projectID)
    }

    func remember(_ message: ChatMessage) {
        guard let session = chats.first(where: { $0.messages.contains(where: { $0.id == message.id }) }),
            canRemember(message, projectID: session.projectID)
        else { return }
        let projectID = session.projectID
        let content = message.text
        messageMemorySaves[message.id] = .saving
        Task {
            do {
                let receipt = try await memory.remember(content, projectID: projectID)
                messageMemorySaves[message.id] = receipt.status == .queued ? .queued : .saved
                activity.log(.memory, "Remember This → \(receipt.status.rawValue)")
            } catch {
                messageMemorySaves[message.id] = .failed(error.localizedDescription)
                activity.log(.warn, "Remember This: \(error.localizedDescription)")
            }
        }
    }

}
