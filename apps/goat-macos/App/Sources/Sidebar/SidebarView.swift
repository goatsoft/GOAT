import Bleet
import Caprine
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""

    private var searchQuery: String {
        filter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isFiltering: Bool { !searchQuery.isEmpty }

    var body: some View {
        @Bindable var model = model
        let groups = sidebarGroups()
        // SwiftUI List bridges to NSTableView and was producing a reentrant-delegate warning as
        // progressive startup published rows. A lazy stack keeps the same bounded row creation
        // without the AppKit delegate bridge.
        // Keep navigation and the footer outside the clipped scroll viewport. Transparent
        // safe-area insets let rows overlap fixed controls during scrolling and startup.
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                SidebarSearchField(text: $filter, prompt: "Search chats")
                    .padding(.horizontal, 4)
                    .padding(.bottom, 6)
                SidebarNavigationRow(title: "New chat", symbol: "square.and.pencil") {
                    filter = ""
                    Task { await model.beginNewChat() }
                }
                .help("New chat (⌘N)")
                SidebarNavigationRow(
                    title: "Pens", symbol: "folder.badge.gearshape", selected: model.showingPensHome
                ) {
                    model.openPensHome()
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    SidebarSectionHeader(
                        title: isFiltering ? "Your Pens (filtered)" : "Your Pens",
                        help: "New pen (⇧⌘N)"
                    ) {
                        model.showNewPenSheet = true
                    }
                    ForEach(model.pens) { pen in
                        PenHeaderRow(pen: pen)
                        if pen.isExpanded {
                            let chats = groups.penChats[pen.id] ?? []
                            if chats.isEmpty {
                                SidebarEmptyRow(text: "No chats yet", indented: true)
                            } else {
                                ForEach(chats) { chat in
                                    ChatRow(chat: chat, penColor: Color(pen.color))
                                }
                            }
                        }
                    }
                    if model.pens.isEmpty {
                        SidebarEmptyRow(text: "No pens yet")
                    }

                    if !groups.pinned.isEmpty {
                        SidebarTextHeader(title: "Pinned")
                        ForEach(groups.pinned) { chat in
                            ChatRow(chat: chat, penColor: penColor(for: chat))
                        }
                    }

                    SidebarSectionHeader(
                        title: isFiltering ? "Chats (filtered)" : "Chats",
                        help: "New global chat"
                    ) {
                        Task { await model.newChat() }
                    }
                    ForEach(groups.loose) { chat in
                        ChatRow(chat: chat)
                    }
                }
                .padding(.vertical, 6)
            }
            .tint(model.theme.tokens.tint)
            .clipped()
            VStack(spacing: 0) {
                Divider()
                    .opacity(0.35)
                    .padding(.horizontal, 12)
                EngineStatusBar()
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: model.selectedChatID) { _, _ in
            if let chat = model.currentSession, chat.hasDefaultTitle, chat.messages.isEmpty { filter = "" }
        }
        .onChange(of: model.penComposerFocusID) { _, id in
            if id != nil { filter = "" }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 300, max: 320)
        .opacity(model.startupPhase.hasLocalState ? 1 : 0)
        .allowsHitTesting(model.startupPhase.hasLocalState)
        .overlay {
            if !model.startupPhase.hasLocalState {
                VStack(spacing: 10) {
                    if case .failed = model.startupPhase {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                            .foregroundStyle(.orange)
                    } else {
                        GoatLoadingIndicator().controlSize(.small)
                    }
                    Text(model.startupPhase.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
        }
    }

    private struct Groups {
        var pinned: [ChatSession] = []
        var loose: [ChatSession] = []
        var penChats: [UUID: [ChatSession]] = [:]
    }

    /// One O(chats + pens) grouping pass per sidebar publication. The old computed properties
    /// rescanned the complete chat array once for every expanded Pen.
    private func sidebarGroups() -> Groups {
        let penIDs = Set(model.pens.map(\.id))
        var groups = Groups()
        for chat in model.chats {
            guard !isFiltering || chat.title.localizedCaseInsensitiveContains(searchQuery) else {
                continue
            }
            if chat.pinned {
                groups.pinned.append(chat)
            } else if let penID = chat.projectID, penIDs.contains(penID) {
                groups.penChats[penID, default: []].append(chat)
            } else {
                groups.loose.append(chat)
            }
        }
        return groups
    }

    /// Pins change placement, never ownership. Preserve the Pen colour when a Pen chat is
    /// surfaced in the Pinned section so its origin remains visible.
    private func penColor(for chat: ChatSession) -> Color? {
        guard let penID = chat.projectID, let pen = model.pens.first(where: { $0.id == penID }) else {
            return nil
        }
        return Color(pen.color)
    }
}

// MARK: - Section header (title + roomy plus)

private struct SidebarNavigationRow: View {
    let title: String
    let symbol: String
    var selected = false
    let action: () -> Void
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(model.theme.tokens.tint)
                    .frame(width: 18)
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(model.theme.tokens.ink)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        selected
                            ? model.theme.tokens.tint.opacity(0.18)
                            : model.theme.tokens.surface.opacity(hovering ? 0.7 : 0))
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct SidebarSectionHeader: View {
    let title: String
    let help: String
    let action: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: action) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(help)
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

private struct SidebarTextHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 5)
    }
}

