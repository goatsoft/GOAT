import Caprine
import Memory
import SwiftUI

struct MemoryRecordRow: View {
    let entry: MemoryBrowserEntry
    let tint: Color
    let onOpen: () -> Void
    @Environment(AppModel.self) private var model
    @State private var hovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "text.bubble")
                    .foregroundStyle(tint).font(.callout)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.displayTitle).font(.callout.weight(.medium))
                        .foregroundStyle(model.theme.tokens.ink).lineLimit(2)
                    if !entry.summary.isEmpty && entry.summary != entry.displayTitle {
                        Text(entry.summary).font(.callout)
                            .foregroundStyle(model.theme.tokens.muted).lineLimit(4)
                    }
                    if let date = entry.modifiedAt {
                        Text(date, style: .relative).font(.caption2)
                            .foregroundStyle(model.theme.tokens.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption2)
                    .foregroundStyle(model.theme.tokens.muted)
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .background(
                hovered ? tint.opacity(0.09) : model.theme.tokens.surface.opacity(0.55),
                in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityHint("Open this memory record")
    }
}

/// Keep a long memory bank from expanding its parent page. The record count and text are bounded;
/// a separate viewport gives roughly four typical previews their own scroll area.
struct MemoryRecordList: View {
    let entries: [MemoryBrowserEntry]
    let tint: Color
    let onSelect: (MemoryEntryID) -> Void
    @State private var contentHeight: CGFloat = 300

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(entries, id: \.id) { entry in
                    MemoryRecordRow(entry: entry, tint: tint) { onSelect(entry.id) }
                }
            }
            .padding(.trailing, 8)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                contentHeight = $0
            }
        }
        .frame(height: min(300, max(64, contentHeight)))
        .scrollIndicators(.visible)
        .accessibilityLabel("Recent memory records")
    }
}

extension View {
    func penPanel(tokens: Caprine) -> some View {
        self.padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tokens.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14).strokeBorder(tokens.muted.opacity(0.16))
            }
    }
}
