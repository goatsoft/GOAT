import AppKit
import Bleet
import Persistence
import SwiftUI

struct ResponseDetailsView: View {
    let message: ChatMessage
    @Environment(\.dismiss) private var dismiss

    private var report: String {
        ModelDiagnosticReportBuilder.build(from: message.generationProvenance)
    }

    var body: some View {
        GOATDialogShell(closeAction: { dismiss() }) {
            Form {
                Section("Identity") {
                    LabeledContent("Model", value: message.generationProvenance?.requestedModelID ?? "Unknown")
                    LabeledContent("Response model", value: message.generationProvenance?.responseModelID ?? "Unknown")
                }
                Section("Request") {
                    LabeledContent("Style", value: message.generationProvenance?.resolvedRequestStyle ?? "Unknown")
                    LabeledContent("Resolution", value: message.generationProvenance?.resolutionSource ?? "Unknown")
                    LabeledContent("Effort", value: message.generationProvenance?.selectedEffort ?? "Unknown")
                    LabeledContent("Temperature", value: message.generationProvenance.map {
                        String(format: "%.3f", $0.actualTemperature)
                    } ?? "Unknown")
                }
                Section("Outcome") {
                    LabeledContent("Lifecycle", value: message.generationProvenance?.lifecycle.rawValue ?? "Unknown")
                    LabeledContent("Finish reason", value: message.generationProvenance?.finishReason ?? message.stats?.finishReason ?? "Unknown")
                    if message.generationProvenanceUnavailable {
                        Label("Saved provenance could not be decoded.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Diagnostic report") {
                    Text(report)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Copy Report", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType: .string)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 480, minHeight: 420)
        }
    }
}
