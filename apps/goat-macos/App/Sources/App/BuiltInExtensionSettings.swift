import Foundation
import Observation

/// App-wide availability is separate from the owner's scoped action approvals.
@MainActor @Observable
final class BuiltInExtensionSettings {
    private let defaults: UserDefaults
    private var subagentModels: [String: String]
    var herderEnabled: Bool { didSet { defaults.set(herderEnabled, forKey: "goated.herder.enabled") } }
    var herderWritesEnabled: Bool { didSet { defaults.set(herderWritesEnabled, forKey: "goated.herder.writes") } }
    var herderCommandsEnabled: Bool { didSet { defaults.set(herderCommandsEnabled, forKey: "goated.herder.commands") } }
    var subagentsEnabled: Bool { didSet { defaults.set(subagentsEnabled, forKey: "goated.subagents.enabled") } }
    private(set) var hindsightEnabled: Bool
    private(set) var commandTimeout: Int
    private(set) var subagentAutomaticBudget: Bool
    private(set) var subagentCustomTokenBudget: Int
    private(set) var subagentMaxRounds: Int
    private(set) var subagentTimeoutSeconds: Int
    private(set) var subagentPreferredBackend: SubagentBackendID

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        subagentAutomaticBudget = defaults.object(forKey: "goated.subagents.budget.auto") as? Bool ?? true
        let tokenBudget = defaults.integer(forKey: "goated.subagents.budget.tokens")
        subagentCustomTokenBudget = (32_768...131_072).contains(tokenBudget) ? tokenBudget : 65_536
        subagentModels = defaults.dictionary(forKey: "goated.subagents.models") as? [String: String] ?? [:]
        herderEnabled = defaults.object(forKey: "goated.herder.enabled") as? Bool ?? true
        herderWritesEnabled = defaults.object(forKey: "goated.herder.writes") as? Bool ?? true
        herderCommandsEnabled = defaults.object(forKey: "goated.herder.commands") as? Bool ?? true
        hindsightEnabled = defaults.object(forKey: "goated.hindsight.enabled") as? Bool ?? true
        let timeout = defaults.integer(forKey: "goated.herder.timeout")
        commandTimeout = (1...600).contains(timeout) ? timeout : 120
        subagentsEnabled = defaults.object(forKey: "goated.subagents.enabled") as? Bool ?? true
        let maxRounds = defaults.integer(forKey: "goated.subagents.max_rounds")
        subagentMaxRounds = (1...10).contains(maxRounds) ? maxRounds : SubagentLimits.defaultMaxRounds
        let timeoutSec = defaults.integer(forKey: "goated.subagents.timeout")
        subagentTimeoutSeconds =
            (10...SubagentLimits.ceilingTimeoutSeconds).contains(timeoutSec)
            ? timeoutSec : SubagentLimits.defaultTimeoutSeconds
        if let backendRaw = defaults.string(forKey: "goated.subagents.backend"),
            let backend = SubagentBackendID(rawValue: backendRaw)
        {
            subagentPreferredBackend = backend
        } else {
            subagentPreferredBackend = .localEngine
        }
    }

    /// Selections are scoped to the engine profile, never silently reused on another server.
    func subagentModelID(for engineID: String?) -> String? {
        guard let engineID else { return nil }
        return subagentModels[engineID]
    }

    func setSubagentModelID(_ modelID: String?, for engineID: String) {
        subagentModels[engineID] = modelID.flatMap { $0.isEmpty ? nil : $0 }
        defaults.set(subagentModels, forKey: "goated.subagents.models")
    }

    func setCommandTimeout(_ value: Int) {
        commandTimeout = min(600, max(1, value))
        defaults.set(commandTimeout, forKey: "goated.herder.timeout")
    }

    func setHindsightEnabled(_ value: Bool) {
        hindsightEnabled = value
        defaults.set(value, forKey: "goated.hindsight.enabled")
    }

    func setSubagentAutomaticBudget(_ value: Bool) {
        subagentAutomaticBudget = value
        defaults.set(value, forKey: "goated.subagents.budget.auto")
    }

    func setSubagentCustomTokenBudget(_ value: Int) {
        subagentCustomTokenBudget = min(131_072, max(32_768, value))
        defaults.set(subagentCustomTokenBudget, forKey: "goated.subagents.budget.tokens")
    }

    func setSubagentMaxRounds(_ value: Int) {
        subagentMaxRounds = min(10, max(1, value))
        defaults.set(subagentMaxRounds, forKey: "goated.subagents.max_rounds")
    }

    func setSubagentTimeoutSeconds(_ value: Int) {
        subagentTimeoutSeconds = min(SubagentLimits.ceilingTimeoutSeconds, max(10, value))
        defaults.set(subagentTimeoutSeconds, forKey: "goated.subagents.timeout")
    }

    func setSubagentPreferredBackend(_ value: SubagentBackendID) {
        subagentPreferredBackend = value
        defaults.set(value.rawValue, forKey: "goated.subagents.backend")
    }

    var subagentConfiguration: SubagentConfiguration {
        SubagentConfiguration(
            enabled: subagentsEnabled,
            maxRounds: subagentMaxRounds,
            timeoutSeconds: subagentTimeoutSeconds,
            preferredBackend: subagentPreferredBackend,
            customTokenBudget: subagentAutomaticBudget ? nil : subagentCustomTokenBudget
        )
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
