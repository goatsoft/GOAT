import Foundation
import Observation

/// Local presentation capability only. Never consulted by inference, storage, or tool permissions.
@MainActor
@Observable
final class PresentationPreferences {
    private let defaults: UserDefaults
    private(set) var isUnlocked: Bool
    private(set) var isEnabled: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let unlocked = defaults.bool(forKey: "experience.1337.unlocked")
        isUnlocked = unlocked
        isEnabled = unlocked && defaults.bool(forKey: "experience.1337.enabled")
    }

    @discardableResult
    func unlock() -> Bool {
        guard !isUnlocked else { return false }
        isUnlocked = true
        defaults.set(true, forKey: "experience.1337.unlocked")
        setEnabled(true)
        return true
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = isUnlocked && enabled
        defaults.set(isEnabled, forKey: "experience.1337.enabled")
    }

    func permitsTheme(_ id: String) -> Bool { id != "leet" || isUnlocked }

    /// Mascots belong to the 1337 theme. Keep restored and newly selected themes in sync
    /// with the presentation gate so a previous 1337 session cannot leak into Light/Dark.
    func selectTheme(_ id: String) -> String {
        let selected = permitsTheme(id) ? id : "system"
        setEnabled(selected == "leet")
        return selected
    }
}

/// Bounded input recognizer. The About view owns its lifetime and resets it on focus loss.
struct AboutUnlockSequence {
    private(set) var progress = 0
    private var startedAt: TimeInterval?
    private let code = Array("1337")

    mutating func reset() {
        progress = 0
        startedAt = nil
    }

    mutating func consume(_ characters: String, at time: TimeInterval, isRepeat: Bool = false) -> Bool {
        guard !isRepeat else { return false }
        if let startedAt, time - startedAt > 10 { reset() }
        guard characters.count == 1, let character = characters.first else {
            reset()
            return false
        }
        if character != code[progress] { reset() }
        guard character == code[progress] else { return false }
        if progress == 0 { startedAt = time }
        progress += 1
        if progress == code.count {
            reset()
            return true
        }
        return false
    }
}
