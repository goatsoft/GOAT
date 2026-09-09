import AppKit
import Bleet
import Caprine
import SwiftUI

private enum PensSort: String, CaseIterable, Identifiable {
    case recent = "Recently active"
    case name = "Name"
    case created = "Newest Pens"
    var id: String { rawValue }
}

enum PenCardMemoryState: String {
    case loading = "Loading"
    case unavailable = "Not ready"
    case off = "Off"
    case paused = "Paused globally"
    case ready = "On"

    static func resolve(
        configuration: MemoryConfigurationLoadState, globalEnabled: Bool, penEnabled: Bool, providerAvailable: Bool
    ) -> Self {
        guard configuration != .loading else { return .loading }
        guard configuration == .ready else { return .unavailable }
        guard penEnabled else { return .off }
        guard globalEnabled else { return .paused }
        return providerAvailable ? .ready : .unavailable
    }
}

/// A local configuration overview. Cards use existing model state, without per-card disk reads
/// or endpoint probes. Counts include pinned chats belonging to the Pen.
struct PensHomeView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var sort = PensSort.recent
    @AppStorage("pens.overview.layout") private var layout = "grid"
    private var tokens: Caprine { model.theme.tokens }

    var body: some View {
        let chats = Dictionary(grouping: model.chats, by: \.projectID)
        let pens = visiblePens(chats: chats)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 16) {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.title).foregroundStyle(tokens.tint)
                        .frame(width: 54, height: 54)
                        .background(tokens.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 15))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Pens").font(.largeTitle.weight(.bold)).foregroundStyle(tokens.ink)
                        Text("Your projects, conversations and memory, together.")
                            .font(.callout).foregroundStyle(tokens.muted)
                    }
                    Spacer(minLength: 12)
                    Button("New Pen", systemImage: "plus") { model.showNewPenSheet = true }
                        .buttonStyle(.borderedProminent).tint(tokens.tint)
                }
                if model.pens.isEmpty {
                    ContentUnavailableView(
                        "No Pens yet", systemImage: "folder.badge.plus",
                        description: Text("Create a Pen to keep chats and memory together.")
                    ).frame(maxWidth: .infinity, minHeight: 280)
                } else {
                    HStack(spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").foregroundStyle(tokens.muted)
                            TextField("Search Pens", text: $query).textFieldStyle(.plain)
                            if !query.isEmpty {
                                Button {
                                    query = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain).accessibilityLabel("Clear Pen search")
                            }
                        }
                        .padding(10).frame(maxWidth: 360)
                        .background(tokens.surface, in: RoundedRectangle(cornerRadius: 10))
                        Spacer(minLength: 0)
                        Text("\(pens.count) of \(model.pens.count) Pens")
                            .font(.caption).foregroundStyle(tokens.muted)
                        Picker("Sort", selection: $sort) {
                            ForEach(PensSort.allCases) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().frame(width: 155).accessibilityLabel("Sort Pens")
                        Picker("View", selection: $layout) {
                            Label("Grid", systemImage: "square.grid.2x2").tag("grid")
                            Label("List", systemImage: "list.bullet").tag("list")
                        }.pickerStyle(.segmented).frame(width: 130).accessibilityLabel("Pens layout")
                    }
                    if pens.isEmpty {
                        ContentUnavailableView.search(text: query).frame(maxWidth: .infinity, minHeight: 220)
                    } else if layout == "list" {
                        LazyVStack(spacing: 12) {
                            ForEach(pens) { pen in
                                PenHomeCard(pen: pen, chats: chats[pen.id] ?? [], list: true)
                            }
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                            ForEach(pens) { pen in
                                PenHomeCard(pen: pen, chats: chats[pen.id] ?? [])
                            }
                        }
                    }
                }
            }
            .padding(28).frame(maxWidth: 1320, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background {
            LinearGradient(
                colors: [tokens.tint.opacity(0.07), .clear], startPoint: .topLeading, endPoint: .center)
        }
    }

    private func visiblePens(chats: [UUID?: [ChatSession]]) -> [Pen] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.pens.filter { pen in
            term.isEmpty
                || [
                    pen.name, pen.instructions, pen.workspace?.path ?? "",
                    model.memory.providerName(forProjectID: pen.id),
                ]
                .contains { $0.localizedCaseInsensitiveContains(term) }
        }.sorted { lhs, rhs in
            switch sort {
            case .name:
                let order = lhs.name.localizedStandardCompare(rhs.name)
                return order == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : order == .orderedAscending
            case .created:
                return lhs.createdAt == rhs.createdAt
                    ? lhs.id.uuidString < rhs.id.uuidString : lhs.createdAt > rhs.createdAt
            case .recent:
                let a = chats[lhs.id]?.map(\.updatedAt).max() ?? lhs.createdAt
                let b = chats[rhs.id]?.map(\.updatedAt).max() ?? rhs.createdAt
                return a == b ? lhs.id.uuidString < rhs.id.uuidString : a > b
            }
        }
    }
}

