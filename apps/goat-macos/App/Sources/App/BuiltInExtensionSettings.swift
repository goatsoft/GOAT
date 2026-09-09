import Foundation
import Observation

/// App-wide availability is separate from the owner's scoped action approvals.
@MainActor @Observable
final class BuiltInExtensionSettings {
    private let defaults: UserDefaults
    var herderEnabled: Bool { didSet { defaults.set(herderEnabled, forKey: "goated.herder.enabled") } }
    var herderWritesEnabled: Bool { didSet { defaults.set(herderWritesEnabled, forKey: "goated.herder.writes") } }
    var herderCommandsEnabled: Bool { didSet { defaults.set(herderCommandsEnabled, forKey: "goated.herder.commands") } }
    private(set) var hindsightEnabled: Bool
    private(set) var commandTimeout: Int

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        herderEnabled = defaults.object(forKey: "goated.herder.enabled") as? Bool ?? true
        herderWritesEnabled = defaults.object(forKey: "goated.herder.writes") as? Bool ?? true
        herderCommandsEnabled = defaults.object(forKey: "goated.herder.commands") as? Bool ?? true
        hindsightEnabled = defaults.object(forKey: "goated.hindsight.enabled") as? Bool ?? true
        let timeout = defaults.integer(forKey: "goated.herder.timeout")
        commandTimeout = (1...600).contains(timeout) ? timeout : 120
    }

    func setCommandTimeout(_ value: Int) {
        commandTimeout = min(600, max(1, value))
        defaults.set(commandTimeout, forKey: "goated.herder.timeout")
    }

    func setHindsightEnabled(_ value: Bool) {
        hindsightEnabled = value
        defaults.set(value, forKey: "goated.hindsight.enabled")
    }

    func allowsHerderTool(_ name: String) -> Bool {
        guard herderEnabled else { return false }
        switch name {
        case "pen_write_file", "pen_edit_file": return herderWritesEnabled
        case "pen_run_command", "pen_command_status", "pen_stop_command": return herderCommandsEnabled
        default: return true
        }
    }
}
