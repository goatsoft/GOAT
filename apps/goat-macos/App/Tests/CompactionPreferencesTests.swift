import Foundation
import Shepherd
import Testing

@testable import GOAT

// ADR-0087 Stage 2c: compaction preferences persist and override the ShepherdEnvironment defaults.
// AppModel.shared is a process-wide singleton, so each test restores the values it touches.

@Test @MainActor func compactAtPercentClampsToConfiguredRange() {
    let model = AppModel.shared
    let original = model.compactAtPercent
    defer { model.compactAtPercent = original }
    model.compactAtPercent = 30
    #expect(model.compactAtPercent == 50)
    model.compactAtPercent = 130
    #expect(model.compactAtPercent == 95)
    model.compactAtPercent = 75
    #expect(model.compactAtPercent == 75)
}

@Test @MainActor func compactionPreferencesOverrideEnvironmentDefaults() {
    let model = AppModel.shared
    let originalEnabled = model.autoCompactEnabled
    let originalPercent = model.compactAtPercent
    defer {
        model.autoCompactEnabled = originalEnabled
        model.compactAtPercent = originalPercent
    }
    model.autoCompactEnabled = false
    model.compactAtPercent = 65
    // AppModel satisfies ShepherdEnvironment; its stored values must win over the protocol defaults (true/80).
    let env: any ShepherdEnvironment = model
    #expect(env.autoCompactEnabled == false)
    #expect(env.compactAtPercent == 65)
}

@Test @MainActor func compactionPreferencesPersistToUserDefaults() {
    let model = AppModel.shared
    let originalEnabled = model.autoCompactEnabled
    let originalPercent = model.compactAtPercent
    defer {
        model.autoCompactEnabled = originalEnabled
        model.compactAtPercent = originalPercent
    }
    model.autoCompactEnabled = false
    model.compactAtPercent = 70
    #expect(UserDefaults.standard.object(forKey: "chat.autoCompact") as? Bool == false)
    #expect(UserDefaults.standard.integer(forKey: "chat.compactAtPercent") == 70)
}
