import Caprine
import Hoofprint
import SwiftUI

/// The GOAT wordmark in heavy block glyphs - two-thick strokes, tight gaps, filled with
/// the theme's neon ramp. Rows start on a block so Swift's indentation strip can't bite.
let goatWordmark = """
    ██████ ██████ ██████ ██████
    ██     ██  ██ ██  ██   ██
    ██ ███ ██  ██ ██████   ██
    ██  ██ ██  ██ ██  ██   ██
    ██████ ██████ ██  ██   ██
    """

struct ActivityLogPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var followsLatest = true

    var body: some View {
        VStack(spacing: 0) {
            crest  // Pinned above the log, including after Clear.
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            model.activity.clear()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Clear")
                        .accessibilityLabel("Clear Log")
                        Button {
                            withAnimation(.easeOut(duration: 0.18)) { model.showActivityLog = false }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .help("Hide (⌃`)")
                        .accessibilityLabel("Hide Log")
                    }
                    .font(.system(size: 12))
                    .buttonStyle(.plain)
                    .foregroundStyle(model.theme.tokens.muted)
                    .padding(12)
                }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        Color.clear.frame(height: 1).id("top")
                        ForEach(model.activity.entries.reversed()) { entry in
                            row(entry).id(entry.id)
                        }
                        if model.activity.entries.isEmpty {
                            Text("Connection decisions and app activity appear here.")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y <= 24
                } action: { _, atTop in
                    followsLatest = atTop
                }
                .onChange(of: model.activity.entries.last?.id) {
                    if followsLatest { proxy.scrollTo("top", anchor: .top) }
                }
            }
        }
        .frame(height: 260)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(model.theme.tokens.tint.opacity(0.3)).frame(height: 0.5)
        }
    }

    /// The byline, JUDAS status and release label sit beside the wordmark at the same height.
    /// Pinned above the log so it never scrolls away.
    private var crest: some View {
        HStack(alignment: .center, spacing: 12) {
            GoatWordmarkView(
                tokens: model.theme.tokens, size: 8,
                animate: model.presentation.isEnabled && model.animationsEnabled && scenePhase == .active)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.presentation.isEnabled ? "GOATed Open AI Tool" : "Your private AI workspace")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(model.theme.tokens.ink.opacity(0.9))
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    Text("JUDAS")
                        .fontWeight(.semibold)
                        .foregroundStyle(model.theme.tokens.tint)
                    Text(" is watching the HERD.")
                        .foregroundStyle(model.theme.tokens.muted)
                }
                .font(.system(size: 9.5, design: .monospaced))
                Spacer(minLength: 0)
                Text(versionLine)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(model.theme.tokens.muted)
            }
            .lineLimit(1)
            .frame(maxHeight: .infinity)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.trailing, 72)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(model.theme.tokens.accent.opacity(0.05))
        .overlay(alignment: .bottom) {
            Rectangle().fill(model.theme.tokens.tint.opacity(0.18)).frame(height: 0.5)
        }
    }

    private var versionLine: String { AppInfo.full }

    private func row(_ entry: ActivityLog.Entry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.date, format: .dateTime.hour().minute().second())
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text(entry.category.rawValue.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(color(entry.category))
                .frame(width: 54, alignment: .leading)
            Text(entry.text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(model.theme.tokens.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func color(_ category: ActivityLog.Category) -> Color {
        switch category {
        case .engine: model.theme.tokens.accent
        case .mcp: model.theme.tokens.accent2
        case .memory: model.theme.tokens.glow
        case .judas: model.theme.tokens.tint
        case .warn: .orange
        case .info: .secondary
        }
    }
}

/// The block-letter GOAT, filled with the theme's neon ramp. When `animate`, a wider
/// repeating gradient slides its bright bands across the letters - a 1337 shimmer.
/// Honors Reduce Motion (static ramp, no slide).
struct GoatWordmarkView: View {
    let tokens: Caprine
    var size: CGFloat = 11
    var animate: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var glyph: some View {
        Text(goatWordmark)
            .font(.system(size: size, weight: .heavy, design: .monospaced))
            .tracking(-0.5)  // pull the block columns together so letters read as solid
            .fixedSize()
            .shadow(color: tokens.glow.opacity(0.5), radius: 5)
            .accessibilityLabel("GOAT")
    }

    var body: some View {
        if animate && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let shift = CGFloat(sin(t * 0.9))  // −1…1, ~7s round trip
                glyph.foregroundStyle(
                    LinearGradient(
                        colors: [tokens.accent, tokens.glow, tokens.accent2, tokens.glow, tokens.accent],
                        startPoint: UnitPoint(x: -1 + shift, y: 0.5),
                        endPoint: UnitPoint(x: 1 + shift, y: 0.5))
                )
            }
        } else {
            glyph.foregroundStyle(
                LinearGradient(
                    colors: [tokens.accent, tokens.glow, tokens.accent2],
                    startPoint: .leading, endPoint: .trailing)
            )
        }
    }
}
