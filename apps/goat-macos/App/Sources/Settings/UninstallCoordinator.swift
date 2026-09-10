import AppKit
import Darwin
import Foundation
import Observation

/// Shared by every window, so dismissing Settings does not lose the cancel action.
@MainActor @Observable final class UninstallCoordinator {
    static let shared = UninstallCoordinator()
    private(set) var pending = false
    private(set) var preparing = false
    private(set) var recovery: URL?
    var error: String?
    private var worker: Process?
    private var job: URL?

    func prepare(plan: DataManagementPlan, inventory: DataManagementInventory, model: AppModel) async {
        guard !pending, !preparing else { return }
        preparing = true
        defer { preparing = false }
        error = nil
        do {
            guard ProcessInfo.processInfo.environment["GOAT_TEST_MODE"] != "1" else {
                throw UninstallError.unsafe(
                    "This isolated preview cannot uninstall an app. Use the verified GOAT build when you intend to uninstall."
                )
            }
            guard model.startupPhase == .ready, model.activeTurnSessionID == nil,
                model.shepherd.pendingLeadCount == 0, !model.extensionsChanging, !model.userExtensions.busy,
                model.mcp.pendingPermission == nil, !model.filePermissions.isUpdating
            else {
                throw UninstallError.unsafe("Finish active work and pending approvals before preparing uninstall.")
            }
            guard let home = inventory.locations.first(where: { $0.id == "home" })?.url,
                let database = inventory.locations.first(where: { $0.id == "database" })?.url,
                let app = inventory.locations.first(where: { $0.id == "app" })?.url
            else {
                throw UninstallError.unsafe("Could not identify the running installation.")
            }
            let fm = FileManager.default
            let destination = (plan.backupURL ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
                .resolvingSymlinksInPath().appendingPathComponent("GOAT Recovery \(UUID().uuidString)")
            let initial = UninstallRequest(
                parentPID: getpid(), home: home, support: database.deletingLastPathComponent(),
                app: app, cli: plan.cliURL, preferencesDomain: inventory.preferencesDomain,
                keepPreferences: plan.keepPreferences, removedGroups: Set(plan.groups.map(\.rawValue)),
                protectedPaths: model.pens.flatMap { pen in
                    pen.files.map { URL(fileURLWithPath: $0.path) }
                        + (pen.workspace.map { [URL(fileURLWithPath: $0.path)] } ?? [])
                }, recovery: destination)
            let staging = try await Task.detached(priority: .userInitiated) {
                var request = initial
                let fm = FileManager.default
                try request.captureRoots()
                try request.validateRoots()
                let staging = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(
                    "goat-uninstall-\(UUID().uuidString)")
                try fm.createDirectory(
                    at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                do {
                    request.roots[destination.path] = try UninstallIdentity.read(destination)
                    _ = try UninstallOperation.inventory(request)
                    try fm.createDirectory(
                        at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    try UninstallHelperBundle.copy(from: app, to: staging)
                    let planURL = staging.appendingPathComponent("request.json")
                    try JSONEncoder().encode(request).write(to: planURL)
                    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: planURL.path)
                    return staging
                } catch {
                    try? fm.removeItem(at: staging)
                    try? fm.removeItem(at: destination)
                    throw error
                }
            }.value
            let process = Process()
            process.executableURL = UninstallHelperBundle.executable(in: staging)
            process.arguments = ["--goat-uninstall-helper", staging.path]
            // ADR-0081: preserve the signed app bundle, then use one fixed local maintenance mode.
            // No shell, user command, service registration or network operation is involved.
            process.environment = ["TMPDIR": fm.temporaryDirectory.path, "PATH": "/usr/bin:/bin"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] completed in
                let status = completed.terminationStatus
                Task { @MainActor in
                    guard let self, self.pending, self.job == staging else { return }
                    self.pending = false
                    self.error =
                        status == 0
                        ? "The uninstall was cancelled."
                        : "The cleanup helper stopped. Review the recovery folder before trying again."
                    self.worker = nil
                }
            }
            do { try process.run() } catch {
                try? fm.removeItem(at: staging)
                try? fm.removeItem(at: destination)
                throw error
            }
            worker = process
            job = staging
            recovery = destination
            pending = true
        } catch { self.error = error.localizedDescription }
    }

    func cancel() {
        guard pending, let job else { return }
        // The helper checks this only while the parent is alive; it never mutates source data then.
        do {
            try Data().write(to: job.appendingPathComponent("cancel"), options: .atomic)
            pending = false
            worker = nil
            self.job = nil
        } catch { self.error = "Could not cancel uninstall: \(error.localizedDescription)" }
    }
}

enum UninstallHelperBundle {
    static func executable(in job: URL) -> URL {
        job.appendingPathComponent("GOAT.app/Contents/MacOS/GOAT")
    }

