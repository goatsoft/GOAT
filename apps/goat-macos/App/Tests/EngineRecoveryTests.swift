import Foundation
import Testing

@testable import GOAT

private actor RecoveryClock {
    private var pending: CheckedContinuation<Void, Never>?
    private var delays: [Duration] = []
    private var observer: CheckedContinuation<Duration, Never>?

    func sleep(_ delay: Duration) async throws {
        await withCheckedContinuation { continuation in
            pending = continuation
            if let observer {
                self.observer = nil
                observer.resume(returning: delay)
            } else {
                delays.append(delay)
            }
        }
        try Task.checkCancellation()
    }

    func nextDelay() async -> Duration {
        if !delays.isEmpty { return delays.removeFirst() }
        return await withCheckedContinuation { observer = $0 }
    }

    func advance() {
        let continuation = pending
        pending = nil
        continuation?.resume()
    }
}

@Test @MainActor func offlineEngineRecoveryIsSingleFlightAndBacksOffWithoutEditingSettings() async {
    let clock = RecoveryClock()
    let controller = EngineRecoveryController { try await clock.sleep($0) }
    var offline = true
    var probes = 0
    let finished = AsyncStream<Void>.makeStream()
    for _ in 0..<3 {
        controller.update(
            enabled: true, shouldRetry: { offline }, canProbe: { true },
            probe: {
                probes += 1
                if probes == 3 {
                    offline = false
                    finished.continuation.finish()
                }
            })
    }
    for seconds in [1, 2, 4] {
        #expect(await clock.nextDelay() == .seconds(seconds))
        await clock.advance()
    }
    for await _ in finished.stream {}
    #expect(probes == 3)
    #expect(!offline)
}

@Test @MainActor func engineRecoverySkipsBusyTurnsAndCancelsWhenDisabled() async {
    let clock = RecoveryClock()
    let controller = EngineRecoveryController { try await clock.sleep($0) }
    var probes = 0
    controller.update(
        enabled: true, shouldRetry: { true }, canProbe: { false }, probe: { probes += 1 })
    #expect(await clock.nextDelay() == .seconds(1))
    await clock.advance()
    #expect(await clock.nextDelay() == .seconds(2))
    #expect(probes == 0)
    controller.update(
        enabled: false, shouldRetry: { true }, canProbe: { true }, probe: { probes += 1 })
    await clock.advance()
    await Task.yield()
    #expect(probes == 0)
}

@Test @MainActor func healthyOrAuthenticationRequiredEnginesDoNotScheduleRecovery() async {
    let controller = EngineRecoveryController { _ in
        Issue.record("A non-offline engine must not start polling")
    }
    controller.update(
        enabled: true, shouldRetry: { false }, canProbe: { true },
        probe: { Issue.record("Recovery must not probe healthy or authentication-required engines") })
    await Task.yield()
}
