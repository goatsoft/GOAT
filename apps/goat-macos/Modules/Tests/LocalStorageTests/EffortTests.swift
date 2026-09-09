import Foundation
import Testing

@testable import Caprine
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

@Test func themeSpecsRoundTripThroughCodable() throws {
    for spec in ThemeCatalog.builtins {
        let data = try JSONEncoder().encode(spec)
        #expect(try JSONDecoder().decode(ThemeSpec.self, from: data) == spec)
    }
}

@Test func leetIsTheOnlyMonospaceBuiltin() {
    let monos = ThemeCatalog.builtins.filter(\.isMono).map(\.id)
    #expect(monos == ["leet"])
}

@Test func builtinsAreReadOnlyAndUserThemesAppend() throws {
    // A user theme claiming a built-in id can't override it (ADR-0022); a new id appends.
    let userThemes = [
        ThemeSpec(
            id: "system", name: "Hacked System", appearance: .system,
            bg: "#000000", surface: "#111111", ink: "#FFFFFF", muted: "#888888",
            accent: "#FF0000", accent2: "#00FF00", glow: "#0000FF",
            selection: "#FF0000", tint: "#FF0000", washOpacity: 0.1, bgOpacity: 0.4),
        ThemeSpec(
            id: "sunset", name: "Sunset", appearance: .dark,
            bg: "#1A0E14", surface: "#241019", ink: "#FFF0E8", muted: "#B08575",
            accent: "#FF6B4A", accent2: "#FFB03A", glow: "#FF8A3A",
            selection: "#FF6B4A", tint: "#FF6B4A", washOpacity: 0.18, bgOpacity: 0.42, intensity: 1.2),
    ]
    let all = ThemeCatalog.all(userThemes: userThemes)
    #expect(all[0].id == "system")
    #expect(all[0].name == "System")  // the built-in wins; the impostor is dropped
    #expect(all.last?.id == "sunset")  // a genuinely new theme appends after built-ins
    #expect(all.count == ThemeCatalog.builtins.count + 1)
}
