import SwiftUI

struct StorageLocationTree: View {
    let inventory: DataManagementInventory
    @State private var homeExpanded = false
    @State private var supportExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let home = inventory.locations.first(where: { $0.id == "home" }) {
                folderHeader("GOAT Home", url: home.url, expanded: $homeExpanded)
                if homeExpanded {
                    ForEach(
                        inventory.locations.filter {
                            ["config", "memory", "pens", "skills", "extensions"].contains($0.id)
                        }
                    ) { child($0) }
                }
            }
            if let database = inventory.locations.first(where: { $0.id == "database" }) {
                folderHeader(
                    "Application Support", url: database.url.deletingLastPathComponent(), expanded: $supportExpanded)
                if supportExpanded {
                    ForEach(inventory.locations.filter { ["database", "attachments"].contains($0.id) }) {
                        child($0)
                    }
                }
            }
            if let app = inventory.locations.first(where: { $0.id == "app" }) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Application", systemImage: "macwindow").font(.callout.weight(.semibold))
                    Text(app.url.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func folderHeader(_ title: String, url: URL, expanded: Binding<Bool>) -> some View {
        Button {
            expanded.wrappedValue.toggle()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                StorageFolderGlyph(open: expanded.wrappedValue)
                    .frame(width: 19, height: 16).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(url.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
        .accessibilityHint("Show or hide the storage locations in this folder")
    }

    private func child(_ item: DataManagementInventory.Location) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.id == "database" ? "doc" : "folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent).font(.callout.monospaced())
                Text(item.title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(item.status.rawValue).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .padding(.leading, 28)
    }
}

/// A native vector glyph with a raised front flap when its folder is expanded.
private struct StorageFolderGlyph: View {
    let open: Bool
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 2, y: 14))
            path.addLine(to: CGPoint(x: 2, y: 3))
            path.addQuadCurve(to: CGPoint(x: 3, y: 2), control: CGPoint(x: 2, y: 2))
            path.addLine(to: CGPoint(x: 7, y: 2))
            path.addLine(to: CGPoint(x: 9, y: 4))
            path.addLine(to: CGPoint(x: 16, y: 4))
            path.addQuadCurve(to: CGPoint(x: 17, y: 5), control: CGPoint(x: 17, y: 4))
            if open {
                path.addLine(to: CGPoint(x: 17, y: 7))
                path.move(to: CGPoint(x: 2, y: 14))
                path.addLine(to: CGPoint(x: 5, y: 7))
                path.addLine(to: CGPoint(x: 19, y: 7))
                path.addLine(to: CGPoint(x: 16, y: 14))
            } else {
                path.addLine(to: CGPoint(x: 17, y: 14))
            }
            path.addLine(to: CGPoint(x: 2, y: 14))
            path.closeSubpath()
        }
        .stroke(style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
        .foregroundStyle(.secondary)
    }
}
