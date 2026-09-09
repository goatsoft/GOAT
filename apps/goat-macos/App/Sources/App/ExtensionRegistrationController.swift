import Foundation
import GOATed

/// Serializes activation and removal, including providers that finish after being disabled.
@MainActor
final class ExtensionRegistrationController {
    private let activate: () async throws -> Registration
    private let deactivate: (Registration) async -> Void
    private let reportFailure: (any Error) -> Void
    private var registration: Registration?
    private var pending: (id: UUID, task: Task<Void, Never>)?
    private var desiredEnabled = false
    private var revision: UInt64 = 0

    init(
        activate: @escaping () async throws -> Registration,
        deactivate: @escaping (Registration) async -> Void,
        reportFailure: @escaping (any Error) -> Void
    ) {
        self.activate = activate
        self.deactivate = deactivate
        self.reportFailure = reportFailure
    }

    func setEnabled(_ enabled: Bool) async {
        if enabled == desiredEnabled {
            if let pending {
                await pending.task.value
                return
            }
            if enabled == (registration != nil) { return }
        }
        desiredEnabled = enabled
        revision &+= 1
        let intent = revision
        let id = UUID()
        let previous = pending?.task
        let task = Task {
            // Removal must finish before a replacement uses the same extension identifier.
            await previous?.value
            guard revision == intent else { return }
            if enabled {
                // A queued disable may have been superseded before it removed the current token.
                guard registration == nil else { return }
                do {
                    let token = try await activate()
                    if revision == intent {
                        registration = token
                    } else {
                        await deactivate(token)
                    }
                } catch {
                    if revision == intent { reportFailure(error) }
                }
            } else if let token = registration {
                registration = nil
                await deactivate(token)
            }
        }
        pending = (id, task)
        await task.value
        if pending?.id == id { pending = nil }
    }
}
