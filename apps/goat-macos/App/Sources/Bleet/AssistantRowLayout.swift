import Caprine
import SwiftUI

/// The avatar has a fixed intrinsic width; the document receives the remaining width.
/// A general-purpose HStack probes the whole Markdown tree at several widths and
/// searches its descendants for alignment guides. Neither is needed for these columns.
struct AssistantRowLayout: Layout {
    private let spacing = Caprine.Activity.assistantGutter
    private let trailingSpace = Caprine.Activity.trailingSpacer

    struct Cache {
        var avatar: CGSize?
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil }
        let avatar = cache.avatar ?? subviews[0].sizeThatFits(.unspecified)
        cache.avatar = avatar
        let inset = avatar.width + spacing + trailingSpace
        let document = subviews[1].sizeThatFits(
            ProposedViewSize(width: width.map { max(0, $0 - inset) }, height: nil))
        return CGSize(
            width: width ?? (inset + document.width),
            height: max(avatar.height, document.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard subviews.count == 2 else { return }
        let avatar = cache.avatar ?? subviews[0].sizeThatFits(.unspecified)
        cache.avatar = avatar
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(avatar))
        subviews[1].place(
            at: CGPoint(x: bounds.minX + avatar.width + spacing, y: bounds.minY), anchor: .topLeading,
            proposal: ProposedViewSize(
                width: max(0, bounds.width - avatar.width - spacing - trailingSpace), height: nil))
    }
}
