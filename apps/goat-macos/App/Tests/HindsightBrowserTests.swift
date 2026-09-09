import Foundation
import Testing

@testable import GOAT
@testable import Hindsight
@testable import Memory

@Test func hindsightMapUsesServerLinksAndDropsDanglingEdges() throws {
    let data = Data(
        #"{"nodes":[{"data":{"id":"a","label":"First","text":"Full memory"}},{"data":{"id":"b","label":"Second"}}],"edges":[{"data":{"source":"a","target":"b","linkType":"semantic"}},{"data":{"source":"a","target":"b","linkType":"entity"}},{"data":{"source":"a","target":"missing","linkType":"temporal"}}],"total_units":200}"#
            .utf8)
    let graph = try HindsightGraph.decode(data)
    #expect(graph.isHindsight)
    #expect(graph.isTruncated)
    #expect(graph.nodes.count == 2)
    #expect(graph.edges.count == 2)
    #expect(graph.nodes.first?.summary == "Full memory")
    #expect(graph.edges.first?.sourceID.rawValue == "hindsight:a")
    #expect(graph.nodes.allSatisfy { abs($0.position.x) <= 1 && abs($0.position.y) <= 1 })
    #expect(try HindsightGraph.decode(data) == graph)
}

@Test func hindsightMapRejectsDuplicateIDsAndOversizedGraphs() throws {
    let duplicate = Data(
        #"{"nodes":[{"data":{"id":"a","label":"One"}},{"data":{"id":"a","label":"Two"}}],"edges":[],"total_units":2}"#
            .utf8)
    #expect(throws: (any Error).self) { try HindsightGraph.decode(duplicate) }
    let nodes = (0...HindsightGraph.maximumNodes).map { ["data": ["id": String($0), "label": "Memory"]] }
    let oversized = try JSONSerialization.data(withJSONObject: [
        "nodes": nodes, "edges": [], "total_units": nodes.count,
    ])
    #expect(throws: (any Error).self) { try HindsightGraph.decode(oversized) }
}

@Test func globalHindsightBankCannotReuseAPenRoute() {
    let serviceID = MemoryProviderID(rawValue: "hindsight-service")
    let connection = HindsightBankConnection(apiURL: "http://localhost:8888", bankID: "pen-bank")
    let service = MemoryProviderRecord(
        id: serviceID, displayName: "Hindsight", kind: .hindsight,
        hindsight: HindsightProviderConfiguration(connection: connection))
    let pen = MemoryProviderRecord(
        id: MemoryProviderID(rawValue: "pen-route"), displayName: "Pen", kind: .hindsight,
        hindsight: HindsightProviderConfiguration(
            penRoute: HindsightPenBankRoute(serviceProviderID: serviceID, bankID: "pen-bank")))
    #expect(!MemoryModel.globalBankIsDedicated(connection, providers: [service, pen]))
    #expect(
        MemoryModel.globalBankIsDedicated(
            HindsightBankConnection(apiURL: connection.apiURL, bankID: "goat-global"), providers: [service, pen]))
    #expect(
        !MemoryModel.globalBankIsDedicated(
            HindsightBankConnection(apiURL: "http://127.0.0.1:8888", bankID: "pen-bank"),
            providers: [service, pen], replacingProviderID: serviceID))
}

@Test func hindsightUILinkUsesConfiguredHostWithoutAPIPathOrCredentials() {
    #expect(MemoryModel.hindsightUIURL(apiURL: "http://localhost:8888")?.absoluteString == "http://localhost:9999/")
    #expect(
        MemoryModel.hindsightUIURL(apiURL: "https://memory.example")?.absoluteString
            == "https://memory.example:9999/")
    #expect(MemoryModel.hindsightUIURL(apiURL: "file:///tmp/memory") == nil)
    #expect(MemoryModel.hindsightUIURL(apiURL: "https://memory.example/api") == nil)
    #expect(MemoryModel.hindsightUIURL(apiURL: "https://user:secret@example.com") == nil)
}

