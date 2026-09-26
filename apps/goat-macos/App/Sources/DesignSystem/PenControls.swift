import AppKit
import Caprine
import OKLabColorPicker
import Pens
import SwiftUI

/// Adapt the shared picker at the UI boundary; the Pen's persisted OKLCH representation stays stable.
enum ColorPickerValues {
    static func picker(_ color: OKLCH) -> OKLabColorValue {
        OKLabColorValue(lightness: color.l, chroma: color.c, hueDegrees: color.h)
    }

    static func pen(_ color: OKLabColorValue) -> OKLCH {
        OKLCH(l: color.lightness, c: color.chroma, h: color.hueDegrees)
    }

    /// Theme slots store opaque #RRGGBB, including when the picker accepts an RGBA hex value.
    static func themeHex(_ color: OKLabColorValue) -> String {
        var opaque = color
        opaque.alpha = 1
        return opaque.hexString
    }
}

/// Shared picker with writable mode state (the upstream convenience button uses a constant mode).
struct ThemeColorPicker: View {
    @Binding var hex: String
    let title: String
    @State private var showingPicker = false
    @State private var mode = OKLabPickerMode.polarOKLCH

    private var value: Binding<OKLabColorValue> {
        Binding(
            get: { OKLabColorValue.from(hex: hex) ?? OKLabColorValue(lightness: 0, a: 0, b: 0) },
            set: { hex = ColorPickerValues.themeHex($0) })
    }

    var body: some View {
        Button {
            showingPicker.toggle()
        } label: {
            HStack(spacing: Caprine.Activity.spacing) {
                RoundedRectangle(cornerRadius: Caprine.Activity.radius)
                    .fill(Color(hexString: hex))
                    .frame(width: InterfaceMetrics.controlHitArea, height: InterfaceMetrics.controlHitArea)
                Text(title)
                Spacer()
                Text(hex).monospaced().foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(hex)
        .popover(isPresented: $showingPicker) {
            SharedColorSelection(color: value, mode: $mode, title: title)
                .padding(Caprine.Activity.spacing)
                .frame(width: Caprine.ColorEditing.pickerWidth)
        }
    }
}

/// Pen colours keep their persisted values; the shared package supplies swatches and precise controls.
struct PenColorPicker: View {
    @Binding var color: OKLCH
    @State private var mode = OKLabPickerMode.perceptualSwatches

    var body: some View {
        SharedColorSelection(
            color: Binding(get: { ColorPickerValues.picker(color) }, set: { color = ColorPickerValues.pen($0) }),
            mode: $mode, title: "Pen colour")
    }
}

/// The package accepts a mode binding; the host supplies the mode selector.
private struct SharedColorSelection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var color: OKLabColorValue
    @Binding var mode: OKLabPickerMode
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: Caprine.Activity.spacing) {
            Picker("Colour controls", selection: $mode) {
                Text("Swatches").tag(OKLabPickerMode.perceptualSwatches)
                Text("Colour wheel").tag(OKLabPickerMode.polarOKLCH)
                Text("Sliders").tag(OKLabPickerMode.cartesianOKLab)
                Text("Harmonies").tag(OKLabPickerMode.colorHarmonies)
            }
            .pickerStyle(.menu)
            OKLabColorPicker(
                color: $color, mode: $mode,
                configuration: OKLabPickerConfiguration(title: title, showColorMetrics: false))
        }
        .transaction { transaction in
            if reduceMotion || !model.animationsEnabled {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
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
