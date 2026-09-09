import Foundation

/// Bundle identity is generated from release.json. Missing metadata stays visibly unknown.
enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown version"
    }
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }
    static var codename: String {
        Bundle.main.infoDictionary?["GOATCodename"] as? String ?? "Unknown codename"
    }

    /// e.g. `0.1 (Kid)`, while the bundle retains canonical `0.1.0`.
    static var versionName: String { releaseLabel(version: version, codename: codename) }
    static var diagnostics: String {
        buildDetails(channel: Bundle.main.infoDictionary?["GOATReleaseChannel"] as? String, build: build)
    }
    static var full: String { "\(versionName) · \(diagnostics)" }

    static func buildDetails(channel: String?, build: String) -> String {
        switch channel {
        case "Release": "Build \(build)"
        case "Candidate": "Candidate · build \(build)"
        case "Development": "Development · build \(build)"
        default: "Unknown channel · build \(build)"
        }
    }

    static func releaseLabel(version: String, codename: String) -> String {
        let components = version.split(separator: ".")
        let displayVersion =
            components.count == 3 && components.last == "0"
            ? components.dropLast().joined(separator: ".") : version
        return "\(displayVersion) (\(codename))"
    }
}
