import AppKit
import SwiftUI

/// Finite, bounded camera math shared by pointer, trackpad, and toolbar controls.
struct GraphCamera: Equatable {
    static let minimumZoom: CGFloat = 0.2
    static let maximumZoom: CGFloat = 20

    private(set) var zoom: CGFloat = 1
    private(set) var pan = CGSize.zero
    private(set) var yaw: CGFloat = 0
    private(set) var pitch: CGFloat = 0

    mutating func orbit(horizontal: CGFloat, vertical: CGFloat) {
        guard horizontal.isFinite, vertical.isFinite else { return }
        yaw = (yaw + horizontal.truncatingRemainder(dividingBy: .pi * 2)).truncatingRemainder(dividingBy: .pi * 2)
        pitch = min(.pi * 0.48, max(-.pi * 0.48, pitch + vertical))
    }

    struct Projection {
        let point: CGPoint
        let depth: CGFloat
        let perspective: CGFloat
    }

    func project(_ position: MemoryGraphPosition, size: CGSize) -> Projection {
        // One radius for both screen axes preserves shape while orbiting. The camera remains
        // outside the normalized unit sphere, so its near plane cannot intersect graph nodes.
        let x = CGFloat(position.x) * cos(yaw) + CGFloat(position.z) * sin(yaw)
        let z = -CGFloat(position.x) * sin(yaw) + CGFloat(position.z) * cos(yaw)
        let y = CGFloat(position.y) * cos(pitch) - z * sin(pitch)
        let depth = CGFloat(position.y) * sin(pitch) + z * cos(pitch)
        let perspective: CGFloat = 3.4 / max(0.5, 3.4 - depth)
        let radius = max(1, min(size.width, size.height) / 2 - 28) * zoom
        return Projection(
            point: CGPoint(
                x: size.width / 2 + x * radius * perspective + pan.width,
                y: size.height / 2 + y * radius * perspective + pan.height),
            depth: depth, perspective: perspective)
    }

    mutating func scroll(delta: CGFloat, precise: Bool, anchor: CGPoint, size: CGSize) {
        guard delta.isFinite else { return }
        // Trackpads report pixels; wheels report lines. Bound bursts before exponentiation so a
        // single accelerated event cannot jump to a zoom limit or overflow the scale calculation.
        let step = min(0.2, max(-0.2, delta * (precise ? 0.003 : 0.08)))
        scale(to: zoom * exp(step), anchor: anchor, size: size)
    }

    mutating func scale(to proposed: CGFloat, anchor: CGPoint, size: CGSize) {
        guard proposed.isFinite, anchor.x.isFinite, anchor.y.isFinite,
            size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0
        else { return }
        let next = min(Self.maximumZoom, max(Self.minimumZoom, proposed))
        let factor = next / zoom
        let x = anchor.x - size.width / 2
        let y = anchor.y - size.height / 2
        zoom = next
        move(to: CGSize(width: x - (x - pan.width) * factor, height: y - (y - pan.height) * factor), size: size)
    }

    mutating func move(to proposed: CGSize, size: CGSize) {
        guard proposed.width.isFinite, proposed.height.isFinite,
            size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0
        else { return }
        let extent = max(4, zoom * 2)
        pan = CGSize(
            width: min(size.width * extent, max(-size.width * extent, proposed.width)),
            height: min(size.height * extent, max(-size.height * extent, proposed.height)))
    }
}

/// One native responder owns pointer, trackpad, and keyboard input. An inactive viewport forwards
/// scrolling normally; a click activates it until the pointer leaves or first-responder focus moves.
struct GraphInteractionSurface: NSViewRepresentable {
    @Binding var isActive: Bool
    var onScroll: (CGFloat, CGPoint, Bool) -> Void
    var onRotate: (CGFloat, CGFloat) -> Void
    var onPan: (CGSize) -> Void
    var onMagnify: (CGFloat) -> Void
    var onKey: (String) -> Bool
    var onSelect: (CGPoint) -> Void
    var onHover: (CGPoint?) -> Void

