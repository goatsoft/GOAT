import SwiftUI

/// Keep the duration directly below its label, including inside a reasoning disclosure.
/// Both lines share a leading edge; expanding reasoning never moves the clock below it.
struct AssistantStatusRow<Content: View>: View {
    let startedAt: Date?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            content
            if let startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let elapsed = Self.elapsedLabel(context.date.timeIntervalSince(startedAt))
                    Text(elapsed)
                        .monospacedDigit()
                        .accessibilityLabel("Elapsed time")
                        .accessibilityValue(elapsed)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
                .layoutPriority(1)
            }
        }
    }

    private static func elapsedLabel(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}
