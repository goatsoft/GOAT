import AppKit
import Bleet
import Caprine
import Persistence
import SwiftUI

struct ResponseDetailsView: View {
    let message: ChatMessage
    @Environment(\.dismiss) private var dismiss

    static func hasUsefulDetails(_ message: ChatMessage) -> Bool {
        message.generationProvenance != nil || message.generationProvenanceUnavailable
    }

    var body: some View {
        GOATDialogShell(closeAction: { dismiss() }) {
            Form {
                if let provenance = message.generationProvenance {
                    ForEach(ResponseDetailSection.sections(provenance)) { section in
                        Section(section.title) {
                            ForEach(section.rows) { row in
                                LabeledContent(row.title, value: row.value)
                            }
                        }
                    }
                    Section("Diagnostic report") {
                        let report = ModelDiagnosticReportBuilder.build(from: provenance)
                        Text(report)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Copy Report", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(report, forType: .string)
                        }
                    }
                } else if message.generationProvenanceUnavailable {
                    Section {
                        Label("Saved response details could not be decoded.", systemImage: "exclamationmark.triangle")
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 480, minHeight: 220)
        }
    }
}

struct ResponseDetailSection: Identifiable {
    struct Row: Identifiable {
        let title: String
        let value: String
        var id: String { title }
    }
    let title: String
    let rows: [Row]
    var id: String { title }

    static func sections(_ value: GenerationProvenanceRecord) -> [Self] {
        let sampling = value.samplingValues?.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        let definitions: [(String, [(String, String?)])] = [
            (
                "Identity",
                [
                    ("Model", value.requestedModelID), ("Response model", value.responseModelID),
                    ("Engine", value.engineDisplayName),
                ]
            ),
            (
                "Request",
                [
                    ("Style", value.resolvedRequestStyle), ("Resolution", value.resolutionSource),
                    ("Effort", value.selectedEffort),
                    (
                        "Requested temperature",
                        value.actualTemperature.map { String(format: "%.3f", $0) } ?? "Engine default"
                    ),
                    ("Requested sampling", sampling), ("Sampling source", value.samplingSource),
                    ("Family rule", value.familyRuleID), ("Output token cap", String(value.effectiveOutputTokenCap)),
                    ("Reasoning instruction", value.reasoningInstruction),
                    ("Native reasoning", value.nativeReasoningValue),
                ]
            ),
            (
                "Outcome",
                [
                    ("Lifecycle", value.lifecycle.rawValue), ("Finish reason", value.finishReason),
                    ("Failure", value.failureCategory?.rawValue),
                ]
            ),
        ]
        return definitions.compactMap { title, fields in
            let rows = fields.compactMap { label, raw -> Row? in
                guard let raw else { return nil }
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, !["unknown", "none"].contains(text.lowercased()) else { return nil }
                return Row(title: label, value: text)
            }
            return rows.isEmpty ? nil : Self(title: title, rows: rows)
        }
    }
}
