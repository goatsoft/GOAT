import SwiftUI

extension View {
    /// A secondary menu with native text and caret, without a filled bezel.
    public func caprineSecondaryMenu(color: Color) -> some View {
        menuStyle(.borderlessButton)
            .buttonStyle(.plain)
            .tint(color)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Compact unfilled arrows for secondary integer settings. Values never wrap at limits.
public struct CaprineCompactStepper: View {
    private let title: String
    @Binding private var value: Int
    @Environment(\.isEnabled) private var isEnabled
    private let bounds: ClosedRange<Int>
    private let step: Int

    public init(_ title: String, value: Binding<Int>, in bounds: ClosedRange<Int>, step: Int = 1) {
        self.title = title
        _value = value
        self.bounds = bounds
        self.step = max(1, step)
    }

    public var body: some View {
        HStack(spacing: Caprine.Activity.compactSpacing) {
            Text(title)
            VStack(spacing: 0) {
                arrow("chevron.up", label: "Increase", enabled: value < bounds.upperBound) { increase() }
                arrow("chevron.down", label: "Decrease", enabled: value > bounds.lowerBound) { decrease() }
            }
        }
        .font(Caprine.Activity.font)
        .accessibilityElement(children: .combine)
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: increase()
            case .decrement: decrease()
            @unknown default: break
            }
        }
    }

    private func arrow(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .semibold))
                .frame(width: 18, height: 11)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .disabled(!enabled)
        .accessibilityLabel("\(label) \(title)")
        .help(label)
    }

    private func increase() { value += min(step, max(0, bounds.upperBound - value)) }
    private func decrease() { value -= min(step, max(0, value - bounds.lowerBound)) }
}
