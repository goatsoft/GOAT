import AppKit
import Darwin
import Foundation
import ObjectiveC

/// Prevents infinite layout, constraint, and display recursion loops between nested
/// split views and SwiftUI hosting views during divider drags.
@MainActor final class LayoutRecursionGuard {
    private static var isUpdatingConstraints = false
    private static var isPerformingLayout = false
    private static var isPerformingDisplay = false
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true

        installConstraintsGuard()
        installLayoutGuard()
        installDisplayGuard()
    }

    private static func installConstraintsGuard() {
        let updateSel = #selector(NSWindow.updateConstraintsIfNeeded)
        let needsSel = Selector(("setNeedsUpdateConstraints:"))

        guard let updateMethod = class_getInstanceMethod(NSWindow.self, updateSel),
            let needsMethod = class_getInstanceMethod(NSView.self, needsSel)
        else { return }

        typealias UpdateFn = @convention(c) (AnyObject, Selector) -> Void
        typealias NeedsFn = @convention(c) (AnyObject, Selector, Bool) -> Void

        let originalUpdateImp = method_getImplementation(updateMethod)
        let originalNeedsImp = method_getImplementation(needsMethod)

        let castedOriginalUpdate = unsafeBitCast(originalUpdateImp, to: UpdateFn.self)
        let castedOriginalNeeds = unsafeBitCast(originalNeedsImp, to: NeedsFn.self)

        let updateBlock: @convention(block) (AnyObject) -> Void = { window in
            MainActor.assumeIsolated {
                let previous = isUpdatingConstraints
                isUpdatingConstraints = true
                defer { isUpdatingConstraints = previous }
                castedOriginalUpdate(window, updateSel)
            }
        }

        let needsBlock: @convention(block) (AnyObject, Bool) -> Void = { view, flag in
            MainActor.assumeIsolated {
                if isUpdatingConstraints {
                    if let v = view as? NSView {
                        DispatchQueue.main.async { [weak v] in
                            v?.needsUpdateConstraints = flag
                        }
                    }
                } else {
                    castedOriginalNeeds(view, needsSel, flag)
                }
            }
        }

        method_setImplementation(updateMethod, imp_implementationWithBlock(updateBlock))
        method_setImplementation(needsMethod, imp_implementationWithBlock(needsBlock))
    }

    private static func installLayoutGuard() {
        let layoutSel = #selector(NSWindow.layoutIfNeeded)
        let needsLayoutSel = Selector(("setNeedsLayout:"))

        guard let layoutMethod = class_getInstanceMethod(NSWindow.self, layoutSel),
            let needsLayoutMethod = class_getInstanceMethod(NSView.self, needsLayoutSel)
        else { return }

        typealias LayoutFn = @convention(c) (AnyObject, Selector) -> Void
        typealias NeedsLayoutFn = @convention(c) (AnyObject, Selector, Bool) -> Void

        let originalLayoutImp = method_getImplementation(layoutMethod)
        let originalNeedsLayoutImp = method_getImplementation(needsLayoutMethod)

        let castedOriginalLayout = unsafeBitCast(originalLayoutImp, to: LayoutFn.self)
        let castedOriginalNeedsLayout = unsafeBitCast(originalNeedsLayoutImp, to: NeedsLayoutFn.self)

        let layoutBlock: @convention(block) (AnyObject) -> Void = { window in
            MainActor.assumeIsolated {
                let previous = isPerformingLayout
                isPerformingLayout = true
                defer { isPerformingLayout = previous }
                castedOriginalLayout(window, layoutSel)
            }
        }

        let needsLayoutBlock: @convention(block) (AnyObject, Bool) -> Void = { view, flag in
            MainActor.assumeIsolated {
                if isPerformingLayout {
                    if let v = view as? NSView {
                        DispatchQueue.main.async { [weak v] in
                            v?.needsLayout = flag
                        }
                    }
                } else {
                    castedOriginalNeedsLayout(view, needsLayoutSel, flag)
                }
            }
        }

        method_setImplementation(layoutMethod, imp_implementationWithBlock(layoutBlock))
        method_setImplementation(needsLayoutMethod, imp_implementationWithBlock(needsLayoutBlock))
    }

    private static func installDisplayGuard() {
        let displaySel = #selector(NSWindow.displayIfNeeded)
        let needsDisplaySel = Selector(("setNeedsDisplay:"))

        guard let displayMethod = class_getInstanceMethod(NSWindow.self, displaySel),
            let needsDisplayMethod = class_getInstanceMethod(NSView.self, needsDisplaySel)
        else { return }

        typealias DisplayFn = @convention(c) (AnyObject, Selector) -> Void
        typealias NeedsDisplayFn = @convention(c) (AnyObject, Selector, Bool) -> Void

        let originalDisplayImp = method_getImplementation(displayMethod)
        let originalNeedsDisplayImp = method_getImplementation(needsDisplayMethod)

        let castedOriginalDisplay = unsafeBitCast(originalDisplayImp, to: DisplayFn.self)
        let castedOriginalNeedsDisplay = unsafeBitCast(originalNeedsDisplayImp, to: NeedsDisplayFn.self)

        let displayBlock: @convention(block) (AnyObject) -> Void = { window in
            MainActor.assumeIsolated {
                let previous = isPerformingDisplay
                isPerformingDisplay = true
                defer { isPerformingDisplay = previous }
                castedOriginalDisplay(window, displaySel)
            }
        }

        let needsDisplayBlock: @convention(block) (AnyObject, Bool) -> Void = { view, flag in
            MainActor.assumeIsolated {
                if isPerformingDisplay {
                    if let v = view as? NSView {
                        DispatchQueue.main.async { [weak v] in
                            v?.needsDisplay = flag
                        }
                    }
                } else {
                    castedOriginalNeedsDisplay(view, needsDisplaySel, flag)
                }
            }
        }

        method_setImplementation(displayMethod, imp_implementationWithBlock(displayBlock))
        method_setImplementation(needsDisplayMethod, imp_implementationWithBlock(needsDisplayBlock))
    }
}

/// Dispatch the copied cleanup executable before any app model or storage is initialized.
@main enum GOATEntry {
    @MainActor static func main() {
        LayoutRecursionGuard.install()
        let arguments = CommandLine.arguments
        if arguments.count == 3, arguments[1] == "--goat-uninstall-helper" {
            exit(UninstallHelper.run(job: URL(fileURLWithPath: arguments[2], isDirectory: true)))
        }
        if ProcessInfo.processInfo.environment["GOAT_TEST_MODE"] == "1" {
            GOATApp.main()
            return
        }
        do {
            let lock = try MaintenanceGate.acquire(exclusive: false)
            defer { close(lock) }
            GOATApp.main()
        } catch {
            let alert = NSAlert()
            alert.messageText = "GOAT maintenance is in progress"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
