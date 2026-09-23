import AppKit
import Hoofprint
import SwiftUI

/// Makes the hosting NSWindow genuinely non-opaque so painted alpha reveals the desktop
/// (SwiftUI windows are opaque by default - materials otherwise render against the window's
/// own backing, which reads as solid). Optionally hides the minimize/zoom traffic-lights for
/// fixed-size windows (e.g. Settings) where they'd only ever be disabled.
///
/// Fullscreen: a non-opaque window in native fullscreen composites against a grey void -
/// there is no desktop behind it - and the Liquid Glass sidebar/titlebar chrome SAMPLES that
/// void, which is "the fullscreen grey" (view dumps 2026-08-30/31). Ghostty ships the same
/// diagnosis and fix ("window transparency only takes effect if not native fullscreen ...
/// the background becomes gray"): while fullscreen, the window backing goes opaque in the
/// theme's base color; on exit it returns to clear. Windowed translucency is untouched.
struct WindowConfigurator: NSViewRepresentable {
    var hidesResizeButtons = false
    var alwaysOnTop = false
    var showsAlwaysOnTopToggle = false
    var onAlwaysOnTopToggle: (() -> Void)?
    var controlTint: Color? = nil
    /// Theme base color used as the opaque window backing while in native fullscreen.
    /// nil keeps the window non-opaque in fullscreen too (pre-existing behavior).
    var fullscreenBackdrop: Color? = nil

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        .zero
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.backdrop = fullscreenBackdrop
        context.coordinator.showsAlwaysOnTopToggle = showsAlwaysOnTopToggle
        context.coordinator.onAlwaysOnTopToggle = onAlwaysOnTopToggle
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            configure(window, coordinator: context.coordinator)
            context.coordinator.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        let backdropChanged = coordinator.backdrop != fullscreenBackdrop
        coordinator.backdrop = fullscreenBackdrop
        coordinator.showsAlwaysOnTopToggle = showsAlwaysOnTopToggle
        coordinator.onAlwaysOnTopToggle = onAlwaysOnTopToggle
        guard let window = nsView.window else {
            DispatchQueue.main.async { [weak nsView] in
                guard let window = nsView?.window else { return }
                configure(window, coordinator: context.coordinator)
                context.coordinator.attach(to: window)
            }
            return
        }
        configure(window, coordinator: coordinator)
        if coordinator.window !== window {
            coordinator.attach(to: window)
        } else if backdropChanged {
            coordinator.apply()
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func configure(_ window: NSWindow, coordinator: Coordinator) {
        if !window.titlebarAppearsTransparent {
            window.titlebarAppearsTransparent = true
        }
        // Keep the toolbar below the titlebar so fullscreen's auto-hiding window controls
        // do not overlap the toolbar buttons.
        if hidesResizeButtons {
            if window.standardWindowButton(.miniaturizeButton)?.isHidden != true {
                window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            }
            if window.standardWindowButton(.zoomButton)?.isHidden != true {
                window.standardWindowButton(.zoomButton)?.isHidden = true
            }
        }
        let targetLevel: NSWindow.Level = alwaysOnTop ? .floating : .normal
        if window.level != targetLevel {
            window.level = targetLevel
        }
        coordinator.configureAlwaysOnTopToggle(in: window, isOn: alwaysOnTop, tint: controlTint.map { NSColor($0) })
    }

    /// Owns the window's opacity/backing in both modes and re-applies on fullscreen
    /// transitions (theme changes flow in through updateNSView).
    @MainActor
    final class Coordinator: NSObject {
        private static let alwaysOnTopPinIdentifier = NSUserInterfaceItemIdentifier("goat.settings.alwaysOnTopPin")
        var backdrop: Color?
        var showsAlwaysOnTopToggle = false
        var onAlwaysOnTopToggle: (() -> Void)?
        private(set) weak var window: NSWindow?
        private var pinAccessory: NSTitlebarAccessoryViewController?
        private var observers: [NSObjectProtocol] = []

        func attach(to window: NSWindow) {
            if self.window !== window {
                detach()
                self.window = window
                observe(window)
            }
            apply()
        }

        func detach() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            if let pinAccessory, let window,
                let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === pinAccessory })
            {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            pinAccessory = nil
            window = nil
        }

        func configureAlwaysOnTopToggle(in window: NSWindow, isOn: Bool, tint: NSColor?) {
            guard showsAlwaysOnTopToggle else {
                if let pinAccessory {
                    if let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === pinAccessory }) {
                        window.removeTitlebarAccessoryViewController(at: index)
                    }
                    self.pinAccessory = nil
                }
                return
            }
            let matching = window.titlebarAccessoryViewControllers.filter {
                ($0.view as? NSButton)?.identifier == Self.alwaysOnTopPinIdentifier
            }
            // A prior SwiftUI host can outlive its representable coordinator. Preserve the
            // first matching accessory and remove any stale duplicates before configuring it.
            for duplicate in matching.dropFirst() {
                if let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === duplicate }) {
                    window.removeTitlebarAccessoryViewController(at: index)
                }
            }

            let button: NSButton
            if let existing = pinAccessory?.view as? NSButton {
                button = existing
            } else if let existing = matching.first?.view as? NSButton {
                button = existing
                pinAccessory = matching.first
            } else {
                button = NSButton(frame: NSRect(x: 0, y: 0, width: 28, height: 24))
                button.isBordered = false
                button.bezelStyle = .inline
                button.identifier = Self.alwaysOnTopPinIdentifier
                button.target = self
                button.action = #selector(toggleAlwaysOnTop)
                button.toolTip = "Always on top"
                let accessory = NSTitlebarAccessoryViewController()
                accessory.layoutAttribute = .right
                accessory.view = button
                window.addTitlebarAccessoryViewController(accessory)
                pinAccessory = accessory
            }
            button.image = NSImage(
                systemSymbolName: isOn ? "pin.fill" : "pin", accessibilityDescription: "Always on top")
            button.contentTintColor = isOn ? (tint ?? .controlAccentColor) : .secondaryLabelColor
        }

        @objc private func toggleAlwaysOnTop() { onAlwaysOnTopToggle?() }

        private func observe(_ window: NSWindow) {
            let center = NotificationCenter.default
            observers.append(
                center.addObserver(
                    forName: NSWindow.willEnterFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.apply(fullscreenOverride: true) }
                })
            observers.append(
                center.addObserver(
                    forName: NSWindow.didEnterFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.apply() }
                })
            observers.append(
                center.addObserver(
                    forName: NSWindow.willExitFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    // Keep the opaque backing throughout the exit transition. Clearing it at
                    // will-exit briefly exposes the compositor's grey void again.
                    MainActor.assumeIsolated { self?.apply(fullscreenOverride: true) }
                })
            observers.append(
                center.addObserver(
                    forName: NSWindow.didExitFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.apply(fullscreenOverride: false) }
                })
        }

        func apply(fullscreenOverride: Bool? = nil) {
            guard let window else { return }
            let isFullscreen = fullscreenOverride ?? window.styleMask.contains(.fullScreen)
            if isFullscreen, let backdrop {
                let targetColor = NSColor(backdrop)
                if !window.isOpaque || window.backgroundColor != targetColor {
                    RenderSignposts.event("WindowBackingChange")
                    window.isOpaque = true
                    window.backgroundColor = targetColor
                }
            } else {
                if window.isOpaque || window.backgroundColor != .clear {
                    RenderSignposts.event("WindowBackingChange")
                    window.isOpaque = false
                    window.backgroundColor = .clear
                }
            }
        }
    }
}
