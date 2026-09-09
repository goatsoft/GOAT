import Foundation
import Testing

@testable import GOAT
@testable import Hoofprint
@testable import JUDAS

@MainActor
@Test func judasActivityUsesTheExistingLogAndKeepsOverflowVisible() throws {
    let judas = Judas(capacity: 600)
    let log = ActivityLog(judas: judas, automaticallyDrain: false)
    let url = try #require(URL(string: "https://example.com/private?token=secret"))
    for _ in 0..<700 { judas.record(.engine, .allowed, url: url) }
    log.drainJudas()
    #expect(log.entries.count == 500)
    #expect(
        log.entries.allSatisfy { $0.category == .judas && !$0.text.contains("secret") && !$0.text.contains("private") })
    #expect(log.entries.last?.text == "Audit queue overflow: 100 older events omitted.")
    log.clear()
    log.drainJudas()
    #expect(log.entries.isEmpty)
    judas.setMode(.blocked)
    log.drainJudas()
    #expect(log.entries.last?.text.contains("policyChanged: blocked") == true)
}

@MainActor
@Test func judasActivityWakesForBurstsAndReleasesItsObserver() async throws {
    let judas = Judas()
    var log: ActivityLog? = ActivityLog(judas: judas)
    weak var released: ActivityLog?
    released = log
    for _ in 0..<100 { judas.record(.engine, .allowed) }
    for _ in 0..<100 where log?.entries.count != 100 {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(log?.entries.count == 100)
    judas.record(.memory, .denied)
    for _ in 0..<100 where log?.entries.count != 101 {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(log?.entries.last?.text.contains("Hindsight denied") == true)
    log = nil
    await Task.yield()
    #expect(released == nil)
    judas.record(.engine, .allowed)
    #expect(judas.drain().events.count == 1)
}