private struct SidebarEmptyRow: View {
    let text: String
    var indented = false

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.leading, indented ? 34 : 16)
            .padding(.vertical, 5)
    }
}

// MARK: - Pen header (a colour pill with the disclosure arrow inside)

private struct PenHeaderRow: View {
    @Bindable var pen: Pen
    @Environment(AppModel.self) private var model
    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var renameDraft = ""

    private var selected: Bool { pen.id == model.selectedPenID }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { pen.isExpanded.toggle() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(pen.isExpanded ? 90 : 0))
                    .foregroundStyle(Color(pen.color))
                    .frame(width: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(pen.emoji)
            if isRenaming {
                InlineRenameField(
                    text: $renameDraft,
                    onCommit: commitRename,
                    onCancel: { isRenaming = false }
                )
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(model.theme.tokens.surface, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(pen.color)))
            } else {
                Text(pen.name)
                    .lineLimit(1)
                    .fontWeight(selected ? .semibold : .medium)
            }
            Spacer(minLength: 4)
            Button {
                model.beginNewChat(in: pen)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(pen.color))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New chat in \(pen.name)")
            .opacity(isHovering ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)  // spans the full row, like a chat row
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(pen.color).opacity(selected ? 0.28 : 0.15)))
        .overlay(
            RoundedRectangle(cornerRadius: 7).strokeBorder(
                Color(pen.color).opacity(selected ? 0.65 : 0.32), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onHover { isHovering = $0 }
        .onTapGesture { if !isRenaming { model.openPen(pen) } }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
            Task { await model.move(chatID: id, to: pen) }
            return true
        }
        .contextMenu {
            Button("Open Pen") { model.openPen(pen) }
            Button("New Chat in \(pen.name)") { model.beginNewChat(in: pen) }
            Button("Rename…") {
                renameDraft = pen.name
                isRenaming = true
            }
            Button("Edit…") { model.editingPen = pen }
            Divider()
            Button("Delete Pen", role: .destructive) {
                Task { await model.deletePen(pen) }
            }
        }
    }

    private func commitRename() {
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        isRenaming = false
        guard !name.isEmpty, name != pen.name else { return }
        Task {
            await model.savePen(
                existing: pen, name: name, emoji: pen.emoji,
                instructions: pen.instructions, color: pen.color)
        }
    }

}

// MARK: - Chat row

private struct ChatRow: View {
    let chat: ChatSession
    /// Set when the chat lives in a Pen - draws a colour bullet + indent so the grouping reads.
    var penColor: Color?
    @Environment(AppModel.self) private var model