    static func copy(from app: URL, to job: URL) throws {
        let destination = job.appendingPathComponent("GOAT.app", isDirectory: true)
        try FileManager.default.copyItem(at: app, to: destination)
        guard Bundle(url: destination)?.executableURL?.standardizedFileURL == executable(in: job).standardizedFileURL
        else { throw UninstallError.unsafe("The copied cleanup app could not be identified.") }
        // The main executable's signature binds Info.plist and sealed bundle resources.
        // Copying just the executable passes ad-hoc tests but fails Developer ID validation.
        _ = try UninstallRequest.signature(destination)
    }
}

enum MaintenanceGate {
    static func acquire(exclusive: Bool, path: String = "/private/tmp/dev.leet.goat-maintenance-\(getuid()).lock")
        throws -> Int32
    {
        let descriptor = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw UninstallError.unsafe("Cannot open the GOAT maintenance lock.") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
            info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
            flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0
        else {
            close(descriptor)
            throw UninstallError.unsafe(
                "Another GOAT copy or cleanup operation is using this account. Finish that operation first.")
        }
        return descriptor
    }
}

@MainActor enum UninstallHelper {
    static func run(job: URL) -> Int32 {
        umask(0o077)
        let fm = FileManager.default
        var recovery: URL?
        do {
            let identity = try UninstallIdentity.read(job)
            let permissions = try fm.attributesOfItem(atPath: job.path)[.posixPermissions] as? NSNumber
            guard identity.kind == S_IFDIR, permissions?.intValue == 0o700,
                job.lastPathComponent.hasPrefix("goat-uninstall-"),
                try UninstallRequest.physicalPath(job.deletingLastPathComponent())
                    == UninstallRequest.physicalPath(fm.temporaryDirectory),
                let executable = Bundle.main.executableURL,
                try UninstallRequest.physicalPath(executable)
                    == UninstallRequest.physicalPath(UninstallHelperBundle.executable(in: job)),
                try UninstallRequest.physicalPath(Bundle.main.bundleURL)
                    == UninstallRequest.physicalPath(job.appendingPathComponent("GOAT.app"))
            else {
                throw UninstallError.unsafe("The private cleanup job could not be validated.")
            }
            defer { try? fm.removeItem(at: job) }
            let requestURL = job.appendingPathComponent("request.json")
            _ = try UninstallIdentity.read(requestURL)
            let request = try JSONDecoder().decode(UninstallRequest.self, from: Data(contentsOf: requestURL))
            try request.validateRoots()
            _ = try UninstallIdentity.read(request.recovery)
            recovery = request.recovery
            guard request.parentPID > 1, getppid() == request.parentPID else {
                throw UninstallError.unsafe("The launching GOAT process could not be verified.")
            }
            let deadline = Date().addingTimeInterval(3600)
            while kill(request.parentPID, 0) == 0 {
                if fm.fileExists(atPath: job.appendingPathComponent("cancel").path) { return 0 }
                guard Date() < deadline else {
                    throw UninstallError.unsafe("Uninstall expired after one hour. GOAT and its data were kept.")
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
            if fm.fileExists(atPath: job.appendingPathComponent("cancel").path) { return 0 }
            let lock = try MaintenanceGate.acquire(exclusive: true)
            defer { close(lock) }
            // Older releases do not take the maintenance lock. Refuse to clean up while one is visible.
            guard
                !NSWorkspace.shared.runningApplications.contains(where: {
                    $0.processIdentifier != getpid() && ($0.bundleIdentifier?.hasPrefix("dev.leet.goat") == true)
                })
            else { throw UninstallError.unsafe("Another GOAT copy is still running. No cleanup was started.") }
            var trashed: [String: String] = [:]
            try UninstallOperation.execute(request) { url in
                var destination: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &destination)
                if let destination { trashed[url.path] = destination.path }
                try JSONEncoder().encode(trashed).write(
                    to: request.recovery.appendingPathComponent("trash.json"), options: .atomic)
            }
            try """
            GOAT was moved to Trash. Selected data is in this private recovery folder.
            plan.json lists original and recovery paths; completed.json records successful file moves.
            Preferences, when selected, are in preferences.plist. Keep this folder private.
            To recover: reinstall a compatible GOAT version, keep it closed, and restore reviewed files to their recorded paths. Never overwrite newer data without reviewing it. Restore preferences with macOS defaults import only while GOAT is closed.
            Shared roots, empty directories, unknown entries and symbolic links were kept. External workspaces, remote memory and model engines were not removed.
            """.write(to: request.recovery.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(request.recovery)
            return 0
        } catch {
            if let recovery {
                try?
                    ("Uninstall stopped: \(error.localizedDescription)\nReview plan.json, completed.json and the data folder for any completed moves. Do not discard this recovery folder.")
                    .write(
                        to: recovery.appendingPathComponent("UNINSTALL-STOPPED.txt"), atomically: true, encoding: .utf8)
                NSWorkspace.shared.open(recovery)
            }
            return 1
        }
    }
}