@Test func denseHindsightMapHasItsOwnBoundedResponseBudget() throws {
    let nodes = (0..<49).map { ["data": ["id": String($0), "label": "Memory"]] }
    let edges = (0..<2_000).map { index in
        [
            "data": [
                "source": String(index / 49), "target": String(index % 49),
                "linkType": "entity", "entityName": String(repeating: "e", count: 100),
            ]
        ]
    }
    let data = try JSONSerialization.data(withJSONObject: ["nodes": nodes, "edges": edges, "total_units": 49])
    #expect(data.count > HindsightControlClient.maximumResponseBytes)
    let graph = try HindsightGraph.decode(data)
    #expect(graph.nodes.count == 49)
    #expect(graph.edges.count == HindsightGraph.maximumEdges)
    #expect(graph.isTruncated)
    #expect(throws: HindsightControlError.responseTooLarge) {
        try HindsightGraph.decode(Data(repeating: 32, count: HindsightGraph.maximumResponseBytes + 1))
    }
}

@Test func hindsightAssociationsKeepTheirTypesAndCausalMotionUsesCauseToEffect() throws {
    let payload: [String: Any] = [
        "nodes": ["a", "b"].map { ["data": ["id": $0, "label": $0]] },
        "edges": [
            ["source": "a", "target": "b", "linkType": "semantic"],
            ["source": "b", "target": "a", "linkType": "semantic"],
            ["source": "a", "target": "b", "linkType": "temporal"],
            ["source": "a", "target": "b", "linkType": "entity"],
            ["source": "a", "target": "b", "linkType": "caused_by"],
            ["source": "a", "target": "b", "linkType": "future-relation"],
        ].map { ["data": $0] },
        "total_units": 2,
    ]
    let graph = try HindsightGraph.decode(JSONSerialization.data(withJSONObject: payload))
    #expect(graph.edges.count == 5)
    for type in [MemoryGraphRelationship.semantic, .temporal, .entity] {
        let edge = try #require(graph.edges.first { $0.relationship == type })
        #expect(edge.flows.count == 2)
        #expect(Set(edge.flows.map(\.fromID)) == Set(graph.nodes.map(\.id)))
    }
    let causal = try #require(graph.edges.first { $0.relationship == .causedBy })
    #expect(causal.sourceID.rawValue == "hindsight:a")  // Stored effect remains unchanged.
    #expect(causal.flows == [MemoryGraphFlow(fromID: causal.targetID, toID: causal.sourceID)])
    #expect(graph.edges.first { $0.relationship == .unknown }?.flows.isEmpty == true)
    #expect(MemoryGraphRelationship.hindsightType("wikiLink") == .unknown)
}

@Test func directedGraphTracersFollowCitationsAndLegacyCausalMeaning() {
    let source = MemoryEntryID(rawValue: "source")
    let target = MemoryEntryID(rawValue: "target")
    for type in [MemoryGraphRelationship.wikiLink, .citation, .causes, .enables, .prevents] {
        let edge = MemoryGraphEdge(
            sourceID: source, targetID: target, directLink: type != .citation, relationship: type)
        #expect(edge.flows == [MemoryGraphFlow(fromID: source, toID: target)])
    }
}

@Test func graphTracersRespectTheirBudgetFocusAndBothDirectionsOfAssociations() {
    let ids = (0..<30).map { MemoryEntryID(rawValue: String($0)) }
    let edges = ids.dropFirst().map {
        MemoryGraphEdge(sourceID: ids[0], targetID: $0, directLink: true, relationship: .semantic)
    }
    let flows = MemoryGraphFlow.preview(edges: edges + edges, visibleIDs: Set(ids), focus: ids[0])
    #expect(MemoryGraphFlow.preview(edges: edges, visibleIDs: Set(ids), focus: nil).isEmpty)
    #expect(flows.count == MemoryGraphFlow.maximumDots)
    #expect(Set(flows).count == flows.count)
    #expect(flows.allSatisfy { flows.contains(MemoryGraphFlow(fromID: $0.toID, toID: $0.fromID)) })
    let focused = MemoryGraphFlow.preview(edges: edges, visibleIDs: Set(ids), focus: ids[1])
    #expect(focused.count == 2)
    #expect(focused.allSatisfy { $0.fromID == ids[1] || $0.toID == ids[1] })
    #expect(MemoryGraphFlow.preview(edges: edges, visibleIDs: [ids[0]], focus: ids[0]).isEmpty)
}