    private var selected: Bool {
        chat.id == model.selectedChatID && model.selectedPenID == nil && !model.showingPensHome
    }
    private var renaming: Bool { model.renamingChat?.id == chat.id }

    private var isPen: Bool { penColor != nil }
    /// The selected fill: the pen's own colour for pen chats, the theme selection otherwise.
    private var selectionFill: Color { penColor ?? model.theme.tokens.selection }
    private var rowFill: Color {
        if selected { return selectionFill.opacity(isPen ? 0.25 : 0.20) }
        return model.theme.tokens.surface.opacity(isHovering ? 0.7 : 0)
    }
    @State private var isHovering = false

    var body: some View {
        @Bindable var model = model
        return HStack(spacing: 7) {
            if let penColor {
                Circle()
                    .fill(penColor)
                    .frame(width: 6, height: 6)
                    .opacity(selected ? 1 : 0.75)
            }
            if renaming {
                InlineRenameField(
                    text: $model.renameDraft,
                    onCommit: commitRename,
                    onCancel: cancelRename
                )
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(model.theme.tokens.surface, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(model.theme.tokens.tint))
            } else {
                Text(chat.title)
                    .font(.system(size: 13))
                    .foregroundStyle(model.theme.tokens.ink)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if chat.pinned && !chat.isStreaming {
                Button {
                    Task { await model.togglePin(chat) }
                } label: {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(model.theme.tokens.muted)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Unpin chat")
            }
            if chat.isStreaming {
                GoatLoadingIndicator()
                    .controlSize(.small)
                    .frame(width: 20, height: 20)
                    .help("Response in progress")
            } else if !renaming {
                Menu {
                    ChatContextActions(chat: chat, onRename: startRename)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .opacity(isHovering ? 1 : 0)
                .accessibilityLabel("Chat actions")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(rowFill)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        // Double-click the row → rename in place (with text selected); single-click selects.
        .onTapGesture(count: 2) { startRename() }
        .onTapGesture { model.selectedChatID = chat.id }
        .padding(.leading, isPen ? 18 : 8)
        .padding(.trailing, 8)
        .padding(.vertical, 1)
        .draggable(chat.id.uuidString)
        .onHover { isHovering = $0 }
        .contextMenu {
            ChatContextActions(chat: chat, onRename: startRename)
        }
    }

    private func startRename() {
        model.selectedChatID = chat.id
        model.renameDraft = chat.title
        model.renamingChat = chat
    }

    private func commitRename() {
        Task {
            await model.rename(chat, to: model.renameDraft)
            model.renamingChat = nil
        }
    }

    private func cancelRename() {
        model.renamingChat = nil
    }
}

/// One action set for every chat presentation: sidebar rows and the Pen workspace cards.
struct ChatContextActions: View {
    let chat: ChatSession
    let onRename: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Rename…") { onRename() }
        Button(chat.pinned ? "Unpin" : "Pin") { Task { await model.togglePin(chat) } }
        Menu("Change Pen") {
            Button("Remove from Pen") { Task { await model.move(chatID: chat.id, to: nil) } }
            if !model.pens.isEmpty { Divider() }
            ForEach(model.pens.filter { $0.id != chat.projectID }) { pen in
                Button("\(pen.emoji) \(pen.name)") {
                    Task { await model.move(chatID: chat.id, to: pen) }
                }
            }
        }
        Divider()
        Button("Delete", role: .destructive) { Task { await model.delete(chat) } }
    }
}

// MARK: - Engine status bar

struct EngineStatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if model.startupPhase == .connectingServices {
                HStack(spacing: 7) {
                    GoatLoadingIndicator().controlSize(.mini)
                    Text(model.startupPhase.statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let warning = model.dbWarning {
                Text(warning)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            EngineStatusSummary(showSettings: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // No background: the footer sits on the sidebar; the divider above it is enough.
    }

}
