import Caprine
import SwiftUI

/// Shared chrome for a "managed list" settings screen: the pluggable systems (engines, MCP
/// servers) look and behave the same (ADR-0021): a themed glass action bar over a themed List.
/// Callers supply the toolbar buttons and the list rows.
struct ManagedListScaffold<Toolbar: View, Rows: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder var toolbar: () -> Toolbar
    @ViewBuilder var rows: () -> Rows

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) { toolbar() }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .themedBar(model.theme.tokens, hairline: .bottom)

            List { rows() }
                .scrollContentBackground(.hidden)
        }
    }
}

extension View {
    /// A theme-tinted translucent toolbar surface with a separator on the specified edge.
    func themedBar(_ tokens: Caprine, hairline edge: VerticalEdge = .bottom) -> some View {
        background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                tokens.surface.opacity(0.5)
                tokens.tint.opacity(0.06)
            }
        }
        .overlay(alignment: edge == .bottom ? .bottom : .top) {
            Rectangle().fill(tokens.tint.opacity(0.22)).frame(height: 0.5)
        }
    }
}
