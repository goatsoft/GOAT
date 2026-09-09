import Foundation

/// One app-owned recovery loop, independent of transient settings or chat views.
/// Healthy and authentication-required engines do not poll. Retries back off to 30 seconds.
@MainActor
final class EngineRecoveryController {
    private var task: Task<Void, Never>?
    private var generation: UUID?
    private let sleep: @Sendable (Duration) async throws -> Void

    init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    func update(
        enabled: Bool,
        shouldRetry: @escaping @MainActor () -> Bool,
        canProbe: @escaping @MainActor () -> Bool,
        probe: @escaping @MainActor () async -> Void
    ) {
        guard enabled else {
            generation = nil
            task?.cancel()
            task = nil
            return
        }
        // Let a successful in-flight probe finish publishing its model capabilities.
        guard shouldRetry(), task == nil else { return }
        let generation = UUID()
        self.generation = generation
        let sleep = sleep
        task = Task { [weak self] in
            defer { self?.finish(generation) }
            var seconds = 1
            while !Task.isCancelled, shouldRetry() {
                do { try await sleep(.seconds(seconds)) } catch { return }
                guard !Task.isCancelled, shouldRetry() else { return }
                if canProbe() { await probe() }
                seconds = min(30, seconds * 2)
            }
        }
    }

    private func finish(_ completed: UUID) {
        guard generation == completed else { return }
        task = nil
        generation = nil
    }

    deinit { task?.cancel() }
}
