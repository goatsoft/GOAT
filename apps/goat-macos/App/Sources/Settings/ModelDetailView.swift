import AppKit
import Caprine
import Inference
import SwiftUI

struct ModelDetailView: View {
    @Environment(AppModel.self) private var model
    let identity: ModelIdentity
    let modelRef: ModelRef?
    var onClear: (() -> Void)? = nil
    @State private var contextOverrideText = ""
    @FocusState private var budgetFocused: Bool

    private var preference: ModelPreference? {
        model.modelPreferences.first { $0.identity == identity }
    }

    private var snapshot: ModelInspectionSnapshot? {
        model.modelInspectionStates[identity]?.snapshot
    }

    private var canUseInChat: Bool {
        modelRef != nil && !model.shepherd.hasActiveTurn && !model.engineTransitioning
    }

    private var isCurrentChatModel: Bool {
        model.resolvedModelID(for: model.currentSession) == identity.modelID
    }

    private var currentPill: some View {
        Text("Current")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Caprine.Models.sectionSpacing) {
                    titleSection
                    availabilitySection
                    if let modelRef {
                        capabilitiesSection(modelRef)
                        metadataSection(snapshot: snapshot, model: modelRef)
                    }
                    diagnosticsSection
                }
                .padding(Caprine.Models.inset)
                .contentShape(Rectangle())
                .onTapGesture { budgetFocused = false }
                .id("model-detail-top")
            }
            .frame(
                minWidth: Caprine.Models.detailMinWidth, maxWidth: .infinity, maxHeight: .infinity,
                alignment: .topLeading
            )
            .onChange(of: identity) { _, _ in
                withAnimation(.none) {
                    proxy.scrollTo("model-detail-top", anchor: .top)
                }
            }
            .task(id: identity) { await model.inspectModel(identity) }
        }
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
                    let isFavourite = preference?.isFavourite == true
                    Image(systemName: isFavourite ? "star.fill" : "star")
                        .font(.title2)
                        .frame(width: 24, height: 24)
                        .foregroundStyle(isFavourite ? Color.yellow : Color.white)
                }
                .buttonStyle(.plain)
                .help(preference?.isFavourite == true ? "Remove from favourites" : "Add to favourites")
                if let onClear {
                    Button {
                        onClear()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title2)
                            .frame(width: 24, height: 24)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear selection")
                }
            }
            Text(identity.modelID)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if isCurrentChatModel {
                    currentPill
                } else {
                    Button("Use in Chat") { model.selectModel(identity.modelID) }
                        .disabled(!canUseInChat)
                        .buttonStyle(SecondaryChipButtonStyle())
                    if !canUseInChat {
                        Text("Unavailable during an active turn or engine change")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var availabilitySection: some View {
        SectionCard(title: "Availability", systemImage: "antenna.radiowaves.left.and.right") {
            textRow("Engine", model.activeEngineProfile?.name ?? "No engine configured")
            if modelRef == nil {
                DetailRow("Status") {
                    Text("Not in the current engine catalog").foregroundStyle(.secondary)
                }
            } else {
                textRow("Status", model.health.isOK ? "Available" : "Engine offline")
            }
            DetailRow("Last checked") {
                if let snapshot {
                    HStack(spacing: 6) {
                        Text(snapshot.fetchedAt, style: .relative)
                        if snapshot.freshness() == .stale {
                            Text("Stale").foregroundStyle(.orange)
                        }
                    }
                } else {
                    Text("Not checked yet").foregroundStyle(.secondary)
                }
            }
            Button("Refresh Details") { Task { await model.inspectModel(identity) } }
                .disabled(modelRef == nil || model.engineTransitioning || model.shepherd.hasActiveTurn)
                .buttonStyle(SecondaryChipButtonStyle())
                .padding(.top, 2)
        }
    }

    private func capabilitiesSection(_ ref: ModelRef) -> some View {
        SectionCard(title: "Capabilities", systemImage: "checklist") {
            if ref.capabilities.hasConflict {
                Label(
                    "Engine metadata conflicts with family knowledge. Conflicting capabilities remain unverified.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            capabilityRow("Tools", claim: ref.capabilities.tools)
            capabilityRow("Vision", claim: ref.capabilities.vision)
            capabilityRow("Reasoning", claim: ref.capabilities.reasoning)
            capabilityRow("Reasoning history", claim: ref.capabilities.reasoningHistory)
        }
    }

    private func capabilityRow(_ title: String, claim: CapabilityClaim) -> some View {
        DetailRow(title) {
            HStack(spacing: 5) {
                Image(
                    systemName: claim.isConflict
                        ? "exclamationmark.triangle.fill"
                        : claim.support == .supported
                            ? "checkmark.circle.fill"
                            : claim.support == .unsupported ? "xmark.circle" : "questionmark.circle")
                Text(
                    claim.isConflict
                        ? "Conflict"
                        : claim.support == .supported
                            ? "Supported"
                            : claim.support == .unsupported ? "Unsupported" : "Unknown")
                if !claim.evidence.isEmpty {
                    Text(claim.evidence.map(\.rawValue).sorted().joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(
                claim.isConflict
                    ? .red
                    : claim.support == .supported
                        ? .green : claim.support == .unsupported ? .secondary : .orange
            )
        }
    }

    private func metadataSection(snapshot: ModelInspectionSnapshot?, model ref: ModelRef) -> some View {
        SectionCard(title: "Reported model details", systemImage: "info.circle") {
            textRow("Context", ref.contextLength.map { "\($0.formatted()) tokens" })
            budgetRow(reported: ref.contextLength)
            textRow("Format", snapshot?.format)
            textRow("Quantization", snapshot?.quantization)
            textRow("Architecture", snapshot?.architecture)
            textRow(
                "Checkpoint",
                snapshot?.checkpointRole == .unknown ? nil : snapshot?.checkpointRole.rawValue)
            textRow("Weight size", formattedByteCount(snapshot?.weightBytes))
        }
        .onAppear { contextOverrideText = preference?.contextWindowOverride.map { $0.formatted() } ?? "" }
        .onChange(of: identity) { _, _ in
            contextOverrideText = preference?.contextWindowOverride.map { $0.formatted() } ?? ""
        }
    }

    /// The budget window GOAT plans against. A value fills a missing engine window or lowers a
    /// reported one; it never raises what the engine reports (ADR-0085).
    private func budgetRow(reported: Int?) -> some View {
        DetailRow("Budget window") {
            HStack(spacing: 6) {
                EditableValueField(
                    text: $contextOverrideText,
                    placeholder: (reported ?? PromptBudgeter.fallbackWindowTokens).formatted(),
                    format: { raw in
                        let digits = raw.filter(\.isNumber)
                        return digits.isEmpty ? "" : (Int(digits).map { $0.formatted() } ?? digits)
                    },
                    focused: $budgetFocused,
                    onCommit: commitContextOverride
                )
                Text("tokens").foregroundStyle(.secondary)
                Button {
                    contextOverrideText = ""
                    Task { _ = await model.setContextWindowOverride(nil, for: identity) }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(SecondaryChipButtonStyle())
                .help("Reset to the engine-reported window")
                .disabled(preference?.contextWindowOverride == nil && contextOverrideText.isEmpty)
            }
        }
    }

    private func commitContextOverride() {
        let digits = contextOverrideText.filter(\.isNumber)
        if digits.isEmpty {
            Task { _ = await model.setContextWindowOverride(nil, for: identity) }
        } else if let value = Int(digits) {
            Task { _ = await model.setContextWindowOverride(value, for: identity) }
        }
    }

    private func formattedByteCount(_ bytes: Int64?) -> String? {
        guard let bytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func textRow(_ label: String, _ value: String?) -> some View {
        DetailRow(label) {
            Text(value ?? "Not reported")
                .foregroundStyle(value == nil ? Color.secondary : Color.primary)
        }
    }

    private var diagnosticsSection: some View {
        SectionCard(title: "Diagnostics", systemImage: "stethoscope") {
            Text("Capability evidence is shown conservatively. Name-based hints never become a Supported claim.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Copy Model Report") {
                let report =
                    "Model: \(identity.modelID)\nEngine: \(model.activeEngineProfile?.name ?? "Not configured")\nStatus: \(modelRef == nil ? "Unavailable" : "Available")"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
            }
            .buttonStyle(SecondaryChipButtonStyle())
        }
    }
}

/// A reusable editable value field. Its two-way `@Binding` keeps the field text and the owning
/// view's state in sync (SwiftUI `Binding`), so it can back any label/value row whose value the
/// user edits. Commits on Return.
struct EditableValueField: View {
    @Binding var text: String
    let placeholder: String
    var format: ((String) -> String)? = nil
    var focused: FocusState<Bool>.Binding
    let onCommit: () -> Void
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 96)
            .focused(focused)
            // Return unfocuses; losing focus reformats the value as the visible commit indication.
            .onSubmit { focused.wrappedValue = false }
            .onChange(of: text) { _, _ in
                // Save shortly after typing stops (without reformatting, which would move the caret
                // mid-edit) so a value persists even if the field is never explicitly unfocused.
                saveTask?.cancel()
                saveTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(700))
                    guard !Task.isCancelled else { return }
                    onCommit()
                }
            }
            .onChange(of: focused.wrappedValue) { _, isFocused in
                // Losing focus reformats the value (the visible commit indication) and saves.
                guard !isFocused else { return }
                saveTask?.cancel()
                if let format { text = format(text) }
                onCommit()
            }
            .onDisappear { saveTask?.cancel() }
    }
}

/// A reusable label/value row for a details panel. The label sits in a fixed-width leading column
/// so values line up in one shared column across every panel, and the value can be static text or
/// an editable control. Prose-style panels (Diagnostics) do not use this.
struct DetailRow<Value: View>: View {
    static var labelColumnWidth: CGFloat { 150 }
    let label: String
    @ViewBuilder var value: Value

    init(_ label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: Self.labelColumnWidth, alignment: .leading)
            value
            Spacer(minLength: 0)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Caprine.Models.cornerRadius))
    }
}
