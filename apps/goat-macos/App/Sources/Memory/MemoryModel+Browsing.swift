import Foundation
import Herd
import Hindsight
import Memory

extension MemoryModel {
    func browserEntries(forProjectID projectID: UUID?, limit: Int = 100) async throws -> [MemoryBrowserEntry] {
        let context = storageContext(forProjectID: projectID)
        if isUsingHindsight(forProjectID: projectID) {
            let providerID = providerID(forProjectID: projectID)
            do {
                return try await hindsightStore(forProjectID: projectID).entries(limit: limit)
            } catch {
                hindsightStatuses[providerID] = await hindsightClient(for: providerID).status(for: providerID)
                throw error
            }
        }
        return try await activeStore(forProjectID: projectID).browserEntries(for: context)
    }

    func browserDocument(
        _ id: MemoryEntryID,
        projectID: UUID?
    ) async throws -> MemoryBrowserDocument {
        if usesLLMWiki(forProjectID: projectID), id.rawValue.hasPrefix("raw:") {
            return try await llmWikiStore(forProjectID: projectID).sourceDocument(
                id, context: storageContext(forProjectID: projectID))
        }
        if isUsingHindsight(forProjectID: projectID), id.rawValue.hasPrefix(HindsightKnowledge.idPrefix) {
            _ = try hindsightStore(forProjectID: projectID)
            let providerID = providerID(forProjectID: projectID)
            guard let connection = hindsightConnection(forProjectID: projectID),
                let credentialID = hindsightCredentialProviderID(for: providerID)
            else { throw HindsightControlError.invalidConfiguration }
            let token = try CredentialStore.get(HindsightProviderClient.credentialKey(for: credentialID))
            let pageID = String(id.rawValue.dropFirst(HindsightKnowledge.idPrefix.count))
            let data = try await hindsightControlClient.knowledge(connection: connection, apiToken: token, id: pageID)
            try Task.checkCancellation()
            guard isUsingHindsight(forProjectID: projectID), self.providerID(forProjectID: projectID) == providerID,
                hindsightConnection(forProjectID: projectID) == connection
            else { throw CancellationError() }
            return try HindsightKnowledge.document(
                data, id: pageID, bankID: connection.bankID,
                scope: projectID.map { .project($0) } ?? .global)
        }
        if isUsingHindsight(forProjectID: projectID) {
            let providerID = providerID(forProjectID: projectID)
            do {
                return try await hindsightStore(forProjectID: projectID).browserDocument(
                    id, context: storageContext(forProjectID: projectID))
            } catch {
                hindsightStatuses[providerID] = await hindsightClient(for: providerID).status(for: providerID)
                throw error
            }
        }
        return try await activeStore(forProjectID: projectID).browserDocument(
            id, context: storageContext(forProjectID: projectID))
    }

    /// Resolves only documents the active provider already exposes to the browser. The preview
    /// uses this index to keep wiki navigation provider-aware rather than reconstructing paths
    /// from rendered Markdown.
    func browserLinkTargets(forProjectID projectID: UUID?) async throws -> [String: MemoryEntryID] {
        if usesLLMWiki(forProjectID: projectID) {
            let material = try await llmWikiStore(forProjectID: projectID).graphMaterial(
                for: storageContext(forProjectID: projectID))
            var targets = Dictionary(uniqueKeysWithValues: material.pages.map { ($0.name, $0.entry.id) })
            for source in material.sources where targets[source.name] == nil {
                targets[source.name] = source.entry.id
            }
            return targets
        }
        let entries = try await browserEntries(forProjectID: projectID)
        return entries.reduce(into: [String: MemoryEntryID]()) { targets, entry in
            guard let name = Self.browserLinkName(from: entry.id), targets[name] == nil else { return }
            targets[name] = entry.id
        }
    }

    /// Build the LLM Wiki's memory map. Store reads occur in the provider actor; the bounded link
    /// parse and deterministic layout deliberately run in a detached task before SwiftUI receives a value.
    func llmWikiGraph(forProjectID projectID: UUID?) async throws -> MemoryGraphSnapshot {
        guard usesLLMWiki(forProjectID: projectID) else { return .empty }
        let store = try await llmWikiStore(forProjectID: projectID)
        let context = storageContext(forProjectID: projectID)
        let material = try await store.graphMaterial(for: context)
        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return MemoryGraphBuilder.build(from: material)
        }.value
    }

    nonisolated private static func browserLinkName(from id: MemoryEntryID) -> String? {
        let candidate = id.rawValue.split(separator: ":").last.map(String.init) ?? ""
        guard !candidate.isEmpty, candidate.utf8.count <= 64 else { return nil }
        let scalars = Array(candidate.unicodeScalars)
        guard let first = scalars.first, let last = scalars.last,
            isLowercaseLetterOrDigit(first), isLowercaseLetterOrDigit(last)
        else { return nil }
        guard scalars.allSatisfy({ isLowercaseLetterOrDigit($0) || $0.value == 45 }) else { return nil }
        return candidate
    }

    nonisolated private static func isLowercaseLetterOrDigit(_ scalar: UnicodeScalar) -> Bool {
        (97...122).contains(scalar.value) || (48...57).contains(scalar.value)
    }

    func recentBrowserEntries(forProjectID projectID: UUID?) async throws -> [MemoryBrowserEntry] {
        let entries = try await browserEntries(forProjectID: projectID, limit: Self.recentRecordLimit)
        if isUsingHindsight(forProjectID: projectID) { return Array(entries.prefix(Self.recentRecordLimit)) }
        return Array(
            entries.sorted {
                if $0.modifiedAt != $1.modifiedAt {
                    return ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast)
                }
                return $0.id.rawValue < $1.id.rawValue
            }.prefix(Self.recentRecordLimit))
    }

    func browserGraph(forProjectID projectID: UUID?) async throws -> MemoryGraphSnapshot {
        guard isUsingHindsight(forProjectID: projectID) else { return try await llmWikiGraph(forProjectID: projectID) }
        _ = try hindsightStore(forProjectID: projectID)
        let providerID = providerID(forProjectID: projectID)
        guard let connection = hindsightConnection(forProjectID: projectID),
            let credentialID = hindsightCredentialProviderID(for: providerID)
        else { throw HindsightControlError.invalidConfiguration }
        let token = try CredentialStore.get(HindsightProviderClient.credentialKey(for: credentialID))
        let data = try await hindsightControlClient.graph(connection: connection, apiToken: token)
        let knowledgeData: Data?
        do {
            knowledgeData = try await hindsightControlClient.knowledge(connection: connection, apiToken: token)
        } catch {
            try Task.checkCancellation()
            knowledgeData = nil
        }
        guard isUsingHindsight(forProjectID: projectID),
            self.providerID(forProjectID: projectID) == providerID,
            hindsightConnection(forProjectID: projectID) == connection
        else { throw CancellationError() }
        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            var graph = try HindsightGraph.decode(data)
            if let knowledgeData {
                do { return try HindsightKnowledge.adding(knowledgeData, bankID: connection.bankID, to: graph) } catch {
                    graph.notice = "Knowledge pages could not be decoded. Refresh to retry; memories are still shown."
                }
            } else {
                graph.notice = "Knowledge pages could not be loaded. Refresh to retry; memories are still shown."
            }
            return graph
        }.value
    }

}
