# ADR-0058: Stable transcript reflow and scroll ownership

Status: Accepted · 2026-09-07 · Refines ADRs 0053, 0056 and 0057.

## Context

The user reported chat content disappearing during font resizing and scrolling. A native regression exposed a stack-overflow crash in observable font setters that assigned to themselves unconditionally. The transcript also fed estimated lazy-stack heights into immediate scroll commands and animated row placement.

## Decision

Use a fully measured `VStack` containing at most 40 messages, with the existing bounded Markdown cache. Native lazy-stack height estimates remained unstable under large font/width changes, and the native list alternative failed the selection/reflow regressions. A bounded measured window trades implicit whole-history scrolling for predictable geometry and bounded rich-view work.

Earlier and Later controls move by 20 messages with an overlapping window, preserving the current edge as a message-ID scroll target. Latest and a new send return to the newest window. All messages remain in the model and database; model context and generation ownership do not use this display range. Loading/evicting model history remains separate work.

Each message contributes one stable, vertically self-sizing child. Row insertion fades and offsets are removed. Native scroll-position binding preserves reading identity; native size-change anchors handle font, width and prepared-content reflow. Estimated content heights no longer drive explicit scrolling.

A bottom sentinel tracks whether the reader has reached the end. Reader gestures suspend following through deceleration; ending at the bottom resumes it. New sends resume following. Stream-driven commands retain their 15 Hz upper bound and are always deferred out of the current layout frame. Disappearance and reader gestures cancel pending commands.

Font setters assign a normalized value only when it differs, then persist the canonical value. This bounds observable setter reentry while preserving existing preference keys and valid ranges.

## Consequences and validation

No storage, network authority, dependency or cache policy changes. Visibility observations stay outside observable view state; resuming following is deferred to avoid layout feedback. Long-history paging and large-code rendering remain PERF-01 and PERF-04.

Native regressions cover long/short chat selection, 80 messages across five width/font combinations and five native wheel movements, and scroll-wheel events followed by streaming and reflow. Font tests cover repeated, fractional, out-of-range and non-finite assignments and persistence. Visual inspection uses the complete hosting view, not its transparent clipping layer.

## References

- [Apple: creating performant scrollable stacks](https://developer.apple.com/documentation/swiftui/creating-performant-scrollable-stacks)
- [Apple: scroll target layouts](https://developer.apple.com/documentation/swiftui/view/scrolltargetlayout(isenabled:))
- [Apple: default scroll anchors by role](https://developer.apple.com/documentation/swiftui/view/defaultscrollanchor(_:for:))
