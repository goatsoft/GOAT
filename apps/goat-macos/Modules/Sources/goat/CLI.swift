import Darwin
import Foundation
import Hitch

@main
struct CLI {
    static func main() async {
        do { try await run() } catch {
            let code = (error as? HitchError)?.rawValue ?? "request_failed"
            FileHandle.standardError.write(
                Data(
                    "goat: \(code)\nRun goat --help for usage. For connection failures, check that Hitch is enabled in the running app.\n"
                        .utf8))
            exit(1)
        }
    }
    static func run() async throws {
        var args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty || args == ["--help"] {
            print(
                """
                goat: local Hitch client (API v1)
                goat status
                goat pens list [--cursor OFFSET]
                goat chats list [--pen UUID] [--cursor OFFSET]
                goat chats create [--pen UUID]
                goat send --chat UUID --text TEXT [--follow]
                goat watch --turn UUID
                goat cancel --turn UUID
                Options: --socket PATH, --request-id UUID (safe retry within one enabled session)
                Replies are JSON. Follow/watch emits bounded JSON snapshots until the turn ends.
                No network port is used. Permissions are answered in the GOAT app.
                """)
            return
        }
        var path = LocalSocket.defaultPath()
        var id = UUID()
        var follow = false
        var fields: [String: String] = [:]
        var words: [String] = []
        while !args.isEmpty {
            let arg = args.removeFirst()
            if arg == "--follow" {
                follow = true
                continue
            }
            if arg.hasPrefix("--") {
                guard !args.isEmpty else { throw HitchError.invalidArguments }
                let value = args.removeFirst()
                switch arg {
                case "--socket": path = value
                case "--request-id":
                    guard let parsed = UUID(uuidString: value) else { throw HitchError.invalidArguments }
                    id = parsed
                case "--pen", "--chat", "--text", "--turn", "--cursor":
                    let key = String(arg.dropFirst(2))
                    guard fields[key] == nil else { throw HitchError.invalidArguments }
                    fields[key] = value
                default: throw HitchError.invalidArguments
                }
            } else {
                words.append(arg)
            }
        }
        let operations = [
            "status": "status", "pens list": "pens.list", "chats list": "chats.list",
            "chats create": "chats.create", "send": "turn.send", "watch": "turn.read", "cancel": "turn.cancel",
        ]
        guard let operation = operations[words.joined(separator: " ")] else { throw HitchError.invalidArguments }
        guard !follow || operation == "turn.send" else { throw HitchError.invalidArguments }
        let request = HitchRequest(id: id, operation: operation, arguments: fields)
        let result = try LocalSocket.request(request, path: path)
        try printReply(result)
        if operation == "turn.read" || (operation == "turn.send" && follow) {
            let value = try JSONDecoder().decode([String: String].self, from: Data((result.result ?? "{}").utf8))
            guard let turn = value["turn"] ?? fields["turn"] else { throw HitchError.protocolError }
            var last = result.result
            var state = value["state"]
            while state != "completed" && state != "cancelled" && state != "failed" {
                try await Task.sleep(for: .milliseconds(200))
                let next = try LocalSocket.request(
                    HitchRequest(operation: "turn.read", arguments: ["turn": turn]), path: path)
                if next.result != last || next.error != nil {
                    try printReply(next)
                    last = next.result
                }
                let snapshot = try JSONDecoder().decode([String: String].self, from: Data((next.result ?? "{}").utf8))
                state = snapshot["state"]
            }
        }
    }
    static func printReply(_ reply: HitchReply) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(reply), as: UTF8.self))
        if let error = reply.error {
            FileHandle.standardError.write(Data("goat: \(error)\n".utf8))
            exit(1)
        }
    }
}
