import Foundation

/// User-visible startup progression. Local state becomes available before optional services settle.
enum StartupPhase: Sendable, Equatable {
    case launching
    case restoringLocalState
    case connectingServices
    case ready
    case failed(String)

    var hasLocalState: Bool {
        switch self {
        case .launching, .restoringLocalState, .failed: false
        case .connectingServices, .ready: true
        }
    }

    var servicesSettled: Bool { self == .ready }

    var statusText: String {
        switch self {
        case .launching: "Starting GOAT..."
        case .restoringLocalState: "Restoring chats and Pens..."
        case .connectingServices: "Connecting engine and tools..."
        case .ready: "Ready"
        case .failed(let message): message
        }
    }
}

/// Owns the one app startup task. Every window joins the same operation, and cancelling a view's
/// `.task` waiter cannot cancel initialization for the rest of the app.
actor StartupCoordinator {
    private var task: Task<Void, Never>?

    func run(_ operation: @escaping @MainActor @Sendable () async -> Void) async {
        if let task {
            await task.value
            return
        }
        let task = Task { @MainActor in
            await operation()
        }
        self.task = task
        await task.value
    }

    func reset() {
        task = nil
    }
}
