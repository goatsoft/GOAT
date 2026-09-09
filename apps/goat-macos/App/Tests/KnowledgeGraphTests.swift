import Foundation
import Testing

@testable import GOAT
@testable import Hindsight
@testable import Memory

@Test func graphOrbitUsesDepthAndIndependentAxesWithoutStretching() {
    let size = CGSize(width: 800, height: 400)
    var camera = GraphCamera()
    let front = MemoryGraphPosition(x: 0.3, y: 0.2, z: 0.5)
    let back = MemoryGraphPosition(x: 0.3, y: 0.2, z: -0.5)
    #expect(camera.project(front, size: size).perspective > camera.project(back, size: size).perspective)
    camera.orbit(horizontal: .pi / 2, vertical: 0)
    let turned = camera.project(front, size: size)
    #expect(abs(turned.depth + 0.3) < 0.00001)
    let sameHeight = camera.project(front, size: CGSize(width: 1200, height: 400))
    #expect(abs((turned.point.x - 400) - (sameHeight.point.x - 600)) < 0.00001)
    camera.orbit(horizontal: 0, vertical: .pi / 4)
    #expect(camera.project(front, size: size).point.y != turned.point.y)
    camera.orbit(horizontal: 0, vertical: 1000)
    #expect(camera.pitch < .pi / 2)
}

@Test func spatialLayoutIsDeterministicBoundedAndActuallyHasDepth() {
    let ids = (0..<30).map { MemoryEntryID(rawValue: String($0)) }
    let positions = GraphLayout3D.positions(for: ids, edges: [])
    #expect(positions == GraphLayout3D.positions(for: ids.reversed(), edges: []))
    #expect(positions.values.contains { abs($0.z) > 0.2 })
    #expect(
        positions.values.allSatisfy {
            $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.x * $0.x + $0.y * $0.y + $0.z * $0.z <= 0.851 * 0.851
        })
}

@Test func memoryGraphPreservesEveryServerFactTypeIncludingExperiences() throws {
    let types = ["world", "experience", "observation", "opinion", "future-type"]
    let payload: [String: Any] = [
        "nodes": types.enumerated().map { ["data": ["id": String($0.offset), "label": $0.element]] },
        "edges": [], "total_units": types.count,
        "table_rows": types.enumerated().map { ["id": String($0.offset), "fact_type": $0.element] },
    ]
    let graph = try HindsightGraph.decode(JSONSerialization.data(withJSONObject: payload))
    #expect(graph.nodes.map(\.factType) == [.world, .experience, .observation, .opinion, .unknown])
}

@Test func knowledgeUsesOnlyBankScopedRecordedCitationsAndCanOpenItsDocument() throws {
    let memory = Data(##"{"nodes":[{"data":{"id":"fact-a","label":"Fact"}}],"edges":[],"total_units":1}"##.utf8)
    let knowledge = Data(
        ##"{"items":[{"id":"knowledge-a","bank_id":"pen","name":"Knowledge","content":"# Saved knowledge","reflect_response":{"based_on":{"observation":[{"id":"fact-a"},{"id":"missing"}]}}}],"total":1}"##
            .utf8)
    let graph = try HindsightKnowledge.adding(knowledge, bankID: "pen", to: HindsightGraph.decode(memory))
    #expect(graph.knowledge.count == 1)
    #expect(graph.edges.count == 1)
    #expect(graph.edges[0].sourceID.rawValue == "hindsight-knowledge:knowledge-a")
    #expect(graph.edges[0].targetID.rawValue == "hindsight:fact-a")
    #expect(!graph.edges[0].directLink)
    #expect(graph.isTruncated)
    #expect(graph.notice != nil)
    #expect(throws: (any Error).self) {
        try HindsightKnowledge.adding(knowledge, bankID: "another-pen", to: HindsightGraph.decode(memory))
    }
    let doc = Data(##"{"id":"knowledge-a","bank_id":"pen","name":"Knowledge","content":"# Saved knowledge"}"##.utf8)
    #expect(
        try HindsightKnowledge.document(doc, id: "knowledge-a", bankID: "pen", scope: .shared).content
            == "# Saved knowledge")
    #expect(throws: (any Error).self) {
        try HindsightKnowledge.document(doc, id: "other", bankID: "pen", scope: .shared)
    }
    #expect(!HindsightKnowledge.validID("../another-bank"))
}

@Test func knowledgeRejectsDuplicatePagesAndOversizedPayloads() throws {
    let graph = MemoryGraphSnapshot.empty
    let duplicate = Data(
        ##"{"items":[{"id":"same","bank_id":"pen","name":"A"},{"id":"same","bank_id":"pen","name":"B"}],"total":2}"##
            .utf8)
    #expect(throws: (any Error).self) { try HindsightKnowledge.adding(duplicate, bankID: "pen", to: graph) }
    #expect(throws: HindsightControlError.responseTooLarge) {
        try HindsightKnowledge.adding(
            Data(repeating: 32, count: HindsightKnowledge.maximumBytes + 1), bankID: "pen", to: graph)
    }
}
