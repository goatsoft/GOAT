import Foundation
import Memory

/// Deterministic 3D force layout, run only by the detached graph builders. Depth is a layout
/// coordinate, not a claim about chronology, confidence, or knowledge importance.
enum GraphLayout3D {
    static func positions(for input: [MemoryEntryID], edges: Set<MemoryGraphEdge>) -> [MemoryEntryID:
        MemoryGraphPosition]
    {
        let ids = Array(Set(input)).sorted { $0.rawValue < $1.rawValue }
        guard ids.count > 1 else {
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, MemoryGraphPosition(x: 0, y: 0)) })
        }
        let indices = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let links = edges.sorted {
            ($0.sourceID.rawValue, $0.targetID.rawValue, $0.relationship.rawValue)
                < ($1.sourceID.rawValue, $1.targetID.rawValue, $1.relationship.rawValue)
        }
        .compactMap { edge -> (Int, Int)? in
            guard let a = indices[edge.sourceID], let b = indices[edge.targetID], a != b else { return nil }
            return (a, b)
        }
        let golden = Double.pi * (3 - sqrt(5))
        var positions = ids.indices.map { index -> SIMD3<Double> in
            let y = 1 - 2 * (Double(index) + 0.5) / Double(ids.count)
            let r = sqrt(max(0, 1 - y * y))
            let angle = Double(index) * golden
            return SIMD3(cos(angle) * r, y, sin(angle) * r) * 0.72
        }
        for iteration in 0..<160 {
            var forces = Array(repeating: SIMD3<Double>.zero, count: ids.count)
            for a in ids.indices {
                for b in ids.indices.dropFirst(a + 1) {
                    let delta = positions[b] - positions[a]
                    let distance = max(length(delta), 0.001)
                    let force = delta / distance * (0.016 / (distance * distance))
                    forces[a] -= force
                    forces[b] += force
                }
            }
            for (a, b) in links {
                let delta = positions[b] - positions[a]
                let distance = max(length(delta), 0.001)
                let force = delta / distance * (distance - 0.52) * 0.075
                forces[a] += force
                forces[b] -= force
            }
            let cooling = 0.04 * (1 - Double(iteration) / 190)
            for index in ids.indices { positions[index] += (forces[index] - positions[index] * 0.012) * cooling }
        }
        let center = positions.reduce(.zero, +) / Double(ids.count)
        positions = positions.map { $0 - center }
        let radius = max(positions.map(length).max() ?? 1, 0.001)
        return Dictionary(
            uniqueKeysWithValues: zip(ids, positions).map { id, point in
                let scaled = point / radius * 0.85
                return (id, MemoryGraphPosition(x: scaled.x, y: scaled.y, z: scaled.z))
            })
    }

    private static func length(_ value: SIMD3<Double>) -> Double {
        sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
    }
}
