import Foundation

/// Turn-scoped no-progress guard for tool calls (ADR-0089). Beside the file-repair tracker, it
/// catches a model that repeats an identical call or keeps getting an identical result: three
/// identical (tool name, canonical argument JSON) calls in a turn, or three consecutive identical
/// results from the same tool, return a stop message so the turn pauses with the no-progress
/// presentation. It is a no-progress check, not a round cap: productive repeated work with different
/// arguments and results is never paused.
public struct RepetitionGuard: Sendable, Equatable {
    private struct CallSignature: Hashable, Sendable {
        let name: String
        let arguments: String
    }

    private struct ResultStreak: Equatable, Sendable {
        var hash: UInt64
        var count: Int
    }

    private var callCounts: [CallSignature: Int] = [:]
    private var order: [CallSignature] = []
    private var lastResult: [String: ResultStreak] = [:]
    private let maximumSignatures = 256
    private let repeatThreshold = 3

    public init() {}

    /// Records one executed tool call and its result. Returns a stop message when the call has now
    /// repeated identically three times in the turn, or the tool has returned the same result three
    /// times in a row; otherwise nil.
    @discardableResult
    public mutating func observe(name: String, argumentsJSON: String, result: String) -> String? {
        let signature = CallSignature(name: name, arguments: Self.canonicalArguments(argumentsJSON))
        touch(signature)
        let calls = (callCounts[signature] ?? 0) + 1
        callCounts[signature] = calls
        if calls >= repeatThreshold {
            return
                "Stopped: \(name) was called \(repeatThreshold) times with the same arguments without making progress. Change the arguments or approach, or send a message to continue."
        }

        let hash = Self.stableHash(result)
        if let previous = lastResult[name], previous.hash == hash {
            let count = previous.count + 1
            lastResult[name] = ResultStreak(hash: hash, count: count)
            if count >= repeatThreshold {
                return
                    "Stopped: \(name) returned the same result \(repeatThreshold) times in a row without making progress. Try a different approach, or send a message to continue."
            }
        } else {
            lastResult[name] = ResultStreak(hash: hash, count: 1)
        }
        return nil
    }

    /// Clears all turn state. Called between turns when the guard is reused.
    public mutating func endTurn() {
        callCounts.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        lastResult.removeAll(keepingCapacity: true)
    }

    private mutating func touch(_ signature: CallSignature) {
        order.removeAll { $0 == signature }
        order.append(signature)
        if order.count > maximumSignatures, let evicted = order.first {
            order.removeFirst()
            callCounts.removeValue(forKey: evicted)
        }
    }

    /// Canonicalises argument JSON so semantically identical calls compare equal regardless of key
    /// order or whitespace. Non-JSON or fragment arguments fall back to the trimmed raw string.
    static func canonicalArguments(_ json: String) -> String {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let string = String(data: canonical, encoding: .utf8)
        else { return trimmed }
        return string
    }

    /// FNV-1a 64-bit over the UTF-8 bytes: deterministic across runs, so result comparison is stable
    /// for tests and bounded in memory regardless of result size.
    private static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
