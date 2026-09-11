import Foundation

/// Settings choices. This model has no reset, backup, removal or process-control operations.
struct DataManagementPlan {
    enum Action: String, CaseIterable, Identifiable {
        case preferences = "Reset preferences"
        case uninstall = "Uninstall GOAT"
        var id: Self { self }
    }

    enum Group: String, CaseIterable, Identifiable, Sendable {
        case chats = "Chats and attachments"
        case connections = "Connections and credentials"
        case memory = "Local memory"
        case customizations = "Skills, themes and extensions"
        case pens = "Pen metadata and instructions"
        var id: Self { self }

        var explanation: String {
            switch self {
            case .chats: "Keep the chat database and its attachments together."
            case .connections: "Reconnecting will require your profiles and credentials again."
            case .memory: "Global and Pen memory stored on this Mac. Remote banks are kept."
            case .customizations: "Includes custom files and extension state, not just caches."
            case .pens:
                "Includes chats and attachments to preserve their Pen relationships. External workspaces are kept."
            }
        }
    }

    enum UninstallMode: String, CaseIterable, Identifiable {
        case partial = "Partial uninstall"
        case all = "Uninstall all"
        var id: Self { self }
    }

    var action: Action = .preferences {
        didSet {
            if action == .uninstall && oldValue != .uninstall { uninstallMode = .partial }
        }
    }
    private(set) var groups: Set<Group> = []
    var keepPreferences = false
    var backupURL: URL?
    var cliURL: URL?

    var uninstallMode: UninstallMode {
        get { !keepPreferences && groups == Set(Group.allCases) ? .all : .partial }
        set {
            keepPreferences = false
            groups = newValue == .all ? Set(Group.allCases) : []
        }
    }

    func backupWarning(inventory: DataManagementInventory) -> String? {
        guard let backupURL else { return nil }
        let destination = backupURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let protected = inventory.locations.filter { ["home", "database", "app"].contains($0.id) }.map {
            ($0.id == "database" ? $0.url.deletingLastPathComponent() : $0.url)
                .resolvingSymlinksInPath().standardizedFileURL.pathComponents
        }
        guard protected.contains(where: { destination.starts(with: $0) }) else { return nil }
        return "Choose a backup folder outside GOAT Home, Application Support and the app itself."
    }

    mutating func select(_ group: Group, included: Bool) {
        if included {
            groups.insert(group)
            if group == .pens { groups.insert(.chats) }
        } else {
            groups.remove(group)
            if group == .chats { groups.remove(.pens) }
        }
    }

    var affected: [String] {
        switch action {
        case .preferences:
            [
                "Theme and Dock icon: System; transparency: 40%; animations: on",
                "Reading fonts: Theme; chat size: 14; code size: 13",
                "New-chat effort: Trot; automatic chat titles: on",
                "Pens overview: Grid; Settings always on top: on",
            ]
        case .uninstall:
            ["The selected GOAT app copy"] + (cliURL == nil ? [] : ["The separately selected CLI copy"])
                + Group.allCases.filter { groups.contains($0) }.map(\.rawValue)
                + (keepPreferences ? [] : ["macOS app preferences and saved window state"])
        }
    }

    var kept: [String] {
        var result = [
            "External Pen workspaces and project files", "Model engines, remote services and Hindsight banks",
        ]
        switch action {
        case .preferences:
            result += [
                "GOAT Home location", "Connections and credentials", "Chats, attachments, Pens and local files",
                "Privacy rules, tool permissions and extension settings", "Window positions and presentation unlock",
            ]
        case .uninstall:
            result += Group.allCases.filter { !groups.contains($0) }.map(\.rawValue)
            if keepPreferences { result += ["macOS app preferences and saved window state"] }
            result += ["Unrecognised files, shared folders and linked targets"]
            if cliURL == nil { result += ["Any separately installed CLI"] }
        }
        return result
    }

    var removesHomeData: Bool {
        get { groups.isSuperset(of: [.connections, .memory, .customizations, .pens]) }
        set {
            for group in [Group.connections, .memory, .customizations, .pens] {
                select(group, included: newValue)
            }
        }
    }

}

struct DataManagementInventory: Sendable {
    struct Location: Identifiable, Sendable {
        enum Status: String, Sendable {
            case unchecked = "Not inspected"
            case folder = "Folder"
            case file = "File"
            case missing = "Not found"
            case linked = "Symbolic link, keep target"
            case unavailable = "Could not inspect"
        }
        let id: String
        let title: String
        let url: URL
        var status: Status = .unchecked
    }

    let homeSource: String
    let preferencesDomain: String
    var locations: [Location]

    init(home: URL, support: URL, app: URL, homeSource: String, preferencesDomain: String) {
        self.homeSource = homeSource
        self.preferencesDomain = preferencesDomain
        locations = [
            Location(id: "home", title: "GOAT Home", url: home),
            Location(
                id: "config", title: "Connections, model preferences, credentials and themes", url: home.appendingPathComponent("config")),
            Location(id: "memory", title: "Global local memory", url: home.appendingPathComponent("memory")),
            Location(
                id: "pens", title: "Pen folders, instructions and local memory",
                url: home.appendingPathComponent("projects")),
            Location(id: "skills", title: "Global skills", url: home.appendingPathComponent("skills")),
            Location(
                id: "extensions", title: "Extension files and state", url: home.appendingPathComponent("extensions")),
            Location(
                id: "database", title: "Chat database (keep WAL/SHM companions)",
                url: support.appendingPathComponent("goat.sqlite")),
            Location(id: "attachments", title: "Chat attachments", url: support.appendingPathComponent("Attachments")),
            Location(id: "app", title: "This GOAT app copy", url: app),
        ]
    }

    /// Metadata only: never opens file contents or enumerates folders.
    func inspected() -> Self {
        var result = self
        for index in result.locations.indices {
            let url = result.locations[index].url
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                switch attributes[.type] as? FileAttributeType {
                case .typeSymbolicLink: result.locations[index].status = .linked
                case .typeDirectory: result.locations[index].status = .folder
                default: result.locations[index].status = .file
                }
            } catch {
                let error = error as NSError
                result.locations[index].status =
                    error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileReadNoSuchFile.rawValue
                    ? .missing : .unavailable
            }
        }
        return result
    }
}
