import Foundation
import JUDAS
import Observation

@MainActor
@Observable
public final class ActivityLog {
    public enum Category: String {
        case engine, mcp, memory, judas, warn, info
    }

    public struct Entry: Identifiable {
        public let id = UUID()
        public let date: Date
        public let category: Category
        public let text: String
    }

    public private(set) var entries: [Entry] = []
    private let judas: Judas
    @ObservationIgnored private var drainTask: Task<Void, Never>?

    public init(judas: Judas = .shared, automaticallyDrain: Bool = true) {
        self.judas = judas
        guard automaticallyDrain else { return }
        let notifications = judas.eventNotifications()
        drainTask = Task { [weak self] in
            for await _ in notifications {
                // Coalesce bursts without a perpetual idle timer. Events remain in JUDAS until
                // drained, including while this task sleeps or the panel is hidden.
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard let self else { return }
                self.drainJudas()
            }
        }
    }

    deinit { drainTask?.cancel() }

    public func drainJudas() {
        let batch = judas.drain()
        guard !batch.events.isEmpty || batch.dropped > 0 else { return }
        var additions = batch.events.map { event in
            Entry(
                date: event.date, category: .judas,
                text: "#\(event.sequence) \(event.source.label) \(event.action.rawValue): \(event.destination)")
        }
        if batch.dropped > 0 {
            additions.append(
                Entry(
                    date: Date(), category: .judas,
                    text: "Audit queue overflow: \(batch.dropped) older events omitted."))
        }
        // One observable publication per batch, with the same session retention policy.
        entries = Array((entries + additions).suffix(500))
    }

    public func log(_ category: Category, _ text: String) {
        entries.append(Entry(date: Date(), category: category, text: text))
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
    }

    public func clear() {
        drainJudas()
        entries.removeAll()
    }
}
