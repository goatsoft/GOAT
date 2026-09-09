import Bleet
import Foundation
import GOATed
import Herd
import Hitch

extension AppModel {
    func extensionReport() async -> [String] {
        let names = [
            "goat.herder": "Herder", "goat.hindsight": "Hindsight Memory", "goat.hitch": "Hitch", "goat.pronk": "Pronk",
        ]
        let active = await toolRouter.extensions.activeExtensions()
        var report = active.map { "\(names[$0.id.rawValue] ?? $0.id.rawValue) \($0.version): registered" }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let diagnostics = await toolRouter.extensions.recentDiagnostics()
        report += diagnostics.suffix(8).map {
            "\(names[$0.extensionID.rawValue] ?? $0.extensionID.rawValue): \($0.code)"
        }
        return report.isEmpty ? ["No runtime registrations or recent issues."] : report
    }

    func setControlEnabled(_ enabled: Bool) async {
        guard !extensionsChanging else { return }
        extensionsChanging = true
        defer { extensionsChanging = false }
        extensionError = nil
        if enabled {
            if controlSession == nil { controlSession = AppControlSession(model: self, runtime: toolRouter.extensions) }
            do {
                try await controlSession?.start()
                controlEnabled = true
                UserDefaults.standard.set(true, forKey: "goated.control")
            } catch {
                extensionError =
                    "Hitch could not start. Check that GOAT Home exists, the control directory is private, and another GOAT instance is not using it."
            }
        } else {
            controlEnabled = false
            await controlSession?.stop()
            controlTurns.removeAll()
            UserDefaults.standard.set(false, forKey: "goated.control")
        }
    }

    func setHindsightExtensionEnabled(_ enabled: Bool) async {
        guard !extensionsChanging, shepherd.activeTurnID == nil else { return }
        extensionsChanging = true
        defer { extensionsChanging = false }
        await memory.setHindsightExtensionEnabled(enabled)
        await toolRouter.refreshHindsightExtension()
    }

    func setPronkEnabled(_ enabled: Bool) async {
        guard !extensionsChanging else { return }
        extensionsChanging = true
        defer { extensionsChanging = false }
        do {
            try await toolRouter.setPronkEnabled(enabled)
            pronkEnabled = enabled
            extensionError = nil
            UserDefaults.standard.set(enabled, forKey: "goated.pronk")
        } catch { extensionError = "Pronk could not be activated. Restart GOAT to retry." }
    }

    private func controlJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func controlPage(_ items: [[String: String]], cursor: String?) throws -> String {
        struct Page: Encodable {
            let items: [[String: String]]
            let nextCursor: String?
        }
        guard let offset = Int(cursor ?? "0"), offset >= 0, offset <= items.count else {
            throw HitchError.invalidArguments
        }
        let end = min(items.count, offset + 32)
        return try controlJSON(
            Page(items: Array(items[offset..<end]), nextCursor: end < items.count ? String(end) : nil))
    }

    func controlSnapshot(turn: UUID, record: ControlTurn, chat: ChatSession, running: Bool) -> [String: String] {
        let last = chat.messages.dropFirst(record.firstMessageIndex).last { $0.role == .assistant }
        let state =
            running
            ? (mcp.pendingPermission == nil ? "streaming" : "awaiting_approval")
            : (record.cancelled ? "cancelled" : (last?.error == nil && last?.complete == true ? "completed" : "failed"))
        return [
            "turn": turn.uuidString, "chat": record.chatID.uuidString, "state": state,
            "text": String((last?.text ?? "").prefix(32_768)),
            "truncated": (last?.text.count ?? 0) > 32_768 ? "true" : "false",
            "approval": mcp.pendingPermission == nil || !running ? "" : "Respond to the permission request in GOAT.",
        ]
    }

    func controlOperation(_ operation: String, arguments: [String: String]) async throws -> String {
        guard controlEnabled, startupPhase.hasLocalState else { throw HitchError.disabled }
        try Task.checkCancellation()
        func uuid(_ name: String) throws -> UUID {
            guard let raw = arguments[name], let value = UUID(uuidString: raw) else {
                throw HitchError.invalidArguments
            }
            return value
        }
        switch operation {
        case "status":
            return try controlJSON([
                "api": "1", "state": startupPhase == .ready ? "ready" : "starting",
                "activeTurn": shepherd.activeTurnID?.uuidString ?? "",
                "permission": mcp.pendingPermission == nil ? "none" : "awaiting_approval",
            ])
        case "pens.list":
            return try controlPage(
                pens.sorted { $0.id.uuidString < $1.id.uuidString }.map {
                    [
                        "id": $0.id.uuidString, "name": String($0.name.prefix(256)),
                        "workspace": String(($0.workspace?.path ?? "").prefix(4096)),
                    ]
                }, cursor: arguments["cursor"])
        case "chats.list":
            let pen = try arguments["pen"].map { _ in try uuid("pen") }
            return try controlPage(
                chats.filter { pen == nil || $0.projectID == pen }.sorted { $0.id.uuidString < $1.id.uuidString }.map {
                    [
                        "id": $0.id.uuidString, "title": String($0.title.prefix(256)),
                        "pen": $0.projectID?.uuidString ?? "",
                    ]
                }, cursor: arguments["cursor"])
        case "chats.create":
            guard !shepherd.hasActiveTurn else { throw HitchError.busy }
            let penID = try arguments["pen"].map { _ in try uuid("pen") }
            let pen = pens.first { $0.id == penID }
            guard penID == nil || pen != nil else { throw HitchError.invalidArguments }
            guard let chatID = await newChat(in: pen) else { throw HitchError.unavailable }
            return try controlJSON(["chat": chatID.uuidString])
        case "turn.send":
            let chatID = try uuid("chat")
            guard let text = arguments["text"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                text.utf8.count <= 32_768, let chat = chats.first(where: { $0.id == chatID }),
                !deletingChatIDs.contains(chatID)
            else { throw HitchError.invalidArguments }
            guard controlTurns.count < 128, !shepherd.hasActiveTurn else { throw HitchError.busy }
            await loadMessages(for: chat)
            try Task.checkCancellation()
            guard controlEnabled, chats.contains(where: { $0.id == chatID }) else { throw HitchError.disabled }
            guard controlTurns.count < 128 else { throw HitchError.historyFull }
            let index = chat.messages.count
            guard let turn = send(text, in: chat) else { throw HitchError.unavailable }
            controlTurns[turn] = ControlTurn(chatID: chatID, firstMessageIndex: index)
            return try controlJSON(["turn": turn.uuidString, "chat": chatID.uuidString, "state": "accepted"])
        case "turn.read":
            let turn = try uuid("turn")
            guard let record = controlTurns[turn], let chat = chats.first(where: { $0.id == record.chatID }) else {
                throw HitchError.unavailable
            }
            return try controlJSON(
                record.finalSnapshot
                    ?? controlSnapshot(
                        turn: turn, record: record, chat: chat, running: shepherd.activeTurnID == turn))
        case "turn.cancel":
            let turn = try uuid("turn")
            guard var record = controlTurns[turn] else { throw HitchError.unavailable }
            if shepherd.activeTurnID == turn {
                record.cancelled = true
                controlTurns[turn] = record
                shepherd.stop(sessionID: record.chatID, turnID: turn)
            }
            return try controlJSON([
                "turn": turn.uuidString, "state": record.cancelled ? "cancellation_requested" : "already_ended",
            ])
        default: throw HitchError.invalidArguments
        }
    }
}
