import Testing

@testable import GOAT

@Test func penCardsNeverClaimMemoryIsOnBeforeConfigurationAndProviderAreReady() {
    #expect(
        PenCardMemoryState.resolve(
            configuration: .loading, globalEnabled: true, penEnabled: true, providerAvailable: true) == .loading)
    #expect(
        PenCardMemoryState.resolve(
            configuration: .failed, globalEnabled: true, penEnabled: true, providerAvailable: true) == .unavailable)
    #expect(
        PenCardMemoryState.resolve(
            configuration: .ready, globalEnabled: true, penEnabled: true, providerAvailable: false) == .unavailable)
    #expect(
        PenCardMemoryState.resolve(
            configuration: .ready, globalEnabled: true, penEnabled: true, providerAvailable: true) == .ready)
}

@Test func penCardsDistinguishDisabledPensFromTheGlobalMemoryPause() {
    #expect(
        PenCardMemoryState.resolve(
            configuration: .ready, globalEnabled: false, penEnabled: false, providerAvailable: false) == .off)
    #expect(
        PenCardMemoryState.resolve(
            configuration: .ready, globalEnabled: true, penEnabled: false, providerAvailable: true) == .off)
    #expect(
        PenCardMemoryState.resolve(
            configuration: .ready, globalEnabled: false, penEnabled: true, providerAvailable: true) == .paused)
}