private struct PenHomeCard: View {
    let pen: Pen
    let chats: [ChatSession]
    var list = false
    @Environment(AppModel.self) private var model
    @State private var hovering = false
    @State private var folderError: String?
    private var tokens: Caprine { model.theme.tokens }
    private var tint: Color { Color(pen.color) }
    private var memoryState: PenCardMemoryState {
        PenCardMemoryState.resolve(
            configuration: model.memory.configurationLoadState,
            globalEnabled: model.memory.isEnabled,
            penEnabled: model.memory.penMemoryIsEnabled(forProjectID: pen.id),
            providerAvailable: model.memory.isProviderAvailable(model.memory.providerID(forProjectID: pen.id)))
    }
    private var instructions: String { pen.instructions.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var latest: Date { chats.map(\.updatedAt).max() ?? pen.createdAt }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                model.openPen(pen)
            } label: {
                Group {
                    if list {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 20) {
                                VStack(alignment: .leading, spacing: 10) {
                                    header
                                    stats
                                }.frame(width: 255)
                                folderDetails.frame(minWidth: 170, maxWidth: .infinity, alignment: .leading)
                                memoryDetails.frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)
                            }.padding(.trailing, 20)
                            compactContent
                        }
                    } else {
                        compactContent
                    }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Open \(pen.name) Pen")
            Rectangle().fill(tint.opacity(0.18)).frame(height: 1)
            HStack(spacing: 6) {
                Button("New Chat", systemImage: "plus.bubble") {
                    model.beginNewChat(in: pen)
                }.buttonStyle(SecondaryChipButtonStyle()).tint(tint)
                Spacer(minLength: 0)
                Button("Folder", systemImage: "folder") { openFolder() }
                    .buttonStyle(SecondaryChipButtonStyle()).disabled(pen.workspace == nil)
                Button("Edit", systemImage: "slider.horizontal.3") { model.editingPen = pen }
                    .buttonStyle(SecondaryChipButtonStyle())
            }
            .font(.caption).padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(tokens.surface.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
        .background {
            RoundedRectangle(cornerRadius: 16).fill(
                LinearGradient(
                    colors: [tint.opacity(0.2), tint.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        }
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(tint.opacity(hovering ? 0.65 : 0.3), lineWidth: 1) }
        .overlay(alignment: .topTrailing) {
            Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(tint)
                .padding(14).allowsHitTesting(false).accessibilityHidden(true)
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open Pen") { model.openPen(pen) }
            Button("Edit Pen…") { model.editingPen = pen }
            if let workspace = pen.workspace {
                Button("Open Folder") { openFolder() }
                Button("Copy Folder Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(workspace.path, forType: .string)
                }
            }
        }
        .alert(
            "Could not open folder",
            isPresented: Binding(get: { folderError != nil }, set: { if !$0 { folderError = nil } })
        ) {
            Button("OK", role: .cancel) { folderError = nil }
        } message: {
            Text(folderError ?? "")
        }
    }

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            stats
            folderDetails
            memoryDetails
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(pen.emoji.isEmpty ? "🐐" : pen.emoji).font(.title)
                .frame(width: 48, height: 48)
                .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 4) {
                Text(pen.name).font(.headline).foregroundStyle(tokens.ink).lineLimit(2)
                Text("Active \(latest.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2).foregroundStyle(tokens.muted)
            }.padding(.trailing, list ? 0 : 18)
            Spacer(minLength: 0)
        }
    }

    private var stats: some View {
        HStack(spacing: 8) {
            stat("\(chats.count) \(chats.count == 1 ? "chat" : "chats")", symbol: "bubble.left.and.bubble.right")
            stat("\(pen.files.count) \(pen.files.count == 1 ? "file" : "files")", symbol: "paperclip")
            stat(instructions.isEmpty ? "No instructions" : "Instructions set", symbol: "text.document")
        }
    }

    private var folderDetails: some View {
        detail("Folder", symbol: "folder") {
            Text(pen.workspace?.path ?? "No folder linked")
                .font(.caption).foregroundStyle(pen.workspace == nil ? tokens.muted : tokens.ink)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private var memoryDetails: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "brain.head.profile").foregroundStyle(tint).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.memory.providerName(forProjectID: pen.id))
                        .font(.caption.weight(.medium)).foregroundStyle(tokens.ink).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(memoryState.rawValue).font(.caption2.weight(.medium))
                        .foregroundStyle(memoryState == .ready ? tint : tokens.muted)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((memoryState == .ready ? tint : tokens.muted).opacity(0.12), in: Capsule())
                }
                Text(memoryDetail).font(.caption2).foregroundStyle(tokens.muted).lineLimit(1).truncationMode(.middle)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var memoryDetail: String {
        switch memoryState {
        case .loading: return "Loading saved memory configuration"
        case .unavailable: return "Open the Pen to check memory setup"
        case .off: return "Memory is disabled for this Pen"
        case .paused: return "The global memory switch is off"
        case .ready:
            if let connection = model.memory.hindsightConnection(forProjectID: pen.id) { return connection.bankID }
            return "Stored locally and scoped to this Pen"
        }
    }

    private func stat(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.caption2).foregroundStyle(tokens.muted)
            .lineLimit(1).padding(.horizontal, 5).padding(.vertical, 4)
            .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    }

    private func detail<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content)
        -> some View
    {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption2.weight(.medium)).foregroundStyle(tokens.muted)
                content()
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func openFolder() {
        guard let workspace = pen.workspace else { return }
        if !NSWorkspace.shared.open(URL(fileURLWithPath: workspace.path, isDirectory: true)) {
            folderError = "The configured folder could not be opened: \(workspace.path)"
        }
    }
}
