import Foundation
import GOATed
import Hitch
import JUDAS

@MainActor
final class AppControlSession: ServiceProvider {
    private weak var model: AppModel?
    private let runtime: ExtensionRuntime
    private let server = HitchServer()
    private var registration: Registration?
    private var enabled = false

    init(model: AppModel, runtime: ExtensionRuntime) {
        self.model = model
        self.runtime = runtime
    }
    func start() async throws {
        guard registration == nil else { return }
        let token = try await runtime.activate(HitchExtension(service: self))
        registration = token
        enabled = true
        Judas.shared.record(.hitch, .allowed)
        let dispatcher = HitchDispatcher { [runtime] request in
            let args = String(decoding: try JSONEncoder().encode(request.arguments), as: UTF8.self)
            return try await runtime.invokeService(
                named: "goat.hitch", operation: request.operation, argumentsJSON: args)
        }
        do { try await server.start(path: LocalSocket.defaultPath(), dispatcher: dispatcher) } catch {
            enabled = false
            try? await runtime.unregister(token)
            registration = nil
            throw error
        }
    }
    func stop() async {
        enabled = false
        if let registration { try? await runtime.unregister(registration) }
        registration = nil
        await server.stop()
        Judas.shared.record(.hitch, .revoked)
    }
    func invoke(operation: String, argumentsJSON: String) async throws -> String {
        guard enabled, let model else { throw HitchError.disabled }
        let args = try JSONDecoder().decode([String: String].self, from: Data(argumentsJSON.utf8))
        Judas.shared.recordHitch(.allowed, operation: operation)
        do {
            let result = try await model.controlOperation(operation, arguments: args)
            Judas.shared.recordHitch(.completed, operation: operation)
            return result
        } catch {
            Judas.shared.recordHitch(.failed, operation: operation)
            throw error
        }
    }
}