    final class Surface: NSView {
        private(set) var isActive = false
        var onActiveChange: ((Bool) -> Void)?
        var onScroll: ((CGFloat, CGPoint, Bool) -> Void)?
        var onRotate: ((CGFloat, CGFloat) -> Void)?
        var onPan: ((CGSize) -> Void)?
        var onMagnify: ((CGFloat) -> Void)?
        var onKey: ((String) -> Bool)?
        var onSelect: ((CGPoint) -> Void)?
        var onHover: ((CGPoint?) -> Void)?
        private var clickOrigin: CGPoint?
        private var pointerTracking: NSTrackingArea?
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        func setActive(_ active: Bool, notify: Bool = true) {
            guard isActive != active else { return }
            isActive = active
            if !active { clickOrigin = nil }
            if active { window?.makeFirstResponder(self) }
            if notify { onActiveChange?(active) }
        }
        override func mouseDown(with event: NSEvent) {
            setActive(true)
            clickOrigin = convert(event.locationInWindow, from: nil)
        }
        override func mouseUp(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if isActive, let origin = clickOrigin, hypot(point.x - origin.x, point.y - origin.y) < 5 {
                onSelect?(point)
            }
            clickOrigin = nil
        }
        override func mouseMoved(with event: NSEvent) {
            onHover?(convert(event.locationInWindow, from: nil))
        }
        override func rightMouseDown(with event: NSEvent) { setActive(true) }
        override func mouseDragged(with event: NSEvent) {
            guard isActive else {
                super.mouseDragged(with: event)
                return
            }
            onPan?(CGSize(width: event.deltaX, height: event.deltaY))
        }
        override func rightMouseDragged(with event: NSEvent) {
            guard isActive else {
                super.rightMouseDragged(with: event)
                return
            }
            onRotate?(event.deltaX * 0.01, event.deltaY * 0.01)
        }
        override func scrollWheel(with event: NSEvent) {
            guard isActive else {
                super.scrollWheel(with: event)
                return
            }
            onScroll?(
                event.scrollingDeltaY, convert(event.locationInWindow, from: nil), event.hasPreciseScrollingDeltas)
        }
        override func magnify(with event: NSEvent) {
            guard isActive else {
                super.magnify(with: event)
                return
            }
            onMagnify?(1 + event.magnification)
        }
        override func keyDown(with event: NSEvent) {
            guard isActive, onKey?(event.charactersIgnoringModifiers ?? "") == true else {
                super.keyDown(with: event)
                return
            }
        }
        override func resignFirstResponder() -> Bool {
            setActive(false)
            return super.resignFirstResponder()
        }
        override func mouseExited(with event: NSEvent) {
            onHover?(nil)
            setActive(false)
            if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let pointerTracking { removeTrackingArea(pointerTracking) }
            let area = NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
            addTrackingArea(area)
            pointerTracking = area
        }
    }

    func makeNSView(context: Context) -> Surface {
        let view = Surface()
        configure(view)
        return view
    }
    func updateNSView(_ nsView: Surface, context: Context) {
        configure(nsView)
        nsView.setActive(isActive, notify: false)
    }
    private func configure(_ view: Surface) {
        view.onActiveChange = { isActive = $0 }
        view.onScroll = onScroll
        view.onRotate = onRotate
        view.onPan = onPan
        view.onMagnify = onMagnify
        view.onKey = onKey
        view.onSelect = onSelect
        view.onHover = onHover
    }
    static func dismantleNSView(_ nsView: Surface, coordinator: ()) {
        nsView.onActiveChange = nil
        nsView.setActive(false, notify: false)
    }
}

/// One native pointer target keeps legend hover and click help reliable beside the AppKit canvas.
/// SwiftUI retains keyboard/accessibility activation. The target never claims keyboard focus and
/// leaves scrolling to the responder chain.
struct MapLegendHoverSurface: NSViewRepresentable {
    var onHover: (Bool) -> Void

    final class Surface: NSView {
        var onHover: ((Bool) -> Void)?
        private var area: NSTrackingArea?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { onHover?(true) }
        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseMoved(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let next = NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
            addTrackingArea(next)
            area = next
        }
    }

    func makeNSView(context: Context) -> Surface {
        let view = Surface()
        view.onHover = onHover
        return view
    }
    func updateNSView(_ nsView: Surface, context: Context) { nsView.onHover = onHover }
}
