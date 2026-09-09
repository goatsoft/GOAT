import Foundation
import GOATed
import Herd
import Hoofprint
import Observation

struct InstalledExtension: Identifiable, Sendable {
    let package: ExtensionPackage
    let penID: UUID?
    var enabled: Bool
    var issue: String?
    var id: String { package.manifest.id }
    var scope: ExtensionScope { penID.map(ExtensionScope.pen) ?? .application }
}

private struct StoredExtension: Codable {
    let archive: Data
    let penID: UUID?
    let enabled: Bool
}

enum UserExtensionError: LocalizedError {
    case duplicate, capacity, missing, busy
    var errorDescription: String? {
        switch self {
        case .duplicate: "This extension is already installed. Remove it before importing a replacement."
        case .capacity: "GOAT supports up to 16 user packages and 32 MiB of installed archives."
        case .missing: "The extension is no longer installed."
        case .busy: "Another extension change is still in progress."
        }
    }
}

/// All archive parsing and managed-file I/O occur off the main actor. A single owner-only record
/// holds the reviewed bytes and enabled/scope state, so partial imports cannot become executable.
actor UserExtensionStore {
    let root: URL
    init(root: URL) { self.root = root }

    func inspect(_ url: URL) throws -> ExtensionPackage {
        guard url.pathExtension.lowercased() == "goated",
            let bytes = try LocalFileStore.boundedDataIfPresent(at: url, maximumBytes: 8 * 1_024 * 1_024)
        else { throw PackageError.invalidArchive }
        return try ExtensionPackage(archive: bytes)
    }

    func load() throws -> ([InstalledExtension], [String]) {
        try LocalFileStore.ensureDirectory(at: root)
        let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard urls.count <= 16 else { throw UserExtensionError.capacity }
        var items: [InstalledExtension] = []
        var issues: [String] = []
        var total = 0
        for url in urls {
            do {
                guard let data = try LocalFileStore.ownerOnlyDataIfPresent(at: url, maximumBytes: 12 * 1_024 * 1_024)
                else { continue }
                let record = try JSONDecoder().decode(StoredExtension.self, from: data)
                total += record.archive.count
                guard total <= 32 * 1_024 * 1_024 else { throw UserExtensionError.capacity }
                let package = try ExtensionPackage(archive: record.archive)
                guard package.manifest.id == url.deletingPathExtension().lastPathComponent else {
                    throw PackageError.invalidManifest
                }
                items.append(InstalledExtension(package: package, penID: record.penID, enabled: record.enabled))
            } catch {
                issues.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (items, issues)
    }

    func save(_ item: InstalledExtension, new: Bool = false) throws {
        try LocalFileStore.ensureDirectory(at: root)
        let url = try location(item.id)
        if new, try LocalFileStore.regularFileExists(at: url) { throw UserExtensionError.duplicate }
        let bytes = try JSONEncoder().encode(
            StoredExtension(archive: item.package.archive, penID: item.penID, enabled: item.enabled))
        try LocalFileStore.writeOwnerOnly(bytes, to: url)
    }

    func remove(_ id: String) throws { try LocalFileStore.removeItem(at: location(id)) }

    func export(_ package: ExtensionPackage, to url: URL) throws {
        try LocalFileStore.writeOwnerOnly(package.archive, to: url)
    }

    private func location(_ id: String) throws -> URL {
        guard ExtensionPackage.validID(id) else { throw PackageError.invalidManifest }
        return root.appendingPathComponent(id + ".json")
    }
}

@MainActor @Observable
final class UserExtensionManager {
    private(set) var items: [InstalledExtension] = []
    private(set) var issues: [String] = []
    private(set) var busy = false
    private var loaded = false
    private var registrations: [String: Registration] = [:]
    let store: UserExtensionStore
    private let runtime: ExtensionRuntime
    private let activity: ActivityLog?

    init(
        runtime: ExtensionRuntime,
        root: URL = Home.url.appendingPathComponent("extensions/packages", isDirectory: true),
        activity: ActivityLog? = nil
    ) {
        self.runtime = runtime
        self.activity = activity
        store = UserExtensionStore(root: root)
    }

    func load() async {
        guard !loaded, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            (items, issues) = try await store.load()
            loaded = true
            for index in items.indices where items[index].enabled {
                do {
                    registrations[items[index].id] = try await runtime.activate(
                        items[index].package.extensionValue, scope: items[index].scope)
                } catch {
                    items[index].enabled = false
                    items[index].issue = "Could not activate this extension. Review it and try enabling again."
                }
            }
            sort()
        } catch { issues = [error.localizedDescription] }
    }

    func install(_ package: ExtensionPackage, penID: UUID?, enabled: Bool) async throws {
        if !loaded { await load() }
        guard loaded else { throw UserExtensionError.busy }
        guard !busy else { throw UserExtensionError.busy }
        guard !items.contains(where: { $0.id == package.manifest.id }) else { throw UserExtensionError.duplicate }
        guard items.count < 16,
            items.reduce(package.archive.count, { $0 + $1.package.archive.count }) <= 32 * 1_024 * 1_024
        else {
            throw UserExtensionError.capacity
        }
        busy = true
        defer { busy = false }
        var item = InstalledExtension(package: package, penID: penID, enabled: false)
        try await store.save(item, new: true)
        items.append(item)
        sort()
        loaded = true
        activity?.log(.info, "GOATed installed: \(item.id) \(item.package.manifest.version)")
        if enabled {
            let registration = try await runtime.activate(package.extensionValue, scope: item.scope)
            item.enabled = true
            do { try await store.save(item) } catch {
                try? await runtime.unregister(registration)
                throw error
            }
            activity?.log(.info, "GOATed enabled: \(item.id)")
            registrations[item.id] = registration
            if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
        }
    }

    func setEnabled(_ id: String, _ enabled: Bool) async throws {
        guard !busy else { throw UserExtensionError.busy }
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw UserExtensionError.missing }
        guard items[index].enabled != enabled else { return }
        busy = true
        defer { busy = false }
        var item = items[index]
        if enabled {
            let registration = try await runtime.activate(item.package.extensionValue, scope: item.scope)
            item.enabled = true
            do { try await store.save(item) } catch {
                try? await runtime.unregister(registration)
                throw error
            }
            registrations[id] = registration
        } else {
            // Persist first; a failed write cannot silently re-enable this extension next launch.
            item.enabled = false
            try await store.save(item)
            if let registration = registrations.removeValue(forKey: id) { try? await runtime.unregister(registration) }
        }
        item.issue = nil
        items[index] = item
        activity?.log(.info, "GOATed \(enabled ? "enabled" : "disabled"): \(id)")
    }

    func remove(_ id: String) async throws {
        try await setEnabled(id, false)
        guard !busy else { throw UserExtensionError.busy }
        busy = true
        defer { busy = false }
        try await store.remove(id)
        items.removeAll { $0.id == id }
        activity?.log(.info, "GOATed removed: \(id)")
    }

    private func sort() {
        items.sort { $0.package.manifest.name.localizedStandardCompare($1.package.manifest.name) == .orderedAscending }
    }
}
