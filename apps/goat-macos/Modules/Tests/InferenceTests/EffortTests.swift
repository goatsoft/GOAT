import Foundation
import Testing

@testable import Inference

@Test func effortLevelsAreOrderedByBudget() {
    let budgets = Effort.allCases.map(\.maxTokens)
    #expect(budgets == budgets.sorted())
    #expect(Effort.summit.maxTokens > Effort.graze.maxTokens)
}

@Test func everyEffortHasIdentity() {
    for e in Effort.allCases {
        #expect(!e.label.isEmpty)
        #expect(!e.emoji.isEmpty)
        #expect(!e.blurb.isEmpty)
    }
}
