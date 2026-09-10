import AppKit
import Caprine
import Testing

@testable import GOAT

@Test @MainActor func preferenceResetUpdatesLiveSettingsAndPreservesUnrelatedState() throws {
    let model = AppModel.shared
    let defaults = UserDefaults.standard
    let domain = try #require(Bundle.main.bundleIdentifier)
    let original = defaults.persistentDomain(forName: domain) ?? [:]
    let strings: [(ReferenceWritableKeyPath<AppModel, String>, String)] = [
        (\.themeID, model.themeID), (\.chatFontID, model.chatFontID), (\.codeFontID, model.codeFontID),
    ]
    let numbers: [(ReferenceWritableKeyPath<AppModel, Double>, Double)] = [
        (\.chatFontSize, model.chatFontSize), (\.codeFontSize, model.codeFontSize),
        (\.windowTransparency, model.windowTransparency),
    ]
    let flags: [(ReferenceWritableKeyPath<AppModel, Bool>, Bool)] = [
        (\.animationsEnabled, model.animationsEnabled), (\.automaticChatTitles, model.automaticChatTitles),
        (\.settingsAlwaysOnTop, model.settingsAlwaysOnTop),
    ]
    let effort = model.defaultEffort
    let icon = AppIconManager.current
    defer {
        for (key, value) in strings { model[keyPath: key] = value }
        for (key, value) in numbers { model[keyPath: key] = value }
        for (key, value) in flags { model[keyPath: key] = value }
        model.defaultEffort = effort
        AppIconManager.apply(
            icon, unlocked: model.presentation.isUnlocked, playful: model.presentation.isEnabled,
            dark: model.theme.isDark)
        defaults.setPersistentDomain(original, forName: domain)
    }
    model.themeID = "midnight"
    model.chatFontID = "system"
    model.codeFontID = "system"
    model.chatFontSize = 22
    model.codeFontSize = 20
    model.windowTransparency = 0.8
    model.animationsEnabled = false
    model.automaticChatTitles = false
    model.settingsAlwaysOnTop = false
    defaults.set("list", forKey: "pens.overview.layout")
    let before = defaults.persistentDomain(forName: domain) ?? [:]
    let selectedChat = model.selectedChatID
    let endpoint = model.endpoint
    let privacy = model.judasMode
    let offGrid = model.previewsOffGrid
    let unlocked = model.presentation.isUnlocked

    model.resetPreferences()

    #expect(model.themeID == "system")
    #expect(model.chatFontID == "theme" && model.codeFontID == "theme")
    #expect(model.chatFontSize == 14 && model.codeFontSize == 13)
    #expect(model.windowTransparency == CaprineBackground.defaultTransparency)
    #expect(model.animationsEnabled && model.automaticChatTitles && model.settingsAlwaysOnTop)
    #expect(model.defaultEffort == .trot)
    #expect(AppIconManager.current == .system)
    #expect(defaults.string(forKey: "pens.overview.layout") == "grid")
    #expect(defaults.string(forKey: "appearance.theme") == model.themeID)
    #expect(defaults.double(forKey: "appearance.fontSize") == model.chatFontSize)
    #expect(defaults.double(forKey: "appearance.codeFontSize") == model.codeFontSize)
    #expect(model.selectedChatID == selectedChat && model.endpoint == endpoint)
    #expect(model.judasMode == privacy && model.previewsOffGrid == offGrid)
    #expect(model.presentation.isUnlocked == unlocked && !model.presentation.isEnabled)
    let resetKeys: Set<String> = [
        "appearance.theme", "appearance.chatFont", "appearance.codeFont", "appearance.fontSize",
        "appearance.codeFontSize", "appearance.transparency", "appearance.animations",
        "chat.automaticTitles", "chat.defaultEffort", "settings.alwaysOnTop", "pens.overview.layout",
        "experience.1337.enabled", "appIcon",
    ]
    let after = defaults.persistentDomain(forName: domain) ?? [:]
    #expect(
        NSDictionary(dictionary: before.filter { !resetKeys.contains($0.key) })
            .isEqual(to: after.filter { !resetKeys.contains($0.key) }))
}
