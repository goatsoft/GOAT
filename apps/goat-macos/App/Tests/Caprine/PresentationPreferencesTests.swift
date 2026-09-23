import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Caprine
@testable import GOAT
@testable import Paddock

private actor MockJSONWorker: JSONDocumentWorker {
    var loadDelayNanoseconds: UInt64 = 0
    var loadResult: JSONFileWorker.LoadResult = .loaded("{\"status\": \"ok\"}")
    var validationErrorResult: String? = nil
    var saveResult: String? = nil

    func setLoadDelay(milliseconds: UInt64) {
        loadDelayNanoseconds = milliseconds * 1_000_000
    }

    func setLoadResult(_ result: JSONFileWorker.LoadResult) {
        loadResult = result
    }

    func setValidationError(_ error: String?) {
        validationErrorResult = error
    }

    func load(_ url: URL) async -> JSONFileWorker.LoadResult {
        if loadDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: loadDelayNanoseconds)
        }
        return loadResult
    }

    func validationError(for text: String) async -> String? {
        if let validationErrorResult { return validationErrorResult }
        guard let data = text.data(using: .utf8) else { return "Not UTF-8" }
        do {
            _ = try JSONSerialization.jsonObject(with: data)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func save(_ data: Data, to url: URL) async -> String? {
        saveResult
    }
}

extension AppTests.Caprine {
    @Suite struct PresentationPreferencesTests {

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
            #expect(preferences.unlock() && preferences.isEnabled)
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

        @MainActor
        @Test func windowConfiguratorAlwaysOnTopTogglesBothDirectionsOnSameWindow() async throws {
            struct HostView: View {
                @Binding var alwaysOnTop: Bool
                var body: some View {
                    Color.clear
                        .background(
                            WindowConfigurator(
                                alwaysOnTop: alwaysOnTop,
                                showsAlwaysOnTopToggle: true,
                                onAlwaysOnTopToggle: { alwaysOnTop.toggle() }
                            )
                        )
                }
            }

            final class StateHolder: ObservableObject {
                @Published var alwaysOnTop = false
            }

            struct Wrapper: View {
                @ObservedObject var state: StateHolder
                var body: some View {
                    HostView(alwaysOnTop: $state.alwaysOnTop)
                }
            }

            let state = StateHolder()
            let controller = NSHostingController(rootView: Wrapper(state: state))
            let window = NSWindow(contentViewController: controller)
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 400, height: 300))
            window.orderFront(nil)
            defer {
                window.contentViewController = nil
                window.close()
            }

            try await Task.sleep(for: .milliseconds(150))
            #expect(window.level == .normal)

            // Toggle on
            state.alwaysOnTop = true
            try await Task.sleep(for: .milliseconds(150))
            #expect(window.level == .floating)

            // Toggle off on the same window
            state.alwaysOnTop = false
            try await Task.sleep(for: .milliseconds(150))
            #expect(window.level == .normal)
        }
    }

    @Suite struct JSONEditorTests {

        @Test @MainActor func delayedLoadFailureDisablesEditingAndPreventsValidationRace() async throws {
            let worker = MockJSONWorker()
            await worker.setLoadDelay(milliseconds: 100)
            await worker.setLoadResult(.failed("Disk read timeout"))

            let state = JSONEditorState()
            let dummyURL = URL(fileURLWithPath: "/tmp/test.json")

            let loadTask = Task { @MainActor in
                await state.load(from: dummyURL, worker: worker)
            }

            // Immediately during load, state must be loading, and editor/save must be disabled
            #expect(state.phase == .loading)
            #expect(!state.phase.isEditable)
            #expect(!state.phase.canSave)
            #expect(!state.isDocumentReady)

            // Triggering validation while load is pending must NOT overwrite .loading
            await state.validate(worker: worker)
            #expect(state.phase == .loading)
            #expect(!state.phase.isEditable)
            #expect(!state.phase.canSave)

            // Wait for delayed load to complete
            await loadTask.value

            // Verify load failed state
            #expect(state.phase == .loadFailed("Disk read timeout"))
            #expect(!state.phase.isEditable)
            #expect(!state.phase.canSave)
            #expect(!state.isDocumentReady)

            // Further validation attempts after failure must stay disabled and not overwrite phase
            await state.validate(worker: worker)
            #expect(state.phase == .loadFailed("Disk read timeout"))
            #expect(!state.phase.isEditable)
            #expect(!state.phase.canSave)
        }

        @Test @MainActor func successfulLoadDrivesValidationAndTracksGenerations() async throws {
            let worker = MockJSONWorker()
            await worker.setLoadResult(.loaded("{\"valid\": true}"))

            let state = JSONEditorState()
            let dummyURL = URL(fileURLWithPath: "/tmp/valid.json")

            await state.load(from: dummyURL, worker: worker)

            #expect(state.isDocumentReady)
            #expect(state.text == "{\"valid\": true}")
            #expect(state.phase == .valid)
            #expect(state.phase.isEditable)
            #expect(state.phase.canSave)

            // User edits text to invalid JSON
            state.text = "{\"valid\": true"
            let validateTask = Task { @MainActor in
                await state.validate(worker: worker)
            }
            await validateTask.value

            #expect(state.phase.isEditable)
            #expect(!state.phase.canSave)
            if case .invalid = state.phase {
                // Expected invalid JSON error
            } else {
                Issue.record("Expected phase to be .invalid, but got \(state.phase)")
            }

            // Restoring valid JSON enables Save
            state.text = "{\"valid\": false}"
            await state.validate(worker: worker)
            #expect(state.phase == .valid)
            #expect(state.phase.canSave)
        }

        @Test @MainActor func jsonEditorInstallsLineNumberRulerAndUpdatesThemeTokens() async throws {
            struct HostView: View {
                @State var text = "{\"key\": 123}"
                var tokens: Caprine
                var body: some View {
                    JSONEditorView(text: $text, tokens: tokens, isEditable: true)
                }
            }

            let initialView = HostView(tokens: ThemeCatalog.midnight.tokens)
            let host = NSHostingView(rootView: initialView)
            host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
            host.layoutSubtreeIfNeeded()

            func findScrollView(_ view: NSView) -> NSScrollView? {
                if let sv = view as? NSScrollView { return sv }
                return view.subviews.lazy.compactMap(findScrollView).first
            }

            let scroll = try #require(findScrollView(host))
            #expect(scroll.hasVerticalRuler)
            let ruler = try #require(scroll.verticalRulerView as? LineNumberRuler)
            #expect(ruler.tv != nil)
            let tv = try #require(scroll.documentView as? NSTextView)
            #expect(tv.insertionPointColor == NSColor(ThemeCatalog.midnight.tokens.tint))

            // Update to light theme
            host.rootView = HostView(tokens: ThemeCatalog.light.tokens)
            host.layoutSubtreeIfNeeded()

            #expect(tv.insertionPointColor == NSColor(ThemeCatalog.light.tokens.tint))
            #expect(ruler.tokens.ink == ThemeCatalog.light.tokens.ink)
        }
    }
}
