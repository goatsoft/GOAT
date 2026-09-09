import AppKit
import Caprine
import Inference
import SwiftUI

/// The goaties - the resident mascot set, one pose per app mood. Whimsy budget (DESIGN.md §1.3):
/// empty states, errors, the About box. Never on the hot path.
enum Goatie: String, CaseIterable {
    case wave, thumbsup, heart, laugh, surprise
    case thinking, shrug, cry, arms, sleeping
    case typing, headphones, mic, check, warning
    case celebrate, running, folder, laptop, rocket
    case graze, climb, trot

    var asset: String { "goatie-\(rawValue)" }

    var image: Image { Image(asset) }

    static func assistant(complete: Bool, hasError: Bool) -> Self {
        if hasError { return .warning }
        return complete ? .wave : .thinking
    }
}

struct GoatieView: View {
    let pose: Goatie
    var size: CGFloat = 96
    @Environment(AppModel.self) private var model

    var body: some View {
        Image(model.presentation.isEnabled ? pose.asset : (model.theme.isDark ? "goat-dark" : "goat-light"))
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension Effort {
    @MainActor func presentationColor(in theme: ThemeSpec) -> Color {
        switch self {
        case .graze: theme.tokens.muted
        case .trot: theme.tokens.ink
        case .climb: .blue
        case .summit: .purple
        }
    }

    /// The goatie that fronts each effort level.
    var goatie: Goatie {
        switch self {
        case .graze: .graze
        case .trot: .trot
        case .climb: .climb
        case .summit: .rocket  // no summit sprite - rocket says "send it"
        }
    }
}

/// A compact effort dropdown: current effort as a button, EffortRows in a popover.
/// Shares EffortRow with the model menu so the two never drift.
struct EffortDropdown: View {
    @Binding var effort: Effort
    @State private var show = false
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            show.toggle()
        } label: {
            HStack(spacing: 7) {
                if model.presentation.isEnabled { GoatieView(pose: effort.goatie, size: 22) }
                Text(effort.label).fontWeight(.medium)
                    .foregroundStyle(effort.presentationColor(in: model.theme))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $show, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                ForEach(Effort.allCases) { e in
                    EffortRow(effort: e, selected: e == effort) {
                        effort = e
                        show = false
                    }
                }
            }
            .padding(.vertical, 6)
            .frame(width: 260)
        }
    }
}

/// One selectable effort row - goatie + name + blurb + tick. Shared by the model
/// popover and General settings so they never drift.
struct EffortRow: View {
    let effort: Effort
    let selected: Bool
    let action: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if model.presentation.isEnabled { GoatieView(pose: effort.goatie, size: 30) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(effort.label).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(effort.presentationColor(in: model.theme))
                    Text(effort.blurb).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(model.theme.tokens.tint)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Professional figurehead used even inside the unlocked About interface when requested.
struct FigureheadView: View {
    var size: CGFloat = 96
    var fillsFrame = false
    @Environment(AppModel.self) private var model

    var body: some View {
        artwork
            .renderingMode(.original)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .scaledToFit()
            // The source includes generous transparent margins. Use the full mark in chat
            // without changing its aspect ratio or the surrounding avatar column.
            .frame(width: size * (fillsFrame ? 1.25 : 1), height: size * (fillsFrame ? 1.25 : 1))
            .frame(width: size, height: size)
            .clipped()
            .accessibilityHidden(true)
    }

    private var artwork: Image {
        if fillsFrame, let compact = CompactMasthead.image(dark: model.theme.isDark) {
            return Image(nsImage: compact)
        }
        return Image(model.theme.isDark ? "goat-dark" : "goat-light")
    }
}

/// The live window renderer aliases the 1254-pixel mark at chat size even with high
/// interpolation. Prefilter once using Core Graphics, retaining enough pixels for Retina.
/// These two immutable thumbnails are shared by every message; larger artwork stays original.
@MainActor
private enum CompactMasthead {
    private static let light = prepare("goat-light")
    private static let dark = prepare("goat-dark")

    static func image(dark isDark: Bool) -> NSImage? { isDark ? dark : light }

    private static func prepare(_ name: String) -> NSImage? {
        guard let original = NSImage(named: name),
            let source = original.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: 128, height: 128))
        guard let thumbnail = context.makeImage() else { return nil }
        return NSImage(cgImage: thumbnail, size: NSSize(width: 128, height: 128))
    }
}
