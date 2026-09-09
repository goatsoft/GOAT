import Foundation
import Herd

/// Stores each user theme in `~/.goat/config/themes/<id>/`, with `theme.json` and an optional
/// `preview.png` (docs/THEMES.md, ADR-0022). Built-in themes are defined in code.
public enum ThemeStore {
    public static var root: URL { Home.themesDir }

    public static func all() throws -> [ThemeSpec] {
        try all(in: root)
    }

    static func all(in root: URL) throws -> [ThemeSpec] {
        let specs = try LocalFileStore.childDirectories(in: root).map {
            try spec(inFolder: $0, root: root)
        }
        let ids = specs.map(\.id)
        guard Set(ids).count == ids.count else {
            throw LocalStoreError.invalidData(
                path: root.path, reason: "theme IDs must be unique")
        }
        return specs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func folder(for id: String) -> URL? {
        try? folder(for: id, in: root)
    }

    static func folder(for id: String, in root: URL) throws -> URL {
        try validateThemeID(id)
        let folder = root.appendingPathComponent(id, isDirectory: true)
        try LocalFileStore.requireContained(folder, in: root)
        return folder
    }

    public static func previewURL(for spec: ThemeSpec) -> URL? {
        guard let preview = spec.preview, !preview.isEmpty else { return nil }
        guard let folder = folder(for: spec.id) else { return nil }
        do {
            try LocalFileStore.validateComponent(preview, label: "preview filename")
            let url = folder.appendingPathComponent(preview)
            try LocalFileStore.requireContained(url, in: folder)
            return try LocalFileStore.regularFileExists(at: url) ? url : nil
        } catch {
            return nil
        }
    }

    /// Write a theme; when `previewData` is given, save it as `preview.png` and point the spec at it.
    @discardableResult
    public static func save(_ spec: ThemeSpec, previewData: Data? = nil) throws -> ThemeSpec {
        try save(spec, previewData: previewData, in: root)
    }

    @discardableResult
    static func save(_ spec: ThemeSpec, previewData: Data? = nil, in root: URL) throws -> ThemeSpec {
        var spec = spec
        try validateTheme(spec, path: spec.id, validateID: true)
        spec.schema = ThemeSpec.schemaVersion
        guard !ThemeCatalog.isBuiltin(spec.id) else {
            throw LocalStoreError.unsafePath(
                path: spec.id, reason: "built-in themes are read-only")
        }
        let dir = try folder(for: spec.id, in: root)
        try LocalFileStore.ensureDirectory(at: root)
        if try LocalFileStore.directoryExists(at: dir) {
            let staging = try LocalFileStore.makeStagingCopy(of: dir, in: root)
            do {
                let saved = try write(spec, previewData: previewData, to: staging)
                try LocalFileStore.commitReplacingDirectory(staging, at: dir, in: root)
                return saved
            } catch {
                try? LocalFileStore.removeItem(at: staging)
                throw error
            }
        }
        let staging = try LocalFileStore.makeStagingDirectory(in: root)
        do {
            let saved = try write(spec, previewData: previewData, to: staging)
            try LocalFileStore.commitNewDirectory(staging, to: dir, in: root)
            return saved
        } catch {
            try? LocalFileStore.removeItem(at: staging)
            throw error
        }
    }

    private static func write(
        _ original: ThemeSpec, previewData: Data?, to dir: URL
    ) throws -> ThemeSpec {
        var spec = original
        try LocalFileStore.ensureDirectory(at: dir)
        if let previewData {
            let file = dir.appendingPathComponent("preview.png")
            try LocalFileStore.write(previewData, to: file)
            spec.preview = "preview.png"
        } else if let preview = spec.preview, !preview.isEmpty {
            try LocalFileStore.validateComponent(preview, label: "preview filename")
            let previewURL = dir.appendingPathComponent(preview)
            try LocalFileStore.requireContained(previewURL, in: dir)
            guard try LocalFileStore.regularFileExists(at: previewURL) else {
                throw LocalStoreError.invalidData(
                    path: previewURL.path, reason: "declared preview file is missing")
            }
        }
        try writeJSON(spec, to: dir.appendingPathComponent("theme.json"))
        return spec
    }

    public static func delete(id: String) throws {
        try delete(id: id, in: root)
    }

    static func delete(id: String, in root: URL) throws {
        guard !ThemeCatalog.isBuiltin(id) else {
            throw LocalStoreError.unsafePath(
                path: id, reason: "built-in themes are read-only")
        }
        let folder = try folder(for: id, in: root)
        try LocalFileStore.removeItem(at: folder)
    }

    /// The single-object JSON for sharing a theme (preview travels as a separate file).
    public static func exportJSON(_ spec: ThemeSpec) -> String {
        var spec = spec
        spec.schema = ThemeSpec.schemaVersion
        spec.preview = nil
        return ThemeCatalog.json(for: spec)
    }

    /// Parse a pasted GTF object into a saveable theme with a unique, non-built-in id (renaming on
    /// collision so a shared theme can never clobber a built-in or an existing user theme).
    public static func makeImportable(from json: String) throws -> ThemeSpec {
        guard let data = json.data(using: .utf8) else { throw ThemeError.notJSON }
        guard var spec = try? JSONDecoder().decode(ThemeSpec.self, from: data) else { throw ThemeError.notJSON }
        try validateTheme(spec, path: "imported theme", validateID: false)
        spec.id = try uniqueID(base: spec.id.isEmpty ? slug(spec.name) : spec.id)
        spec.preview = nil
        return spec
    }

    /// A fresh editable copy of any theme (built-in or user), with a new id and name. Not yet saved.
    public static func prepareDuplicate(
        of spec: ThemeSpec, appearance: ThemeSpec.Appearance? = nil
    ) throws -> ThemeSpec {
        var copy = spec
        copy.id = try uniqueID(base: "\(slug(spec.name))-mine")
        copy.name = "\(spec.name) Copy"
        if let appearance { copy.appearance = appearance }
        copy.author = nil
        copy.description = nil
        copy.preview = nil
        return copy
    }

    // MARK: Migration (single themes.json → folders)

    /// One-time move of the old `themes.json` array into per-theme folders. Built-in overrides in
    /// that file become new user themes (suffixed) rather than editing a built-in (ADR-0022).
    public static func migrateLegacyFileIfNeeded() throws {
        let legacy = Home.configDir.appendingPathComponent("themes.json")
        let marker = Home.configDir.appendingPathComponent(".themes-v1-migrated")
        try migrateLegacyFileIfNeeded(legacy: legacy, marker: marker, root: root)
    }

    static func migrateLegacyFileIfNeeded(legacy: URL, marker: URL, root: URL) throws {
        if try LocalFileStore.dataIfPresent(at: marker) != nil { return }
        guard let data = try LocalFileStore.dataIfPresent(at: legacy) else { return }
        let specs: [ThemeSpec]
        do {
            specs = try JSONDecoder().decode([ThemeSpec].self, from: data)
        } catch {
            throw LocalStoreError.invalidData(
                path: legacy.path, reason: error.localizedDescription)
        }
        var existing = Dictionary(uniqueKeysWithValues: try all(in: root).map { ($0.id, $0) })
        for var spec in specs {
            if let builtin = ThemeCatalog.builtins.first(where: { $0.id == spec.id }) {
                // The old editor seeded exact copies of the built-ins; skip those (nothing to keep).
                if spec == builtin { continue }
                // A genuinely customized built-in becomes its own theme (built-ins are read-only now).
                spec.id = "\(spec.id)-custom"
                spec.name = "\(spec.name) (custom)"
            }
            spec.preview = nil
            var base = slug(spec.id)
            if base.isEmpty { base = slug(spec.name) }
            if base.isEmpty { base = "theme" }
            var candidate = base
            var suffix = 2
            while true {
                var expected = spec
                expected.id = candidate
                expected.schema = ThemeSpec.schemaVersion
                if let found = existing[candidate] {
                    if found == expected { break }
                    candidate = "\(base)-\(suffix)"
                    suffix += 1
                    continue
                }
                spec.id = candidate
                let saved = try save(spec, in: root)
                existing[saved.id] = saved
                break
            }
        }
        // A durable marker makes the migration resumable and prevents delete-all from resurrecting
        // the legacy array. If interrupted before this write, equivalent completed entries are
        // recognized above and skipped on the next launch.
        try LocalFileStore.write(Data("1\n".utf8), to: marker)
    }

    // MARK: Internals

    static func spec(inFolder dir: URL, root: URL? = nil) throws -> ThemeSpec {
        if let root { try LocalFileStore.requireContained(dir, in: root) }
        let json = dir.appendingPathComponent("theme.json")
        guard let data = try LocalFileStore.dataIfPresent(at: json) else {
            throw LocalStoreError.invalidData(
                path: json.path, reason: "theme.json is missing")
        }
        let spec: ThemeSpec
        do {
            spec = try JSONDecoder().decode(ThemeSpec.self, from: data)
        } catch {
            throw LocalStoreError.invalidData(
                path: json.path, reason: error.localizedDescription)
        }
        try validateTheme(spec, path: json.path, validateID: true)
        guard spec.id == dir.lastPathComponent else {
            throw LocalStoreError.invalidData(
                path: json.path, reason: "theme ID must match its folder name")
        }
        guard !ThemeCatalog.isBuiltin(spec.id) else {
            throw LocalStoreError.invalidData(
                path: json.path, reason: "user theme cannot replace a built-in theme")
        }
        if let preview = spec.preview, !preview.isEmpty {
            try LocalFileStore.validateComponent(preview, label: "preview filename")
            let previewURL = dir.appendingPathComponent(preview)
            try LocalFileStore.requireContained(previewURL, in: dir)
            guard try LocalFileStore.regularFileExists(at: previewURL) else {
                throw LocalStoreError.invalidData(
                    path: previewURL.path, reason: "declared preview file is missing")
            }
        }
        return spec
    }

    private static func writeJSON(_ spec: ThemeSpec, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(spec)
        } catch {
            throw LocalStoreError.invalidData(
                path: url.path, reason: error.localizedDescription)
        }
        guard data.count <= LocalFileStore.maximumManagedFileBytes else {
            throw LocalStoreError.invalidData(
                path: url.path, reason: "theme metadata exceeds the permitted byte count")
        }
        try LocalFileStore.write(data, to: url)
    }

