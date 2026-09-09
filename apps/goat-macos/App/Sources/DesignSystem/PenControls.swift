import AppKit
import Pens
import SwiftUI

/// A compact OKLCH colour picker: a live swatch + quick palette, then Lightness / Chroma /
/// Hue sliders. Perceptually uniform, themed, no dependency (conversion lives in GoatCore).
struct OKLCHPicker: View {
    @Binding var color: OKLCH
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(color))
                    .frame(width: 40, height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.2)))
                    .shadow(color: Color(color).opacity(0.5), radius: 5)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(Array(OKLCH.palette.enumerated()), id: \.offset) { _, swatch in
                            Circle()
                                .fill(Color(swatch))
                                .frame(width: 18, height: 18)
                                .overlay(
                                    Circle().strokeBorder(
                                        .white.opacity(isSelected(swatch) ? 0.9 : 0.15),
                                        lineWidth: isSelected(swatch) ? 2 : 1)
                                )
                                .onTapGesture { color = swatch }
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
            slider("Lightness", value: $color.l, range: 0.35...0.92)
            slider("Chroma", value: $color.c, range: 0...0.30)
            slider("Hue", value: $color.h, range: 0...360)
        }
    }

    private func isSelected(_ s: OKLCH) -> Bool {
        abs(s.h - color.h) < 1 && abs(s.l - color.l) < 0.01 && abs(s.c - color.c) < 0.01
    }

    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Slider(value: value, in: range)
                .tint(tint)
        }
    }
}

/// An emoji chooser: the current emoji as a button that opens a grid popover, plus a field
/// to type or paste any emoji, plus the native palette as a fallback. Reliable - selection
/// is a plain tap, not dependent on the system palette's focus insertion.
struct EmojiField: View {
    @Binding var emoji: String
    var tint: Color
    @State private var show = false

    var body: some View {
        Button {
            show.toggle()
        } label: {
            Text(emoji.isEmpty ? "🐐" : emoji)
                .font(.system(size: 22))
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.4)))
                .overlay(
                    RoundedRectangle(cornerRadius: 9).strokeBorder(
                        show ? tint : .secondary.opacity(0.3), lineWidth: show ? 1.5 : 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Choose an emoji")
        .popover(isPresented: $show, arrowEdge: .bottom) {
            EmojiGrid(emoji: $emoji, tint: tint) { show = false }
        }
    }
}

private struct EmojiGrid: View {
    @Binding var emoji: String
    var tint: Color
    let done: () -> Void
    @State private var custom = ""

    private static let choices: [String] = [
        "🐐", "🐑", "🦙", "🐏", "🦌", "🦊", "🦉", "🐢", "🐙", "🦾", "🤖", "🧠",
        "🚀", "🛠", "⚙️", "🔧", "🔬", "🧪", "⚗️", "💻", "🖥", "🕹", "🎮", "📱",
        "📦", "🗂", "📁", "📚", "📝", "📊", "📈", "🧩", "🎯", "🔒", "🔑", "🌐",
        "🎨", "🖌", "✨", "🔥", "💡", "⭐️", "🌱", "🌿", "🍀", "🌈", "⚡️", "🏔",
        "❤️", "🧡", "💛", "💚", "💙", "💜", "🎵", "🎬", "📷", "🐛", "🪜", "🎉",
    ]

    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 4), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Self.choices, id: \.self) { e in
                    Button {
                        emoji = e
                        done()
                    } label: {
                        Text(e)
                            .font(.system(size: 20))
                            .frame(width: 30, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(e == emoji ? tint.opacity(0.3) : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Type / paste", text: $custom)
                    .themedField(tint: tint)
                    .frame(width: 120)
                    .onChange(of: custom) { _, value in
                        if let last = value.last {
                            emoji = String(last)
                            custom = ""
                            done()
                        }
                    }
                Button("More…") { NSApp.orderFrontCharacterPalette(nil) }
                    .font(.caption)
                Spacer()
            }
        }
        .padding(12)
        .frame(width: 296)
    }
}
