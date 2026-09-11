import Foundation

/// The effort dial: Graze / Trot / Climb / Summit.
/// Maps to model-agnostic sampling and response budgets (docs/ENGINES.md).
public enum Effort: String, CaseIterable, Codable, Sendable, Identifiable {
    case graze, trot, climb, summit

    public var id: String { rawValue }

    public var emoji: String {
        switch self {
        case .graze: "🌱"
        case .trot: "🚶"
        case .climb: "🪜"
        case .summit: "🏔️"
        }
    }

    public var label: String {
        switch self {
        case .graze: "Graze"
        case .trot: "Trot"
        case .climb: "Climb"
        case .summit: "Summit"
        }
    }

    public var blurb: String {
        switch self {
        case .graze: "Quick, compact responses"
        case .trot: "Sure-footed everyday pace"
        case .climb: "More room for hard problems"
        case .summit: "Maximum response budget"
        }
    }

    public var temperature: Double {
        switch self {
        case .graze: 0.7
        case .trot: 0.7
        case .climb: 0.6
        case .summit: 0.6
        }
    }

    /// Requested output ceiling for a model that explicitly cannot reason. The prompt budget
    /// still clamps this to half the context window.
    public var maxTokens: Int {
        switch self {
        case .graze: 1024
        case .trot: 2048
        case .climb: 4096
        case .summit: 8192
        }
    }

    /// Reasoning tokens count against `max_tokens` on every OpenAI-compatible engine, so a
    /// model that may think gets twice the ceiling (ADR-0085). Unknown counts as "may think":
    /// the budget clamp, not the effort preset, protects the input side.
    public var reasoningOutputCeiling: Int { maxTokens * 2 }

    public func outputCeiling(for capabilities: ModelCapabilities) -> Int {
        capabilities.reasoning.support == .unsupported ? maxTokens : reasoningOutputCeiling
    }
}
