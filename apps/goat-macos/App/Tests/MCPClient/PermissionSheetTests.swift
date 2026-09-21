import AppKit
import SwiftUI
import XCTest

@testable import GOAT

final class PermissionSheetTests: XCTestCase {
    @MainActor func testReturnApprovesOnlyTheDisplayedChange() async throws {
        let model = AppModel.shared
        for dark in [false, true] {
            let approval = Task {
                await model.mcp.approvePenWrite(
                    tool: "pen_write_file",
                    preview:
                        "{\n  \"path\": \"src/main.ts\",\n  \"content\": \"export const ready = true;\\n\",\n  \"workspace\": \"/Users/example/Projects/My App\"\n}",
                    penName: "My App", allowsScopes: true)
            }
            for _ in 0..<100 where model.mcp.pendingPermission == nil { try await Task.sleep(for: .milliseconds(5)) }
            let request = try XCTUnwrap(model.mcp.pendingPermission)
            let view = PermissionSheet(request: request).environment(model)
                .environment(\.colorScheme, dark ? .dark : .light)
                .background(dark ? Color.black : Color.white)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 420, height: 380),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer {
                approval.cancel()
                model.mcp.cancelPendingPermission()
                window.contentView = nil
                window.close()
            }
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(350))
            host.layoutSubtreeIfNeeded()
            let key = try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil,
                    characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            window.sendEvent(key)
            for _ in 0..<100 where model.mcp.pendingPermission != nil { try await Task.sleep(for: .milliseconds(5)) }
            if model.mcp.pendingPermission != nil {
                XCTFail("Return must activate Allow Once without opening the scope menu")
                model.mcp.resolvePermission(.deny, requestID: request.id)
            }
            let choice = await approval.value
            XCTAssertEqual(choice, .allowOnce)
        }
    }
}
