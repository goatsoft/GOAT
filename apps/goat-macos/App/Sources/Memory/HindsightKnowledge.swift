import Foundation
import Hindsight
import Memory

/// Knowledge pages are Hindsight mental models, separate from extracted memory units. Links
/// below come only from their saved reflect provenance, never from matching names or text.
enum HindsightKnowledge {
    static let maximumPages = HindsightLimits.knowledgePages
    static let maximumBytes = HindsightLimits.knowledgeBytes
    static let idPrefix = "hindsight-knowledge:"

    struct Page: Decodable {
        let id: String
        let bank_id: String
        let name: String
        let content: String?
        let reflect_response: Reflection?
    }
    struct Reflection: Decodable {
        let based_on: [String: [Reference]]?
    }
    struct Reference: Decodable { let id: String }
    struct Listing: Decodable {
        let items: [Page]
        let total: Int
    }

    static func validID(_ id: String) -> Bool {
        HindsightLimits.validKnowledgeID(id)
    }

    static func adding(_ data: Data, bankID: String, to graph: MemoryGraphSnapshot) throws -> MemoryGraphSnapshot {
        guard data.count <= maximumBytes else { throw HindsightControlError.responseTooLarge }
        let listing = try JSONDecoder().decode(Listing.self, from: data)
        guard listing.items.count <= maximumPages, listing.total >= listing.items.count,
            Set(listing.items.map(\.id)).count == listing.items.count,
            listing.items.allSatisfy({ validID($0.id) && $0.bank_id == bankID && $0.name.utf8.count <= 32_768 })
        else { throw HindsightControlError.invalidResponse }
        let pages = listing.items.sorted { $0.id < $1.id }
        let memoryIDs = Set(graph.nodes.map(\.id))
        let knowledgeIDs = Set(pages.map { MemoryEntryID(rawValue: idPrefix + $0.id) })
        var citations = Set<MemoryGraphEdge>()
        var omittedReferences = 0
        for page in pages {
            for (kind, refs) in page.reflect_response?.based_on ?? [:] {
                let prefix: String
                let targets: Set<MemoryEntryID>
                switch kind {
                case "world", "experience", "opinion", "observation":
                    prefix = "hindsight:"
                    targets = memoryIDs
                case "mental-models":
                    prefix = idPrefix
                    targets = knowledgeIDs
                default: continue
                }
                for reference in refs {
                    let target = MemoryEntryID(rawValue: prefix + reference.id)
                    let source = MemoryEntryID(rawValue: idPrefix + page.id)
                    guard target != source else { continue }
                    guard targets.contains(target) else {
                        omittedReferences += 1
                        continue
                    }
                    citations.insert(MemoryGraphEdge(sourceID: source, targetID: target, directLink: false))
                }
            }
        }
        // Provenance earns space before incidental similarity edges in a dense memory graph.
        let orderedCitations = citations.sorted {
            ($0.sourceID.rawValue, $0.targetID.rawValue) < ($1.sourceID.rawValue, $1.targetID.rawValue)
        }
        let edges = Array((orderedCitations + graph.edges).prefix(HindsightGraph.maximumEdges))
        let ids = graph.nodes.map(\.id) + pages.map { MemoryEntryID(rawValue: idPrefix + $0.id) }
        let positions = GraphLayout3D.positions(for: ids, edges: Set(edges))
        var nodes = graph.nodes.map { node in
            MemoryGraphNode(
                id: node.id, title: node.title, summary: node.summary, kind: node.kind,
                incomingPageLinks: edges.count { $0.targetID == node.id },
                outgoingPageLinks: edges.count { $0.sourceID == node.id },
                sourceCitationCount: node.sourceCitationCount, isHub: node.isHub, isOrphan: node.isOrphan,
                isDisconnected: !edges.contains { $0.sourceID == node.id || $0.targetID == node.id },
                position: positions[node.id] ?? node.position, factType: node.factType)
        }
        nodes += pages.map { page in
            let id = MemoryEntryID(rawValue: idPrefix + page.id)
            let links = edges.count { $0.sourceID == id || $0.targetID == id }
            return MemoryGraphNode(
                id: id, title: page.name,
                summary: String((page.content ?? "This knowledge page has not been populated yet.").prefix(2_000)),
                kind: .knowledge,
                incomingPageLinks: edges.count { $0.targetID == id },
                outgoingPageLinks: edges.count { $0.sourceID == id },
                sourceCitationCount: 0, isHub: links >= 3, isOrphan: false, isDisconnected: links == 0,
                position: positions[id] ?? MemoryGraphPosition(x: 0, y: 0))
        }
        return MemoryGraphSnapshot(
            nodes: nodes, edges: edges,
            isTruncated: graph.isTruncated || listing.total > pages.count
                || orderedCitations.count + graph.edges.count > edges.count || omittedReferences > 0,
            isHindsight: true,
            notice: omittedReferences > 0 ? "Some knowledge citations point to memories outside this preview." : nil)
    }

    static func document(_ data: Data, id: String, bankID: String, scope: MemoryDisplayScope) throws
        -> MemoryBrowserDocument
    {
        guard data.count <= maximumBytes else { throw HindsightControlError.responseTooLarge }
        let page = try JSONDecoder().decode(Page.self, from: data)
        guard validID(page.id), page.id == id, page.bank_id == bankID else {
            throw HindsightControlError.invalidResponse
        }
        return MemoryBrowserDocument(
            entry: MemoryBrowserEntry(
                id: MemoryEntryID(rawValue: idPrefix + id), title: page.name,
                summary: "Hindsight knowledge page", scope: scope, canEdit: false, canDelete: false),
            content: page.content ?? "This knowledge page has not been populated yet.")
    }
}
