import AppKit
import Foundation
import Herd
import Inference

extension AppModel {
    func consumeEngineSetupRequest() -> Bool {
        guard shouldPresentEngineSetup, needsEngineSetup else { return false }
        shouldPresentEngineSetup = false
        settingsTab = .engine
        return true
    }

    // MARK: Engine profiles (managed list, one active; engines.json, ADR-0021)

    /// CredentialStore key for a profile's API key (per-engine, never shared across engines).
    nonisolated static func keyStore(_ id: String) -> String { "engine.\(id).apiKey" }
    var activeKey: String? {
        activeEngineProfile.flatMap { engineCredentials[Self.keyStore($0.id)] }
    }

    func saveEngines(revision: UInt64) async -> Bool {
        guard engineStoreWritable else {
            dbWarning =
                "Engine settings are corrupt or unsafe. Repair engines.json before managed changes can be saved."
            return false
        }
        let file = EngineStore.File(
            active: activeEngineID.isEmpty ? nil : activeEngineID,
            engines: engineProfiles)
        let url = Home.enginesFile
        do {
            let saved = try await fileWorker.saveEngineFile(file, to: url, revision: revision)
            return saved && engineStoreRevision == revision
        } catch {
            dbWarning = "Engine settings were not saved: \(error.localizedDescription)"
            return false
        }
    }

    /// Re-read engines.json after a hand-edit (the in-app JSON editor), then re-probe the active one.
    func reloadEngines() async {
        guard startupPhase.hasLocalState, !shepherd.hasActiveTurn else { return }
        let revision = nextEngineStoreRevision()
        let url = Home.enginesFile
        let file: EngineStore.File
        do {
            switch try await fileWorker.loadEngineFile(from: url, revision: revision) {
            case .stale:
                return
            case .missing:
                file = EngineStore.File(active: nil, engines: [])
            case .loaded(let loaded):
                file = loaded
            }
        } catch {
            dbWarning = "Engine settings were not loaded: \(error.localizedDescription)"
            return
        }
        let keys = file.engines.map { Self.keyStore($0.id) }
        let credentials: [String: String]
        do {
            credentials = try await fileWorker.credentials(for: keys)
        } catch {
            dbWarning = "Credentials were not loaded: \(error.localizedDescription)"
            return
        }
        guard engineStoreRevision == revision, !shepherd.hasActiveTurn else { return }
        engineProfiles = file.engines
        engineStoreWritable = true
        engineCredentials = credentials
        if let active = file.active, engineProfiles.contains(where: { $0.id == active }) {
            activeEngineID = active
        } else {
            activeEngineID = engineProfiles.first?.id ?? ""
        }
        await refreshEngineApplicationAvailability()
        guard engineStoreRevision == revision else { return }
        scheduleEngineApply()
    }

    /// Add a new engine or update an existing one (matched by id); re-probes if it's the active one.
    @discardableResult
    func addOrUpdateEngine(_ profile: EngineProfile, connect: Bool = true) async -> Bool {
        guard startupPhase.hasLocalState,
            profile.id != activeEngineID || !shepherd.hasActiveTurn
        else { return false }
        let revision = nextEngineStoreRevision()
        let previous = engineProfiles
        let previousActiveID = activeEngineID
        if let i = engineProfiles.firstIndex(where: { $0.id == profile.id }) {
            engineProfiles[i] = profile
        } else {
            engineProfiles.append(profile)
        }
        if !engineProfiles.contains(where: { $0.id == activeEngineID }) { activeEngineID = profile.id }
        guard await saveEngines(revision: revision) else {
            if engineStoreRevision == revision {
                engineProfiles = previous
                activeEngineID = previousActiveID
            }
            return false
        }
        await refreshEngineApplicationAvailability()
        guard engineStoreRevision == revision else { return false }
        if connect && profile.id == activeEngineID { scheduleEngineApply() }
        return true
    }

    /// Remove an engine (and its stored key); if it was active, promote the first remaining one.
    func deleteEngine(id: String) async {
        guard startupPhase.hasLocalState,
            id != activeEngineID || !shepherd.hasActiveTurn
        else { return }
        let wasActive = id == activeEngineID
        let engineRevision = nextEngineStoreRevision()
        let previousProfiles = engineProfiles
        let previousActiveID = activeEngineID
        engineProfiles.removeAll { $0.id == id }
        let storeKey = Self.keyStore(id)
        if wasActive { activeEngineID = engineProfiles.first?.id ?? "" }
        let profileSaveAccepted = await saveEngines(revision: engineRevision)
        if !profileSaveAccepted, engineStoreRevision == engineRevision {
            if engineStoreRevision == engineRevision {
                engineProfiles = previousProfiles
                activeEngineID = previousActiveID
            }
            return
        }
        let credentialRevision = nextCredentialRevision(for: storeKey)
        do {
            let deleted = try await fileWorker.deleteCredentialIfEngineAbsent(
                storeKey, engineID: id, engineFileURL: Home.enginesFile,
                revision: credentialRevision)
            if deleted == true, credentialRevisions[storeKey] == credentialRevision {
                engineCredentials.removeValue(forKey: storeKey)
            }
        } catch {
            // The engine deletion is already durable. Keep the orphaned local key rather than
            // rolling the engine profile back across two independent files.
            dbWarning = "Engine removed, but its credential could not be deleted: \(error.localizedDescription)"
        }
        guard engineStoreRevision == engineRevision else { return }
        await refreshEngineApplicationAvailability()
        guard engineStoreRevision == engineRevision else { return }
        if wasActive { scheduleEngineApply() }
    }

