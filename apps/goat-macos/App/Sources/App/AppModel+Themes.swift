import Caprine
import Foundation

extension AppModel {
    // MARK: Theme CRUD (user themes are folders; ThemeStore, ADR-0022)

    func reloadThemes() async {
        let revision = nextThemeStoreRevision()
        do {
            guard let themes = try await fileWorker.loadThemes(revision: revision) else { return }
            guard themeStoreRevision == revision, !Task.isCancelled else { return }
            userThemes = themes
        } catch {
            dbWarning = "Themes were not loaded: \(error.localizedDescription)"
        }
    }

    /// Save a user theme (optionally with a preview image) and select it.
    func saveTheme(_ spec: ThemeSpec, previewData: Data? = nil) async {
        await saveThemeOnWorker(spec, previewData: previewData)
    }

    private func saveThemeOnWorker(_ spec: ThemeSpec, previewData: Data?) async {
        let revision = nextThemeStoreRevision()
        do {
            guard
                let result = try await fileWorker.saveTheme(
                    spec, previewData: previewData, revision: revision)
            else { return }
            guard themeStoreRevision == revision, !Task.isCancelled else { return }
            guard let saved = result.saved else { return }
            userThemes = result.themes
            themeID = saved.id
        } catch {
            dbWarning = "Theme was not saved: \(error.localizedDescription)"
            if themeStoreRevision == revision { await reloadThemes() }
        }
    }

    func deleteTheme(id: String) async {
        let revision = nextThemeStoreRevision()
        do {
            guard let themes = try await fileWorker.deleteTheme(id: id, revision: revision) else {
                return
            }
            guard themeStoreRevision == revision, !Task.isCancelled else { return }
            userThemes = themes
            if themeID == id { themeID = "system" }
        } catch {
            dbWarning = "Theme was not deleted: \(error.localizedDescription)"
            if themeStoreRevision == revision { await reloadThemes() }
        }
    }

    /// Duplicate any theme (built-in or user) into a new editable user theme, then select it.
    func duplicateTheme(from spec: ThemeSpec) async {
        // The System theme is a follow-the-OS alias, so seed a duplicate from a concrete base.
        let source = spec.appearance == .system ? (spec.isDark ? ThemeCatalog.midnight : ThemeCatalog.light) : spec
        let revision = nextThemeStoreRevision()
        do {
            guard
                let result = try await fileWorker.duplicateAndSaveTheme(
                    source, appearance: source.appearance, revision: revision)
            else { return }
            guard themeStoreRevision == revision, !Task.isCancelled else { return }
            guard let saved = result.saved else { return }
            userThemes = result.themes
            themeID = saved.id
        } catch {
            dbWarning = "Theme was not duplicated: \(error.localizedDescription)"
            if themeStoreRevision == revision { await reloadThemes() }
        }
    }

    /// Import a pasted GTF theme; returns the new theme's name (or throws on bad JSON).
    @discardableResult
    func importTheme(json: String) async throws -> String {
        let revision = nextThemeStoreRevision()
        do {
            guard let result = try await fileWorker.importAndSaveTheme(from: json, revision: revision)
            else { throw CancellationError() }
            guard themeStoreRevision == revision, !Task.isCancelled else {
                throw CancellationError()
            }
            guard let saved = result.saved else { throw CancellationError() }
            userThemes = result.themes
            themeID = saved.id
            return saved.name
        } catch {
            if themeStoreRevision == revision { await reloadThemes() }
            throw error
        }
    }

    func setThemePreview(id: String, imageData: Data) async {
        guard let spec = userThemes.first(where: { $0.id == id }) else { return }
        await saveThemeOnWorker(spec, previewData: imageData)
    }

    private func nextThemeStoreRevision() -> UInt64 {
        themeStoreRevision &+= 1
        return themeStoreRevision
    }

}
