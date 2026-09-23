import AppKit
import Darwin
import Foundation

/// Dispatch the copied cleanup executable before any app model or storage is initialized.
@main enum GOATEntry {
    @MainActor static func main() {
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
