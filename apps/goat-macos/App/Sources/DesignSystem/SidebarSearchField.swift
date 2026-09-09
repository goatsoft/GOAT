import SwiftUI

/// A compact search field whose surface and focus treatment come from the active theme.
struct SidebarSearchField: View {
    @Binding var text: String
    let prompt: String
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(model.theme.tokens.muted)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .foregroundStyle(model.theme.tokens.ink)
                .focused($focused)
                .onExitCommand { text = "" }
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button {
                    text = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(model.theme.tokens.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(model.theme.tokens.surface.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(focused ? model.theme.tokens.tint : model.theme.tokens.muted.opacity(0.22))
        }
    }
}