    /// Make an engine the active one and re-probe it.
    func setActiveEngine(id: String) async {
        guard startupPhase.hasLocalState, !shepherd.hasActiveTurn, id != activeEngineID,
            engineProfiles.contains(where: { $0.id == id })
        else { return }
        let revision = nextEngineStoreRevision()
        let previous = activeEngineID
        activeEngineID = id
        guard await saveEngines(revision: revision) else {
            if engineStoreRevision == revision { activeEngineID = previous }
            return
        }
        scheduleEngineApply()
    }

    func scheduleEngineApply() {
        guard let intentRevision = beginEngineIntent() else { return }
        Task { await applyActiveEngine(intentRevision: intentRevision) }
    }

    /// Point the live engine actor at the active profile and refresh health.
    func applyActiveEngine(intentRevision: UInt64) async {
        guard engineIntentRevision == intentRevision else { return }
        let target = activeEngineProfile.flatMap { profile -> EngineLifecycleController.Target? in
            guard let url = URL(string: profile.url) else { return nil }
            let key = engineCredentials[Self.keyStore(profile.id)]
            return EngineLifecycleController.Target(
                profileID: profile.id,
                config: EngineConfig(
                    baseURL: url, apiKey: key,
                    name: profile.name, metadataDialect: profile.preset.metadataDialect,
                    requestStyle: profile.requestStyle))
        }
        guard let operation = await beginEngineOperation(for: intentRevision) else { return }
        guard let target else {
            endpoint = ""
            health = .offline("No engine selected")
            await finishEngineTransition(intentRevision: intentRevision, operation: operation)
            return
        }
        guard let resolution = await engineLifecycle.probe(target, for: operation) else {
            await finishEngineTransition(intentRevision: intentRevision, operation: operation)
            return
        }
        await publishEngine(
            resolution, intentRevision: intentRevision, operation: operation,
            persistDiscoveredURL: false)
    }

    /// Probe an engine without making it active (Add/Edit sheet's Test). `key` overrides the stored
    /// one so you can test a key you've typed but not yet saved.
    func testEngine(_ profile: EngineProfile, key: String? = nil) async -> EngineHealth {
        guard let url = URL(string: profile.url) else { return .offline("Bad URL") }
        let apiKey = key ?? engineCredentials[Self.keyStore(profile.id)]
        let probe = OpenAICompatEngine(
            config: EngineConfig(
                baseURL: url, apiKey: apiKey,
                name: profile.name, metadataDialect: profile.preset.metadataDialect,
                requestStyle: profile.requestStyle))
        return await probe.health()
    }

    /// Per-engine API key (in credentials.json, ADR-0012): read/write for a specific profile.
    func engineHasKey(_ id: String) -> Bool { engineCredentials[Self.keyStore(id)] != nil }
    @discardableResult
    func setEngineKey(_ key: String, for id: String, connect: Bool = true) async -> Bool {
        guard id != activeEngineID || !shepherd.hasActiveTurn else { return false }
        let storeKey = Self.keyStore(id)
        let revision = nextCredentialRevision(for: storeKey)
        do {
            let saved = try await fileWorker.setCredential(
                key, for: storeKey, revision: revision)
            guard saved, credentialRevisions[storeKey] == revision else { return false }
            if key.isEmpty {
                engineCredentials.removeValue(forKey: storeKey)
            } else {
                engineCredentials[storeKey] = key
            }
            if connect && id == activeEngineID { scheduleEngineApply() }
            return true
        } catch {
            dbWarning = "Credential was not saved: \(error.localizedDescription)"
            return false
        }
    }

    func nextEngineStoreRevision() -> UInt64 {
        engineStoreRevision &+= 1
        return engineStoreRevision
    }

    func nextCredentialRevision(for key: String) -> UInt64 {
        let revision = (credentialRevisions[key] ?? 0) &+ 1
        credentialRevisions[key] = revision
        return revision
    }

    /// The native model-manager app for the current engine, when its preset names one.
    var engineAppURL: URL? {
        if case .app(let path, _) = enginePreset.management,
            installedEngineApplicationPaths.contains(path)
        {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    func applicationExists(at path: String) async -> Bool {
        await fileWorker.applicationExists(at: path)
    }

    func refreshEngineApplicationAvailability() async {
        let paths = engineProfiles.compactMap { profile -> String? in
            guard case .app(let path, _) = profile.preset.management else { return nil }
            return path
        }
        let installed = await fileWorker.existingApplications(in: paths)
        let currentPaths = Set(
            engineProfiles.compactMap { profile -> String? in
                guard case .app(let path, _) = profile.preset.management else { return nil }
                return path
            })
        guard currentPaths == Set(paths) else { return }
        installedEngineApplicationPaths = installed
    }

    /// Open the current engine's manager app (e.g. oMLX), then re-probe once it's had a moment to wake.
    func openEngineApp() {
        guard let url = engineAppURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        Task {
            try? await Task.sleep(for: .seconds(3))
            await discover()
        }
    }

}
