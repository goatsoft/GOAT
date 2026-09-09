import Testing

@testable import GOAT

private actor StartupCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

@Test func startupPhasesExposeLocalAndServiceReadinessSeparately() {
    #expect(!StartupPhase.launching.hasLocalState)
    #expect(!StartupPhase.restoringLocalState.hasLocalState)
    #expect(StartupPhase.connectingServices.hasLocalState)
    #expect(!StartupPhase.connectingServices.servicesSettled)
    #expect(StartupPhase.ready.servicesSettled)
    #expect(!StartupPhase.failed("ChatDatabase unavailable").hasLocalState)
}

@Test @MainActor func concurrentStartupCallersJoinOneAppOwnedOperation() async {
    let coordinator = StartupCoordinator()
    let counter = StartupCounter()

    async let first: Void = coordinator.run {
        await counter.increment()
        try? await Task.sleep(for: .milliseconds(30))
    }
    async let second: Void = coordinator.run {
        await counter.increment()
    }
    _ = await (first, second)

    await coordinator.run {
        await counter.increment()
    }

    #expect(await counter.value == 1)
}

@Test @MainActor func failedStartupCanBeExplicitlyRetried() async {
    let coordinator = StartupCoordinator()
    let counter = StartupCounter()

    await coordinator.run { await counter.increment() }
    await coordinator.reset()
    await coordinator.run { await counter.increment() }

    #expect(await counter.value == 2)
}

@Test @MainActor func cancellingAViewWaiterDoesNotCancelAppStartup() async {
    let coordinator = StartupCoordinator()
    let counter = StartupCounter()
    let waiter = Task { @MainActor in
        await coordinator.run {
            await counter.increment()
            try? await Task.sleep(for: .milliseconds(30))
            await counter.increment()
        }
    }

    await Task.yield()
    waiter.cancel()
    await waiter.value

    #expect(await counter.value == 2)
}
