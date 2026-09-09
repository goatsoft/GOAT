import AppKit
import SwiftUI

struct TypographySettings: View {
    @Environment(AppModel.self) private var model
    @State private var choosing: ReadingFontRole?

    var body: some View {
        @Bindable var model = model
        Section("Fonts") {
            fontControl(.chat, selection: $model.chatFontID, size: $model.chatFontSize)
            fontControl(.code, selection: $model.codeFontID, size: $model.codeFontSize)
            VStack(alignment: .leading, spacing: 6) {
                Text("The quick brown goat jumps over the fence.")
                    .font(Font(model.chatNSFont))
                Text("let greeting = \"Hello, Herd!\" // 0123")
                    .font(Font(model.codeNSFont))
                    .foregroundStyle(model.theme.tokens.muted)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(model.theme.tokens.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel("Font preview")
            HStack {
                Text("Local fonts · No downloads").font(.caption).foregroundStyle(model.theme.tokens.muted)
                    .help(
                        "Chat, composer and native readers use these fonts. Interface controls retain the macOS system font. Explicit choices override theme fonts."
                    )
                Spacer()
                Button("Reset") {
                    model.chatFontID = "theme"
                    model.codeFontID = "theme"
                    model.chatFontSize = ReadingFontRole.chat.defaultSize
                    model.codeFontSize = ReadingFontRole.code.defaultSize
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(model.theme.tokens.muted)
                .help("Follow theme fonts and restore default sizes")
            }
        }
    }

    private func fontControl(_ role: ReadingFontRole, selection: Binding<String>, size: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                Text(role.title).font(.callout)
                Spacer(minLength: 12)
                Button {
                    choosing = role
                } label: {
                    HStack(spacing: 8) {
                        Text(model.readingFontName(selection.wrappedValue, role: role))
                            .font(
                                Font(
                                    ReadingFonts.nsFont(
                                        model.readingFontID(selection.wrappedValue, role: role), size: 14, role: role))
                            ).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                }
                .buttonStyle(SecondaryChipButtonStyle())
                .frame(width: 210)
                .accessibilityLabel("Choose \(role.title) font")
                .popover(
                    isPresented: Binding(
                        get: { choosing == role },
                        set: { if !$0 && choosing == role { choosing = nil } }),
                    arrowEdge: .bottom
                ) {
                    ReadingFontPicker(role: role, selection: selection)
                }
                HStack(spacing: 4) {
                    TextField("", value: size, format: .number.precision(.fractionLength(0)))
                        .labelsHidden().textFieldStyle(.plain).monospacedDigit().multilineTextAlignment(.trailing)
                        .frame(width: 26)
                        .accessibilityLabel("\(role.title) font size")
                    Text("pt").font(.caption).foregroundStyle(model.theme.tokens.muted)
                    Stepper("Size", value: size, in: role.sizeRange, step: 1).labelsHidden().controlSize(.small)
                        .accessibilityLabel("\(role.title) font size stepper")
                }.fixedSize()
            }
            if let notice = model.readingFontNotice(selection.wrappedValue, role: role) {
                Label(notice, systemImage: "info.circle").font(.caption).foregroundStyle(model.theme.tokens.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ReadingFontPicker: View {
    let role: ReadingFontRole
    @Binding var selection: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var fonts: [ReadingFonts.Choice] = []
    @State private var draft = ""

    private var choices: [ReadingFonts.Choice] {
        let all = [ReadingFonts.Choice(id: "theme", name: "Theme default")] + ReadingFonts.builtins(for: role) + fonts
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? all : all.filter { $0.name.localizedStandardContains(query) }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(model.theme.tokens.muted)
                TextField("Search fonts", text: $search)
                    .labelsHidden().textFieldStyle(.plain)
                    .onSubmit { apply(draft) }
            }
            .padding(8)
            .background(model.theme.tokens.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            List(selection: $draft) {
                ForEach(choices) { choice in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark").font(.caption.weight(.semibold))
                            .opacity(selection == choice.id ? 1 : 0).frame(width: 12)
                        Text(choice.name).font(
                            Font(
                                ReadingFonts.nsFont(
                                    model.readingFontID(choice.id, role: role), size: 14, role: role))
                        ).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 3).contentShape(Rectangle()).tag(choice.id)
                    .onTapGesture { apply(choice.id) }
                    .help(choice.id.hasPrefix("font:") ? String(choice.id.dropFirst(5)) : choice.name)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { apply(choice.id) }
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden).frame(height: 230)
            .onKeyPress(.return) {
                apply(draft)
                return .handled
            }
            .overlay {
                if choices.isEmpty {
                    Text("No matching fonts").font(.callout).foregroundStyle(model.theme.tokens.muted)
                }
            }
            Text(role == .code ? "Monospaced fonts on this Mac" : "Fonts on this Mac")
                .font(.caption).foregroundStyle(model.theme.tokens.muted)
        }
        .padding(10).frame(width: 320)
        .foregroundStyle(model.theme.tokens.ink)
        .background(model.theme.tokens.surface)
        .onExitCommand { dismiss() }
        .onChange(of: search) {
            if !choices.contains(where: { $0.id == draft }) { draft = choices.first?.id ?? "" }
        }
        .onAppear {
            draft = selection
            fonts = ReadingFonts.installed(for: role)
        }
    }

    private func apply(_ id: String) {
        guard choices.contains(where: { $0.id == id }) else { return }
        selection = id
        dismiss()
    }
}
