import Foundation

public enum EngineFailureClassification: String, Codable, Equatable, Sendable {
    case unsupportedModelArchitecture
    case modelUnavailable
    case authentication
    case connection
    case malformedResponse
    case unknown
}

public extension EngineError {
    /// Optional typed context for UI and diagnostics. The original EngineError remains intact.
    var classification: EngineFailureClassification? {
        switch self {
        case .notConfigured:
            return .connection
        case .http(let code):
            return Self.classification(for: code, detail: "")
        case .httpDetail(let code, let detail, _):
            return Self.classification(for: code, detail: detail)
        }
    }

    var userFacingFailureDescription: String {
        guard classification == .unsupportedModelArchitecture else {
            return Self.redacted(errorDescription ?? "The engine request failed.")
        }
        return
            "The engine cannot load this model architecture. Check the checkpoint type and the engine’s supported architectures, then refresh models."
    }

    private static func redacted(_ text: String) -> String {
        let bounded = String(text.prefix(300))
        let patterns = [#"https?://[^\s)]+"#, #"/(?:Users|private|var|tmp|Volumes)/[^\s)]+"#]
        return patterns.reduce(bounded) { value, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            return regex.stringByReplacingMatches(in: value, range: range, withTemplate: "[redacted]")
        }
    }

    private static func classification(for statusCode: Int, detail: String) -> EngineFailureClassification? {
        let lower = detail.lowercased()
        if statusCode == 409,
            lower.contains("glm_moe_dsa_mtp"),
            lower.contains("not supported")
        {
            return .unsupportedModelArchitecture
        }
        switch statusCode {
        case 401, 403: return .authentication
        case 404: return .modelUnavailable
        case 400: return .malformedResponse
        case 408, 429, 500...599: return .connection
        default: return .unknown
        }
    }
}