    private static func validateThemeID(_ id: String) throws {
        let isSlug =
            !id.isEmpty && id.count <= 128
            && id.unicodeScalars.allSatisfy { scalar in
                let value = scalar.value
                return (97...122).contains(value) || (48...57).contains(value) || value == 45
            }
        guard isSlug else {
            throw LocalStoreError.unsafePath(
                path: id, reason: "theme ID must match [a-z0-9-]+")
        }
    }

    private static func validateTheme(
        _ spec: ThemeSpec, path: String, validateID: Bool
    ) throws {
        if validateID { try validateThemeID(spec.id) }
        guard spec.schema == nil || spec.schema == ThemeSpec.schemaVersion else {
            throw LocalStoreError.invalidData(
                path: path, reason: "unsupported theme schema \(spec.schema ?? -1)")
        }
        for font in [spec.fonts?.chat, spec.fonts?.code].compactMap({ $0 }) {
            // PostScript names or system aliases only, never a path, URL or font payload.
            let permitted = CharacterSet(
                charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.")
            guard !font.isEmpty, font.utf8.count <= 128,
                font.unicodeScalars.allSatisfy({ permitted.contains($0) }), !font.hasPrefix(".")
            else {
                throw LocalStoreError.invalidData(
                    path: path,
                    reason:
                        "theme fonts must be system aliases or PostScript names (up to 128 characters), not paths or URLs"
                )
            }
        }
        guard !spec.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalStoreError.invalidData(path: path, reason: "theme name cannot be empty")
        }
        let colors = [
            spec.bg, spec.surface, spec.ink, spec.muted, spec.accent,
            spec.accent2, spec.glow, spec.selection, spec.tint,
        ]
        guard colors.allSatisfy(isHexColor) else {
            throw LocalStoreError.invalidData(
                path: path, reason: "theme colors must use #RRGGBB")
        }
        guard spec.washOpacity.isFinite, (0...1).contains(spec.washOpacity),
            spec.bgOpacity.isFinite, (0...1).contains(spec.bgOpacity),
            spec.intensity.isFinite, (0.5...2).contains(spec.intensity)
        else {
            throw LocalStoreError.invalidData(
                path: path, reason: "theme numeric values are outside the supported range")
        }
    }

    private static func isHexColor(_ color: String) -> Bool {
        let scalars = Array(color.unicodeScalars)
        guard scalars.count == 7, scalars[0].value == 35 else { return false }
        return scalars.dropFirst().allSatisfy { scalar in
            let value = scalar.value
            return (48...57).contains(value) || (65...70).contains(value) || (97...102).contains(value)
        }
    }

    private static func uniqueID(base: String) throws -> String {
        let taken = Set(try all().map(\.id)).union(ThemeCatalog.builtinIDs)
        var candidate = slug(base)
        if candidate.isEmpty { candidate = "theme" }
        guard taken.contains(candidate) else { return candidate }
        var n = 2
        while taken.contains("\(candidate)-\(n)") { n += 1 }
        return "\(candidate)-\(n)"
    }

    private static func slug(_ s: String) -> String {
        var out = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { acc, ch in
                if ch == "-" && acc.hasSuffix("-") { return }
                acc.append(ch)
            }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return out
    }

    public enum ThemeError: LocalizedError {
        case notJSON
        public var errorDescription: String? { "That doesn't look like a GOAT theme (JSON)." }
    }
}
