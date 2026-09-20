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
            "Temperature: \(provenance.actualTemperature.map { String(format: "%.3f", $0) } ?? "Engine default")",
            "Sampling source: \(provenance.samplingSource ?? "Unknown")",
            "Family rule: \(provenance.familyRuleID ?? "None")",
            "Requested sampling values: \(provenance.samplingValues?.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ") ?? "Unknown")",
            "Omitted parameters: \(provenance.omittedSamplingParameters?.joined(separator: ", ") ?? "None recorded")",
            "Reasoning instruction: \(provenance.reasoningInstruction ?? "Engine default or native field")",
            "Output token cap: \(provenance.effectiveOutputTokenCap)",
            "Native reasoning value: \(provenance.nativeReasoningValue ?? "Unknown")",
            "Reasoning history replayed: \(provenance.reasoningHistoryReplayed ? "Yes" : "No")",
            "Lifecycle: \(provenance.lifecycle.rawValue)",
            "Finish reason: \(provenance.finishReason ?? "Unknown")",
        ]
        if let adapter = provenance.adapterIdentifier { lines.append("Adapter: \(adapter)") }
        if let category = provenance.failureCategory {
            lines.append("Failure category: \(category.rawValue)")
        }
        lines.removeAll { $0.hasSuffix(": Unknown") || $0.hasSuffix(": None") }
        return lines.joined(separator: "\n")
    }
}
