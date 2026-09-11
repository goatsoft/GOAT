import Foundation
import Persistence

enum ModelDiagnosticReportBuilder {
    static func build(from provenance: GenerationProvenanceRecord?) -> String {
        guard let provenance else { return "Provenance unavailable for this response." }
        var lines = [
            "GOAT model diagnostic",
            "Model: \(provenance.requestedModelID)",
            "Response model: \(provenance.responseModelID ?? "Unknown")",
            "Request style: \(provenance.resolvedRequestStyle)",
            "Resolution source: \(provenance.resolutionSource)",
            "Effort: \(provenance.selectedEffort)",
            String(format: "Temperature: %.3f", provenance.actualTemperature),
            "Output token cap: \(provenance.effectiveOutputTokenCap)",
            "Native reasoning value: \(provenance.nativeReasoningValue ?? "Unknown")",
            "Reasoning history replayed: \(provenance.reasoningHistoryReplayed ? "Yes" : "No")",
            "Lifecycle: \(provenance.lifecycle.rawValue)",
            "Finish reason: \(provenance.finishReason ?? "Unknown")"
        ]
        if let adapter = provenance.adapterIdentifier { lines.append("Adapter: \(adapter)") }
        if let category = provenance.failureCategory {
            lines.append("Failure category: \(category.rawValue)")
        }
        return lines.joined(separator: "\n")
    }
}
