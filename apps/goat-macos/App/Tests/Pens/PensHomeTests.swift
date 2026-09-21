import Foundation
import Inference
import Testing

@testable import GOAT

extension AppTests.Pens {
    @Suite struct PensHomeTests {

        @Test func penCardsNeverClaimMemoryIsOnBeforeConfigurationAndProviderAreReady() {
            #expect(
                PenCardMemoryState.resolve(
                    configuration: .loading, globalEnabled: true, penEnabled: true, providerAvailable: true) == .loading
            )
            #expect(
                PenCardMemoryState.resolve(
                    configuration: .failed, globalEnabled: true, penEnabled: true, providerAvailable: true)
                    == .unavailable)
            #expect(
                PenCardMemoryState.resolve(
                    configuration: .ready, globalEnabled: true, penEnabled: true, providerAvailable: false)
                    == .unavailable)
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
    }
}

extension AppTests.Pens {
    @Suite struct PenChatNavigationTests {

        @MainActor
        @Test func newChatNavigationUsesVisiblePenContext() {
            let pen = UUID()
            let other = UUID()
            let known = Set([pen, other])
            #expect(
                AppModel.newChatPenID(selectedPenID: nil, chatProjectID: pen, showingPensHome: false, penIDs: known)
                    == pen)
            #expect(
                AppModel.newChatPenID(selectedPenID: other, chatProjectID: pen, showingPensHome: false, penIDs: known)
                    == other)
            #expect(
                AppModel.newChatPenID(selectedPenID: nil, chatProjectID: nil, showingPensHome: false, penIDs: known)
                    == nil)
            #expect(
                AppModel.newChatPenID(selectedPenID: nil, chatProjectID: pen, showingPensHome: true, penIDs: known)
                    == nil)
            #expect(
                AppModel.newChatPenID(selectedPenID: nil, chatProjectID: UUID(), showingPensHome: false, penIDs: known)
                    == nil)
        }
    }
}
