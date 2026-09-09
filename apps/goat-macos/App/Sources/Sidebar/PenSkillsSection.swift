import AppKit
import SwiftUI

/// Pen-scoped skills are managed from the Pen itself. Global skill management stays in Settings,
/// so neither surface needs a scope picker.
struct PenSkillsSection: View {
    let penID: UUID
    let penFolder: URL?
    let tint: Color

    @State private var snapshot = SkillManagementSnapshot()
    @State private var isRefreshing = false
    @State private var pendingRemoval: ManagedSkill?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Skills", systemImage: "shippingbox")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Button("Add Skill…", systemImage: "plus") { chooseSkillFolder() }
                    .buttonStyle(SecondaryChipButtonStyle())
                    .font(.caption)
                    .disabled(root == nil)
                Button("Open Folder", systemImage: "folder") { openFolder() }
                    .buttonStyle(SecondaryChipButtonStyle())
                    .font(.caption)
                    .disabled(root == nil)
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(SecondaryChipButtonStyle())
                .help("Refresh Pen skills")
                .disabled(root == nil || isRefreshing)
            }

            Text("Skills added here are available only to chats in this Pen.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if isRefreshing {
                GoatLoadingIndicator().controlSize(.small).padding(.vertical, 6)
            } else if root == nil {
                Text("GOAT could not locate this Pen’s skills folder.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.vertical, 6)
            } else if snapshot.skills.isEmpty {
                Text("No Pen skills added yet.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            } else {
                ForEach(snapshot.skills) { skill in
                    skillRow(skill)
                }
            }

            ForEach(Array(snapshot.issues.enumerated()), id: \.offset) { _, issue in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.source).font(.caption.weight(.medium))
                        Text(issue.message).font(.caption2).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .task(id: penFolder?.path) { await refresh() }
        .confirmationDialog(
            "Remove \(pendingRemoval?.name ?? "skill")?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Skill", role: .destructive) {
                guard let skill = pendingRemoval else { return }
                pendingRemoval = nil
                Task { await remove(skill) }
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("This deletes the skill from this Pen. Global and built-in skills are unchanged.")
        }
        .alert("Pen Skills", isPresented: errorPresented) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    private var root: SkillManagementRoot? {
        guard let penFolder else { return nil }
        let url = penFolder.appendingPathComponent("skills", isDirectory: true)
        return SkillManagementRoot(
            id: "pen:\(penID.uuidString)", label: "Pen", root: url,
            source: .pen(penID), isLocked: false)
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })
    }

    private func skillRow(_ skill: ManagedSkill) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(skill.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            Button(role: .destructive) {
                pendingRemoval = skill
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(SecondaryChipButtonStyle())
            .help("Remove \(skill.name) from this Pen")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.25)))
    }

    private func refresh() async {
        guard let root else {
            snapshot = SkillManagementSnapshot()
            isRefreshing = false
            return
        }
        isRefreshing = true
        let refreshed = await GOATedSkillFileWorker.shared.snapshot(roots: [root])
        guard !Task.isCancelled, self.root?.root == root.root else { return }
        snapshot = refreshed
        isRefreshing = false
    }

    private func chooseSkillFolder() {
        guard let root else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a Skill Folder"
        panel.message = "Select one folder containing a valid SKILL.md to add to this Pen."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        GOATFileSelector.present(panel) { response in
            guard response == .OK, let source = panel.url else { return }
            Task {
                let hasAccess = source.startAccessingSecurityScopedResource()
                defer { if hasAccess { source.stopAccessingSecurityScopedResource() } }
                do {
                    try await GOATedSkillFileWorker.shared.install(from: source, into: root)
                    await refresh()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func openFolder() {
        guard let root else { return }
        Task {
            do {
                try await GOATedSkillFileWorker.shared.ensureRoot(root)
                NSWorkspace.shared.open(root.root)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func remove(_ skill: ManagedSkill) async {
        guard let root else { return }
        do {
            try await GOATedSkillFileWorker.shared.remove(named: skill.name, from: root)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
