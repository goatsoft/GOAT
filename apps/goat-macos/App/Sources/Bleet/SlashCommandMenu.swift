import GOATed
import SwiftUI

enum ComposerCommand: String, CaseIterable, Hashable {
    case handoff
    case newChat
    case regenerate
    case remember
    case model
    case effort
    case activity

    var slashName: String {
        switch self {
        case .newChat: "new"
        default: rawValue
        }
    }

    var title: String {
        switch self {
        case .handoff: "Handoff"
        case .newChat: "New chat"
        case .regenerate: "Regenerate"
        case .remember: "Remember last answer"
        case .model: "Model"
        case .effort: "Effort"
        case .activity: "Log"
        }
    }

    var description: String {
        switch self {
        case .handoff: "Update memory and prepare a Markdown handover"
        case .newChat: "Start a fresh chat"
        case .regenerate: "Regenerate the latest assistant response"
        case .remember: "Save the latest assistant response to active memory"
        case .model: "Choose the model for this chat"
        case .effort: "Choose how hard GOAT should think"
        case .activity: "Show or hide the log"
        }
    }

    var symbol: String {
        switch self {
        case .handoff: "arrowshape.turn.up.right.fill"
        case .newChat: "square.and.pencil"
        case .regenerate: "arrow.clockwise"
        case .remember: "brain"
        case .model: "cpu"
        case .effort: "gauge.with.dots.needle.67percent"
        case .activity: "terminal"
        }
    }
}

enum ComposerSlashSelection {
    static func moved(from current: Int, by offset: Int, itemCount: Int) -> Int? {
        guard itemCount > 0 else { return nil }
        let candidate = (current + offset) % itemCount
        return candidate >= 0 ? candidate : candidate + itemCount
    }
}

enum ComposerSlashAction: Hashable {
    case command(ComposerCommand)
    case skill(String)
}

struct ComposerSlashItem: Identifiable, Hashable {
    let action: ComposerSlashAction
    let title: String
    let description: String
    let symbol: String
    let source: String?

    var id: ComposerSlashAction { action }

    static func command(_ command: ComposerCommand) -> Self {
        Self(
            action: .command(command),
            title: command.title,
            description: command.description,
            symbol: command.symbol,
            source: nil)
    }

    static func skill(_ skill: SkillSummary) -> Self {
        Self(
            action: .skill(skill.name),
            title: skill.name.split(separator: "-").map { $0.capitalized }.joined(separator: " "),
            description: skill.description,
            symbol: "shippingbox",
            source: skill.source.displayName)
    }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let needle = query.lowercased()
        return title.lowercased().contains(needle)
            || description.lowercased().contains(needle)
            || source?.lowercased().contains(needle) == true
            || slashName.contains(needle)
    }

    private var slashName: String {
        switch action {
        case .command(let command): command.slashName
        case .skill(let name): name
        }
    }
}

struct ComposerSlashMenu: View {
    let commands: [ComposerSlashItem]
    let skills: [ComposerSlashItem]
    let issueCount: Int
    @Binding var selectedIndex: Int
    let onSelect: (ComposerSlashItem) -> Void
    @Environment(AppModel.self) private var model
    @State private var hoveredItemID: ComposerSlashAction?

    private var items: [ComposerSlashItem] { commands + skills }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if commands.isEmpty, skills.isEmpty {
                        Label("No skills are available to this chat", systemImage: "shippingbox")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                    if !commands.isEmpty {
                        sectionLabel("Commands")
                        ForEach(Array(commands.enumerated()), id: \.element.id) { index, item in
                            row(
                                item,
                                selected: selectedIndex == index || hoveredItemID == item.id
                            )
                            .id(item.id)
                            .onHover { hovering in
                                updateHover(item.id, hovering: hovering)
                            }
                        }
                    }
                    if !skills.isEmpty {
                        if !commands.isEmpty { Divider().padding(.vertical, 5) }
                        sectionLabel("Skills")
                        ForEach(Array(skills.enumerated()), id: \.element.id) { offset, item in
                            let index = commands.count + offset
                            row(
                                item,
                                selected: selectedIndex == index || hoveredItemID == item.id
                            )
                            .id(item.id)
                            .onHover { hovering in
                                updateHover(item.id, hovering: hovering)
                            }
                        }
                    }
                    if issueCount > 0 {
                        Divider().padding(.vertical, 5)
                        Label(
                            "\(issueCount) skill \(issueCount == 1 ? "issue" : "issues") excluded",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 9)
                        .padding(.bottom, 5)
                        .help("Conflicting or invalid skills fail closed. Check the Global and Pen skill folders.")
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.hidden)
            .onChange(of: selectedIndex) {
                hoveredItemID = nil
                guard items.indices.contains(selectedIndex) else { return }
                proxy.scrollTo(items[selectedIndex].id, anchor: .center)
            }
        }
        .frame(maxHeight: 390)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(model.theme.tokens.tint.opacity(0.22), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.3), radius: 22, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commands and skills")
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
    }

    private func row(_ item: ComposerSlashItem, selected: Bool) -> some View {
        Button {
            onSelect(item)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: item.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? model.theme.tokens.tint : .secondary)
                    .frame(width: 22)
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(item.description)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let source = item.source {
                    Text(source)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else {
                    Text("/\(commandName(item))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Color.primary.opacity(0.09) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func commandName(_ item: ComposerSlashItem) -> String {
        guard case .command(let command) = item.action else { return "" }
        return command.slashName
    }

    private func updateHover(_ id: ComposerSlashAction, hovering: Bool) {
        if hovering {
            hoveredItemID = id
        } else if hoveredItemID == id {
            hoveredItemID = nil
        }
    }
}
