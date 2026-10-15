import Foundation
import Testing

@testable import Inference

/// A flag the test can flip from a callback and read from any task.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    private var count = 0
    func raise() {
        lock.lock()
        defer { lock.unlock() }
        raised = true
        count += 1
    }
    var isRaised: Bool {
        lock.lock()
        defer { lock.unlock() }
        return raised
    }
    var raises: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

@Test func closureIsNotObservableUntilAcknowledgeCallbacksHaveRun() async {
    let handle = GenerationTransportClosureHandle()
    let callbackDone = Flag()
    // The callback deliberately takes a while, as the subagent quarantine's bookkeeping might.
    handle.onAcknowledge {
        Thread.sleep(forTimeInterval: 0.15)
        callbackDone.raise()
    }

    // Acknowledge from another task, the way the engine's producer task does after its stream ends.
    let producer = Task.detached { handle.acknowledge() }

    let closed = await handle.waitForClosure(timeoutSeconds: 5)
    #expect(closed == true)
    #expect(callbackDone.isRaised, "waitForClosure resumed before the acknowledge callback ran")
    #expect(handle.isClosed)
    await producer.value
}

@Test func isClosedReadsFalseWhileCallbacksAreStillRunning() async {
    let handle = GenerationTransportClosureHandle()
    let observedWhileRunning = Flag()
    handle.onAcknowledge {
        if handle.isClosed == false { observedWhileRunning.raise() }
    }
    handle.acknowledge()
    #expect(observedWhileRunning.isRaised, "isClosed flipped before the callback finished")
    #expect(handle.isClosed)
}

@Test func callbackRegisteredDuringAcknowledgeStillRunsBeforeClosure() async {
    let handle = GenerationTransportClosureHandle()
    let late = Flag()
    handle.onAcknowledge {
        handle.onAcknowledge { late.raise() }
    }
    handle.acknowledge()
    #expect(late.isRaised)
    #expect(handle.isClosed)
}

@Test func callbackRegisteredAfterClosureRunsImmediately() async {
    let handle = GenerationTransportClosureHandle()
    handle.acknowledge()
    let flag = Flag()
    handle.onAcknowledge { flag.raise() }
    #expect(flag.isRaised)
}

@Test func acknowledgeIsIdempotent() async {
    let handle = GenerationTransportClosureHandle()
    let flag = Flag()
    handle.onAcknowledge { flag.raise() }
    handle.acknowledge()
    handle.acknowledge()
    #expect(flag.raises == 1)
    #expect(await handle.waitForClosure(timeoutSeconds: 1))
}

@Test func waitersResumeOnlyAfterCallbacks() async {
    let handle = GenerationTransportClosureHandle()
    let callbackDone = Flag()
    handle.onAcknowledge {
        Thread.sleep(forTimeInterval: 0.1)
        callbackDone.raise()
    }
    // Park a waiter first, then acknowledge from elsewhere so the waiter path (not the fast path) is exercised.
    let waiter = Task { await handle.waitForClosure(timeoutSeconds: 5) }
    try? await Task.sleep(for: .milliseconds(50))
    let producer = Task.detached { handle.acknowledge() }
    #expect(await waiter.value == true)
    #expect(callbackDone.isRaised)
    await producer.value
}
