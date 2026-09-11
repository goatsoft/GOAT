import AppKit
import Caprine
import Inference
import SwiftUI

struct ModelDetailView: View {
    @Environment(AppModel.self) private var model
    let identity: ModelIdentity
    let modelRef: ModelRef?

    private var preference: ModelPreference? {
        model.modelPreferences.first { $0.identity == identity }
    }

    private var snapshot: ModelInspectionSnapshot? {
        model.modelInspectionStates[identity]?.snapshot
    }

    private var review: LegacyCompatibilityReview? {
        model.legacyCompatibilityReviews.first {
            $0.engineProfileID == identity.engineProfileID && $0.state == .pending
        }
    }

    private var canUseInChat: Bool {
        modelRef != nil && !model.shepherd.hasActiveTurn && !model.engineTransitioning && review == nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Caprine.Models.sectionSpacing) {
                titleSection
                availabilitySection
                if let modelRef {
                    capabilitiesSection(modelRef)
                    metadataSection(snapshot: snapshot, model: modelRef)
                }
                ModelCompatibilitySection(identity: identity, review: review)
                diagnosticsSection
            }
            .padding(Caprine.Models.inset)
        }
        .frame(minWidth: Caprine.Models.detailMinWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: identity) { await model.inspectModel(identity) }
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(modelRef?.displayName ?? identity.modelID)
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    Task { _ = await model.setModelFavourite(!(preference?.isFavourite ?? false), for: identity) }
                } label: {
                    Image(systemName: preference?.isFavourite == true ? "star.fill" : "star")
                }
                .buttonStyle(.borderless)
            }
            Text(identity.modelID)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Use in Chat") { model.selectModel(identity.modelID) }
                    .disabled(!canUseInChat)
                if !canUseInChat {
                    Text(review != nil ? "Resolve compatibility migration first" : "Unavailable during an active turn or engine change")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var availabilitySection: some View {
        SectionCard(title: "Availability", systemImage: "antenna.radiowaves.left.and.right") {
            LabeledContent("Engine", value: model.activeEngineProfile?.name ?? "No engine configured")
            if modelRef == nil {
                Text("This favourite is not in the current engine catalog.")
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Status", value: model.health.isOK ? "Available" : "Engine offline")
            }
            if let snapshot {
                HStack {
                    Text("Last checked")
                    Spacer()
                    Text(snapshot.fetchedAt, style: .relative).foregroundStyle(.secondary)
                    if snapshot.freshness() == .stale { Text("Stale").foregroundStyle(.orange) }
                }
            } else {
                Text("Not checked yet").foregroundStyle(.secondary)
            }
            Button("Refresh Details") { Task { await model.inspectModel(identity) } }
                .disabled(modelRef == nil || model.engineTransitioning || model.shepherd.hasActiveTurn)
        }
    }

    private func capabilitiesSection(_ ref: ModelRef) -> some View {
        SectionCard(title: "Capabilities", systemImage: "checklist") {
            capabilityRow("Tools", claim: ref.capabilities.tools)
            capabilityRow("Vision", claim: ref.capabilities.vision)
            capabilityRow("Reasoning", claim: ref.capabilities.reasoning)
            capabilityRow("Reasoning history", claim: ref.capabilities.reasoningHistory)
        }
    }

    private func capabilityRow(_ title: String, claim: CapabilityClaim) -> some View {
        LabeledContent(title) {
            HStack(spacing: 5) {
                Image(systemName: claim.support == .supported ? "checkmark.circle.fill" : claim.support == .unsupported ? "xmark.circle" : "questionmark.circle")
                Text(claim.support == .supported ? "Supported" : claim.support == .unsupported ? "Unsupported" : "Unknown")
                if !claim.evidence.isEmpty { Text(claim.evidence.map(\.rawValue).sorted().joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary) }
            }
            .foregroundStyle(claim.support == .supported ? .green : claim.support == .unsupported ? .secondary : .orange)
        }
    }

    private func metadataSection(snapshot: ModelInspectionSnapshot?, model ref: ModelRef) -> some View {
        SectionCard(title: "Reported model details", systemImage: "info.circle") {
            detail("Context", value: ref.contextLength.map { "\($0) tokens" })
            detail("Format", value: snapshot?.format)
            detail("Quantization", value: snapshot?.quantization)
            detail("Architecture", value: snapshot?.architecture)
            detail("Checkpoint", value: snapshot?.checkpointRole == .unknown ? nil : snapshot?.checkpointRole.rawValue)
            detail("Weight size", value: formattedByteCount(snapshot?.weightBytes))
        }
    }

    private func formattedByteCount(_ bytes: Int64?) -> String? {
        guard let bytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func detail(_ label: String, value: String?) -> some View {
        LabeledContent(label, value: value ?? "Not reported")
    }

    private var diagnosticsSection: some View {
        SectionCard(title: "Diagnostics", systemImage: "stethoscope") {
            Text("Capability evidence is shown conservatively. Name-based hints never become a Supported claim.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Copy Model Report") {
                let report = "Model: \(identity.modelID)\nEngine: \(model.activeEngineProfile?.name ?? "Not configured")\nStatus: \(modelRef == nil ? "Unavailable" : "Available")"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
            }
        }
    }
}

private struct SectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Caprine.Models.spacing) {
            Label(title, systemImage: systemImage).font(.headline)
            content
        }
        .padding(Caprine.Models.inset)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Caprine.Models.cornerRadius))
    }
}
