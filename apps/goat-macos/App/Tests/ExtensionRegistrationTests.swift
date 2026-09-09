import Foundation
import GOATed
import Testing

@testable import GOAT

private struct RegistrationTestExtension: Extension {
    let manifest: ExtensionManifest
    let contributions = ExtensionContributions()
    init(_ id: String) { manifest = ExtensionManifest(id: id, version: "0.1.0") }
}

@MainActor private final class RegistrationGate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor @Test func failedRegistrationRetriesAfterCapacityIsFreed() async throws {
    let runtime = ExtensionRuntime()
    var tokens: [Registration] = []
    for index in 0..<32 {
        tokens.append(try await runtime.activate(RegistrationTestExtension("test.slot\(index)")))
    }
    var failures = 0
    let controller = ExtensionRegistrationController(
        activate: { try await runtime.activate(RegistrationTestExtension("goat.hindsight")) },
        deactivate: { try? await runtime.unregister($0) },
        reportFailure: { _ in failures += 1 })
    await controller.setEnabled(true)
    #expect(failures == 1)
    try await runtime.unregister(tokens[0])
    await controller.setEnabled(true)
    #expect(await runtime.activeExtensions().contains { $0.id.rawValue == "goat.hindsight" })
    #expect(failures == 1)
    await controller.setEnabled(false)
    #expect(!(await runtime.activeExtensions().contains { $0.id.rawValue == "goat.hindsight" }))
}

@MainActor @Test func overlappingRegistrationRefreshesShareActivation() async throws {
    let runtime = ExtensionRuntime()
    let gate = RegistrationGate()
    var attempts = 0
    let controller = ExtensionRegistrationController(
        activate: {
            attempts += 1
            await gate.wait()
            return try await runtime.activate(RegistrationTestExtension("goat.hindsight"))
        },
        deactivate: { try? await runtime.unregister($0) }, reportFailure: { _ in Issue.record("Activation failed") })
    let first = Task { await controller.setEnabled(true) }
    for _ in 0..<1_000 where !gate.entered { await Task.yield() }
    #expect(gate.entered)
    let second = Task { await controller.setEnabled(true) }
    await Task.yield()
    gate.release()
    await first.value
    await second.value
    await controller.setEnabled(true)
    #expect(attempts == 1)
    await controller.setEnabled(false)
}

@MainActor @Test func disablingDuringActivationRemovesTheLateRegistration() async throws {
    let runtime = ExtensionRuntime()
    let gate = RegistrationGate()
    let controller = ExtensionRegistrationController(
        activate: {
            await gate.wait()
            return try await runtime.activate(RegistrationTestExtension("goat.hindsight"))
        },
        deactivate: { try? await runtime.unregister($0) }, reportFailure: { _ in Issue.record("Activation failed") })
    let enable = Task { await controller.setEnabled(true) }
    for _ in 0..<1_000 where !gate.entered { await Task.yield() }
    #expect(gate.entered)
    let disable = Task { await controller.setEnabled(false) }
    await Task.yield()
    gate.release()
    await enable.value
    await disable.value
    #expect(await runtime.activeExtensions().isEmpty)
}

@MainActor @Test func rapidReenableWaitsForObsoleteRegistrationRemoval() async throws {
    let runtime = ExtensionRuntime()
    let gate = RegistrationGate()
    var attempts = 0
    var removals = 0
    let controller = ExtensionRegistrationController(
        activate: {
            attempts += 1
            if attempts == 1 { await gate.wait() }
            return try await runtime.activate(RegistrationTestExtension("goat.hindsight"))
        },
        deactivate: { token in
            removals += 1
            try? await runtime.unregister(token)
        },
        reportFailure: { _ in Issue.record("Activation failed") })
    let first = Task { await controller.setEnabled(true) }
    for _ in 0..<1_000 where !gate.entered { await Task.yield() }
    #expect(gate.entered)
    let disable = Task { await controller.setEnabled(false) }
    await Task.yield()
    let enable = Task { await controller.setEnabled(true) }
    await Task.yield()
    gate.release()
    await first.value
    await disable.value
    await enable.value
    #expect(attempts == 2)
    #expect(removals == 1)
    #expect(await runtime.activeExtensions().count == 1)
    await controller.setEnabled(false)
}

@MainActor @Test func rapidToggleOfActiveRegistrationNeverActivatesADuplicate() async throws {
    let runtime = ExtensionRuntime()
    let controller = ExtensionRegistrationController(
        activate: { try await runtime.activate(RegistrationTestExtension("goat.hindsight")) },
        deactivate: { try? await runtime.unregister($0) },
        reportFailure: { _ in Issue.record("Activation failed") })
    await controller.setEnabled(true)
    for _ in 0..<20 {
        let disable = Task { await controller.setEnabled(false) }
        let enable = Task { await controller.setEnabled(true) }
        await disable.value
        await enable.value
        #expect(await runtime.activeExtensions().count == 1)
    }
    await controller.setEnabled(false)
    #expect(await runtime.activeExtensions().isEmpty)
}
