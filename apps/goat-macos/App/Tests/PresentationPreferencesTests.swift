import Foundation
import Testing

@testable import Caprine
@testable import GOAT
@testable import Paddock

@Test @MainActor func goatiesAreEnabledOnlyWhileTheUnlocked1337ThemeIsSelected() throws {
    let name = "goat.presentation.theme.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = PresentationPreferences(defaults: defaults)
    #expect(preferences.selectTheme("leet") == "system")
    #expect(!preferences.isEnabled)
    preferences.unlock()
    for standard in ["system", "light", "midnight", "pasture", "custom"] {
        #expect(preferences.selectTheme("leet") == "leet")
        #expect(preferences.isEnabled)
        #expect(preferences.selectTheme(standard) == standard)
        #expect(!preferences.isEnabled)
        #expect(preferences.isUnlocked)
    }
}

@Test @MainActor func restoringAStandardThemeClearsAStalePlayfulPreference() throws {
    let name = "goat.presentation.restore.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(true, forKey: "experience.1337.unlocked")
    defaults.set(true, forKey: "experience.1337.enabled")
    let preferences = PresentationPreferences(defaults: defaults)
    #expect(preferences.selectTheme("midnight") == "midnight")
    #expect(!preferences.isEnabled)
    #expect(!PresentationPreferences(defaults: defaults).isEnabled)
}

@Test func assistantGoatiesWaveWhenFinishedThinkWhileBusyAndWarnOnErrors() {
    #expect(Goatie.assistant(complete: true, hasError: false) == .wave)
    #expect(Goatie.assistant(complete: false, hasError: false) == .thinking)
    #expect(Goatie.assistant(complete: true, hasError: true) == .warning)
    #expect(Goatie.assistant(complete: false, hasError: true) == .warning)
}

@MainActor
@Test func presentationUnlockIsPersistentIdempotentAndFailClosed() throws {
    let name = "goat.presentation.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(true, forKey: "experience.1337.enabled")
    let preferences = PresentationPreferences(defaults: defaults)
    #expect(!preferences.isUnlocked && !preferences.isEnabled)
    #expect(!preferences.permitsTheme("leet"))
    #expect(preferences.permitsTheme("pasture"))
    preferences.setEnabled(true)
    #expect(!preferences.isEnabled)
    #expect(preferences.unlock())
    #expect(preferences.isEnabled)
    #expect(!preferences.unlock())
    preferences.setEnabled(false)
    let restored = PresentationPreferences(defaults: defaults)
    #expect(restored.isUnlocked && !restored.isEnabled)
    #expect(restored.permitsTheme("leet"))
    #expect(!restored.unlock())
    #expect(!restored.isEnabled)
}

@Test func aboutSequenceRejectsTimeoutRepeatAndPaste() {
    var sequence = AboutUnlockSequence()
    func consume(_ characters: String, at time: TimeInterval, isRepeat: Bool = false) -> Bool {
        sequence.consume(characters, at: time, isRepeat: isRepeat)
    }
    #expect(!consume("1337", at: 0))
    #expect(!consume("1", at: 1))
    #expect(!consume("3", at: 2))
    #expect(!consume("3", at: 2.1, isRepeat: true))
    #expect(!consume("7", at: 3))
    #expect(sequence.progress == 0)
    #expect(!consume("1", at: 4))
    #expect(!consume("3", at: 15))
    #expect(sequence.progress == 0)
    for (index, digit) in Array("x11337").enumerated() {
        #expect(consume(String(digit), at: Double(20 + index)) == (index == 5))
    }
    #expect(sequence.progress == 0)
    _ = consume("1", at: 30)
    sequence.reset()
    #expect(!consume("3", at: 31))
}

@MainActor
@Test func professionalIconsCannotRestoreLockedVariants() {
    for icon in [AppIcon.original, .v] {
        #expect(!AppIconManager.available(unlocked: false, playful: true).contains(icon))
        #expect(!AppIconManager.available(unlocked: true, playful: false).contains(icon))
        #expect(AppIconManager.available(unlocked: true, playful: true).contains(icon))
        #expect(AppIconManager.resolved(icon, unlocked: false, playful: true, dark: false) == .light)
        #expect(AppIconManager.resolved(icon, unlocked: true, playful: false, dark: false) == .light)
        #expect(AppIconManager.resolved(icon, unlocked: true, playful: false, dark: true) == .dark)
        #expect(AppIconManager.resolved(icon, unlocked: true, playful: true, dark: false) == icon)
    }
    #expect(AppIconManager.resolved(.system, unlocked: false, playful: false, dark: true) == .dark)
}

@Test func mermaidUsesThemeAndRejectsInjectedColors() {
    var theme = ThemeCatalog.light
    theme.tint = "#83582F"
    let html = PaddockHTML.mermaidShell("graph TD; A-->B", dark: false, theme: theme)
    #expect(html.contains("#83582F"))
    #expect(html.contains("theme: 'base'"))
    theme.bg = "</style><script>alert(1)</script>"
    let safe = PaddockHTML.mermaidShell("<script>bad</script>", dark: false, theme: theme)
    #expect(!safe.contains("alert(1)"))
    #expect(safe.contains("&lt;script&gt;bad&lt;/script&gt;"))
}

@Test func builtInTextAndControlColorsHaveContrast() {
    func luminance(_ hex: String) -> Double {
        let n = UInt32(hex.dropFirst(), radix: 16) ?? 0
        let channels = [Double((n >> 16) & 255), Double((n >> 8) & 255), Double(n & 255)].map {
            let v = $0 / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
    }
    for theme in ThemeCatalog.builtins where theme.id != "system" {
        for background in [theme.bg, theme.surface] {
            for foreground in [theme.ink, theme.muted, theme.tint, theme.accent, theme.accent2] {
                let values = [luminance(background), luminance(foreground)].sorted()
                let ratio = (values[1] + 0.05) / (values[0] + 0.05)
                #expect(ratio >= 4.5, "\(theme.id) \(foreground) on \(background): \(ratio)")
            }
        }
    }
}
