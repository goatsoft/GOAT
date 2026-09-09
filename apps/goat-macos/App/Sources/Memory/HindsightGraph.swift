import Foundation
import Hindsight
import Memory

/// A bounded projection of Hindsight's bank graph. Server colors and presentation are ignored;
/// only actual memory IDs and relationships enter GOAT's native, themed renderer.
enum HindsightGraph {
    static let maximumNodes = HindsightLimits.graphNodes
    static let maximumResponseBytes = HindsightLimits.graphBytes
    static let maximumEdges = 480

    private struct Payload: Decodable {
        let nodes: [NodeEnvelope]
        let edges: [EdgeEnvelope]
        let total_units: Int
        let table_rows: [FactRow]?
    }
    private struct FactRow: Decodable {
        let id: String
        let fact_type: String?
    }
    private struct NodeEnvelope: Decodable {
        let data: Node
    }
    private struct Node: Decodable {
        let id: String
        let label: String
        let text: String?
        let fact_type: String?
    }
    private struct EdgeEnvelope: Decodable {
        let data: Edge
    }
    private struct Edge: Decodable {
        let source: String
        let target: String
        let linkType: String
    }

    static func decode(_ data: Data) throws -> MemoryGraphSnapshot {
        guard data.count <= maximumResponseBytes else {
            throw HindsightControlError.responseTooLarge
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.nodes.count <= maximumNodes, payload.edges.count <= 10_000,
            payload.total_units >= payload.nodes.count,
            Set(payload.nodes.map(\.data.id)).count == payload.nodes.count,
            payload.nodes.allSatisfy({ validID($0.data.id) && $0.data.label.utf8.count <= 32_768 })
        else { throw HindsightControlError.invalidResponse }
        guard (payload.table_rows?.count ?? 0) <= maximumNodes else { throw HindsightControlError.invalidResponse }
        var factTypes: [String: MemoryGraphFactType] = [:]
        for row in payload.table_rows ?? [] {
            factTypes[row.id] = MemoryGraphFactType(rawValue: row.fact_type ?? "") ?? .unknown
        }
        let records = payload.nodes.map(\.data).sorted { $0.id < $1.id }
        let ids = Set(records.map(\.id))
        var edges = Set<MemoryGraphEdge>()
        for envelope in payload.edges {
            let edge = envelope.data
            guard ids.contains(edge.source), ids.contains(edge.target), edge.source != edge.target else { continue }
            let relationship = MemoryGraphRelationship.hindsightType(edge.linkType)
            // Reciprocal similarity, time-proximity and shared-entity rows represent one
            // association. Keep distinct relationship types; never reorder causal endpoints.
            let reverse = relationship.isAssociation && edge.source > edge.target
            edges.insert(
                MemoryGraphEdge(
                    sourceID: entryID(reverse ? edge.target : edge.source),
                    targetID: entryID(reverse ? edge.source : edge.target), directLink: true,
                    relationship: relationship))
        }
        let ordered = edges.sorted {
            ($0.sourceID.rawValue, $0.targetID.rawValue, $0.relationship.rawValue)
                < ($1.sourceID.rawValue, $1.targetID.rawValue, $1.relationship.rawValue)
        }
        let bounded = Set(ordered.prefix(maximumEdges))
        let positions = MemoryGraphBuilder.pagePositions(for: records.map { entryID($0.id) }, edges: bounded)
        let nodes = records.map { record in
            let id = entryID(record.id)
            let incoming = bounded.count { $0.targetID == id }
            let outgoing = bounded.count { $0.sourceID == id }
            return MemoryGraphNode(
                id: id, title: MemoryBrowserEntry.displayTitle(for: record.text ?? record.label),
                summary: String((record.text ?? record.label).prefix(2_000)), kind: .page,
                incomingPageLinks: incoming, outgoingPageLinks: outgoing, sourceCitationCount: 0,
                isHub: incoming + outgoing >= 3, isOrphan: incoming == 0,
                isDisconnected: incoming + outgoing == 0,
                position: positions[id] ?? MemoryGraphPosition(x: 0, y: 0),
                factType: factTypes[record.id] ?? MemoryGraphFactType(rawValue: record.fact_type ?? "") ?? .unknown)
        }
        return MemoryGraphSnapshot(
            nodes: nodes, edges: Array(ordered.prefix(maximumEdges)),
            isTruncated: payload.total_units > nodes.count || edges.count > maximumEdges,
            isHindsight: true)
    }

    private static func entryID(_ id: String) -> MemoryEntryID {
        MemoryEntryID(rawValue: "hindsight:\(id)")
    }

    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 512
            && !id.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
}
