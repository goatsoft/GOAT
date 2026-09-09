import Foundation
import Testing

@testable import Inference

private actor ControlledEngineProbe: EngineProbe {
    private var requested: Set<URL> = []
    private var continuations: [URL: CheckedContinuation<EngineHealth, Never>] = [:]

    func probe(_ config: EngineConfig) async -> EngineHealth {
        requested.insert(config.baseURL)
        return await withCheckedContinuation { continuation in
            continuations[config.baseURL] = continuation
        }
    }

    func waitUntilRequested(_ url: URL) async {
        while !requested.contains(url) { await Task.yield() }
    }

    func complete(_ url: URL, with health: EngineHealth) {
        continuations.removeValue(forKey: url)?.resume(returning: health)
    }
}

private func target(_ profileID: String, port: Int, apiKey: String? = nil) -> EngineLifecycleController.Target {
    EngineLifecycleController.Target(
        profileID: profileID,
        config: EngineConfig(
            baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            apiKey: apiKey
        )
    )
}

@Test func newerEngineProbeSupersedesAnOlderSlowResult() async throws {
    let probe = ControlledEngineProbe()
    let controller = EngineLifecycleController(probe: probe)
    let older = target("older", port: 8000)
    let newer = target("newer", port: 8001)

    let olderTask = Task { await controller.resolve(older) }
    await probe.waitUntilRequested(older.config.baseURL)

    let newerTask = Task { await controller.resolve(newer) }
    await probe.waitUntilRequested(newer.config.baseURL)

    let newerHealth = EngineHealth.ok([ModelRef(id: "new-model")])
    await probe.complete(newer.config.baseURL, with: newerHealth)
    let newerResolution = try #require(await newerTask.value)

    await probe.complete(older.config.baseURL, with: .ok([ModelRef(id: "old-model")]))
    let olderResolution = await olderTask.value

    #expect(olderResolution == nil)
    #expect(newerResolution.target == newer)
    #expect(newerResolution.health == newerHealth)
    #expect(await controller.isCurrent(newerResolution))
}

@Test func invalidationDiscardsAnInFlightProbe() async {
    let probe = ControlledEngineProbe()
    let controller = EngineLifecycleController(probe: probe)
    let selection = target("engine", port: 8000)

    let task = Task { await controller.resolve(selection) }
    await probe.waitUntilRequested(selection.config.baseURL)
    let invalidationRevision = await controller.invalidate()
    await probe.complete(selection.config.baseURL, with: .ok([]))

    #expect(await task.value == nil)
    #expect(await controller.revision == invalidationRevision)
}

@Test func cancelledProbeDoesNotPublishAResolution() async {
    let probe = ControlledEngineProbe()
    let controller = EngineLifecycleController(probe: probe)
    let selection = target("engine", port: 8000)

    let task = Task { await controller.resolve(selection) }
    await probe.waitUntilRequested(selection.config.baseURL)
    task.cancel()
    await probe.complete(selection.config.baseURL, with: .ok([]))

    #expect(await task.value == nil)
}

@Test func completedResolutionBecomesStaleWhenTheNextProbeBegins() async throws {
    let probe = ControlledEngineProbe()
    let controller = EngineLifecycleController(probe: probe)
    let first = target("first", port: 8000)
    let second = target("second", port: 8001)

    let firstTask = Task { await controller.resolve(first) }
    await probe.waitUntilRequested(first.config.baseURL)
    await probe.complete(first.config.baseURL, with: .ok([ModelRef(id: "first-model")]))
    let firstResolution = try #require(await firstTask.value)
    #expect(await controller.isCurrent(firstResolution))

    let secondTask = Task { await controller.resolve(second) }
    await probe.waitUntilRequested(second.config.baseURL)
    #expect(!(await controller.isCurrent(firstResolution)))

    await probe.complete(second.config.baseURL, with: .authRequired)
    let secondResolution = try #require(await secondTask.value)
    #expect(secondResolution.target == second)
    #expect(secondResolution.health == .authRequired)
    #expect(secondResolution.revision > firstResolution.revision)
}

@Test func probeReceivesOnlyTheTargetProfilesCredentials() async throws {
    let probe = ControlledEngineProbe()
    let controller = EngineLifecycleController(probe: probe)
    let selection = target("authenticated", port: 8001, apiKey: "profile-key")

    let task = Task { await controller.resolve(selection) }
    await probe.waitUntilRequested(selection.config.baseURL)
    await probe.complete(selection.config.baseURL, with: .authRequired)
    let resolution = try #require(await task.value)

    #expect(resolution.target.config.apiKey == "profile-key")
    #expect(resolution.target.profileID == "authenticated")
}

@Test func supersededDiscoveryCannotReclaimOwnershipWithItsNextCandidate() async {
    let probe = ControlledEngineProbe()
    let controller = EngineLifecycleController(probe: probe)
    let oldOperation = await controller.begin()
    let newOperation = await controller.begin()

    let stale = await controller.probe(target("old", port: 8000), for: oldOperation)
    #expect(stale == nil)
    #expect(!(await controller.isCurrent(oldOperation)))
    #expect(await controller.isCurrent(newOperation))
}

@Test func olderCallerCannotSupersedeANewerRegisteredIntent() async throws {
    let controller = EngineLifecycleController()
    let newer = try #require(await controller.begin(intentRevision: 2))
    let stale = await controller.begin(intentRevision: 1)

    #expect(stale == nil)
    #expect(await controller.isCurrent(newer))
}

@Test func sameEndpointNewerCredentialIntentKeepsOwnership() async throws {
    let controller = EngineLifecycleController()
    let newer = try #require(await controller.begin(intentRevision: 8))
    let stale = await controller.begin(intentRevision: 7)

    #expect(stale == nil)
    #expect(await controller.isCurrent(newer))

    let endpoint = URL(string: "http://127.0.0.1:8000")!
    let engine = OpenAICompatEngine(config: EngineConfig(baseURL: endpoint))
    let newConfig = EngineConfig(baseURL: endpoint, apiKey: "new-key")
    let oldConfig = EngineConfig(baseURL: endpoint, apiKey: "old-key")
    #expect(await engine.update(config: newConfig, revision: newer.revision))
    #expect(!(await engine.update(config: oldConfig, revision: newer.revision &- 1)))
    #expect(await engine.config == newConfig)
}

@Test func liveEngineRejectsAnOutOfOrderConfigurationCommit() async {
    let initial = EngineConfig(baseURL: URL(string: "http://127.0.0.1:8000")!)
    let newer = EngineConfig(baseURL: URL(string: "http://127.0.0.1:8002")!, apiKey: "new")
    let stale = EngineConfig(baseURL: URL(string: "http://127.0.0.1:8001")!, apiKey: "old")
    let engine = OpenAICompatEngine(config: initial)

    #expect(await engine.update(config: newer, revision: 2))
    #expect(!(await engine.update(config: stale, revision: 1)))
    #expect(await engine.config == newer)
}
