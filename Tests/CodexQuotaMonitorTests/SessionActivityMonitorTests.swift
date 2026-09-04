import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

@MainActor
final class SessionActivityMonitorTests: XCTestCase {
    func testFirstPollEstablishesBaselineWithoutEmittingTransition() async {
        let account = makeAccount(id: "C1", home: "/tmp/monitor-c1", side: .left)
        let baseline = snapshot(
            accountID: "C1",
            source: .localActivity,
            sessionID: "session-1",
            status: .working
        )
        let queue = SnapshotQueue(values: ["C1": [baseline]])
        let recorder = TransitionRecorder()
        let monitor = makeMonitor(
            accounts: [account],
            queue: queue,
            recorder: recorder
        )

        await monitor.pollNow()

        XCTAssertTrue(recorder.events.isEmpty)
        let storedSnapshot = await monitor.snapshot(for: "C1")
        XCTAssertEqual(storedSnapshot, baseline)
    }

    func testSessionStartAndEndEmitTransitions() async {
        let account = makeAccount(id: "C1", home: "/tmp/monitor-c1", side: .left)
        let queue = SnapshotQueue(values: [
            "C1": [
                .empty(accountID: "C1"),
                snapshot(accountID: "C1", sessionID: "session-1", status: .working),
                .empty(accountID: "C1"),
            ],
        ])
        let recorder = TransitionRecorder()
        let monitor = makeMonitor(accounts: [account], queue: queue, recorder: recorder)

        await monitor.pollNow()
        await monitor.pollNow()
        await monitor.pollNow()

        XCTAssertEqual(recorder.events.count, 2)
        XCTAssertEqual(recorder.events[0].accountID, "C1")
        XCTAssertEqual(recorder.events[0].side, .left)
        XCTAssertEqual(recorder.events[0].sessionID, "session-1")
        XCTAssertEqual(recorder.events[0].status, .working)
        XCTAssertEqual(recorder.events[1].sessionID, "session-1")
        XCTAssertEqual(recorder.events[1].status, .unknown)
        XCTAssertNil(recorder.events[1].taskName)
    }

    func testAgentStatusChangesEmitOnceAndRepeatedStateIsDeduplicated() async {
        let account = makeAccount(id: "C2", home: "/tmp/monitor-c2", side: .left)
        let waiting = snapshot(
            accountID: "C2",
            sessionID: "session-2",
            status: .working,
            agents: [agent(id: "worker", taskName: "Worker", status: .waiting)]
        )
        let working = snapshot(
            accountID: "C2",
            sessionID: "session-2",
            status: .working,
            agents: [agent(id: "worker", taskName: "Worker", status: .working)]
        )
        let queue = SnapshotQueue(values: ["C2": [waiting, waiting, working, working]])
        let recorder = TransitionRecorder()
        let monitor = makeMonitor(accounts: [account], queue: queue, recorder: recorder)

        await monitor.pollNow()
        await monitor.pollNow()
        await monitor.pollNow()
        await monitor.pollNow()

        XCTAssertEqual(recorder.events.count, 1)
        XCTAssertEqual(recorder.events[0].accountID, "C2")
        XCTAssertEqual(recorder.events[0].agentLabel, "Worker")
        XCTAssertEqual(recorder.events[0].taskName, "Worker")
        XCTAssertEqual(recorder.events[0].status, .working)
    }

    func testSourceOnlyChangeDoesNotEmitTransition() async {
        let account = makeAccount(id: "C1", home: "/tmp/monitor-c1", side: .left)
        let local = snapshot(
            accountID: "C1",
            source: .localActivity,
            sessionID: "session-1",
            status: .working
        )
        let lastKnown = snapshot(
            accountID: "C1",
            source: .lastKnown,
            sessionID: "session-1",
            status: .working
        )
        let queue = SnapshotQueue(values: ["C1": [local, lastKnown]])
        let recorder = TransitionRecorder()
        let monitor = makeMonitor(accounts: [account], queue: queue, recorder: recorder)

        await monitor.pollNow()
        await monitor.pollNow()

        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testUnavailableDoesNotEmitEndAndRecoveryRebaselines() async {
        let account = makeAccount(id: "C1", home: "/tmp/monitor-c1", side: .left)
        let sibling = makeAccount(id: "C2", home: "/tmp/monitor-c2", side: .left)
        let active = snapshot(
            accountID: "C1",
            sessionID: "session-1",
            status: .working
        )
        let siblingActive = snapshot(
            accountID: "C2",
            sessionID: "sibling-session",
            status: .working
        )
        let queue = SnapshotQueue(values: [
            "C1": [
                active,
                .unavailable(accountID: "C1"),
                active,
            ],
            "C2": [siblingActive, siblingActive, siblingActive],
        ])
        let recorder = TransitionRecorder()
        let monitor = makeMonitor(
            accounts: [account, sibling],
            queue: queue,
            recorder: recorder
        )

        await monitor.pollNow()
        await monitor.pollNow()
        await monitor.pollNow()

        XCTAssertTrue(recorder.events.isEmpty)
        let recovered = await monitor.snapshot(for: "C1")
        XCTAssertEqual(recovered?.state, .available)
        XCTAssertEqual(recovered?.sessionID, "session-1")
    }

    func testStopRestartSerializesNonCooperativePollAndDiscardsOldGeneration() async {
        let account = makeAccount(id: "C1", home: "/tmp/monitor-c1", side: .left)
        let callCounter = LockedCounter()
        let gate = RestartProviderGate(
            stale: snapshot(accountID: "C1", sessionID: "stale", status: .working),
            fresh: snapshot(accountID: "C1", sessionID: "fresh", status: .working),
            counter: callCounter
        )
        let monitor = SessionActivityMonitor(
            accounts: [account],
            provider: RestartSessionActivityProvider(gate: gate),
            onTransition: { _ in }
        )

        let oldPoll = Task.detached {
            await monitor.pollNow()
        }
        await gate.waitUntilFirstEntered()

        await monitor.stop()
        let replacementPoll = Task.detached {
            await monitor.pollNow()
        }

        for _ in 0..<30 {
            await Task.yield()
        }
        let callsWhileBlocked = callCounter.value
        XCTAssertEqual(callsWhileBlocked, 1)

        await gate.releaseFirst()
        await oldPoll.value
        await replacementPoll.value
        for _ in 0..<100 {
            if callCounter.value >= 2 { break }
            await Task.yield()
        }

        let callsAfterRelease = callCounter.value
        XCTAssertEqual(callsAfterRelease, 2)
        let current = await monitor.snapshot(for: "C1")
        XCTAssertEqual(current?.sessionID, "fresh")
        await monitor.start()
        await monitor.stop()
    }

    func testStopDuringFirstTransitionCallbackSuppressesRemainingCallbacks() async {
        let account = makeAccount(id: "C1", home: "/tmp/monitor-c1", side: .left)
        let baseline = snapshot(
            accountID: "C1",
            sessionID: "session-1",
            status: .working,
            agents: [agent(id: "worker", taskName: "Worker", status: .waiting)]
        )
        let changed = snapshot(
            accountID: "C1",
            sessionID: "session-1",
            status: .completed,
            agents: [agent(id: "worker", taskName: "Worker", status: .working)]
        )
        let queue = SnapshotQueue(values: ["C1": [baseline, changed]])
        let recorder = TransitionRecorder()
        let callbackGate = BlockingCallbackGate()
        let monitor = makeMonitorWithBlockingFirstCallback(
            account: account,
            queue: queue,
            recorder: recorder,
            callbackGate: callbackGate
        )

        await monitor.pollNow()
        let secondPoll = Task.detached {
            await monitor.pollNow()
        }
        let stopper = Task.detached {
            callbackGate.waitUntilEntered()
            await monitor.stop()
            callbackGate.release()
        }

        await secondPoll.value
        await stopper.value
        XCTAssertEqual(recorder.events.count, 1)
        await monitor.stop()
    }

    func testTransitionsApplyInConfiguredAccountOrderAfterConcurrentPoll() async {
        let c1 = makeAccount(id: "C1", home: "/tmp/monitor-c1", side: .left)
        let c2 = makeAccount(id: "C2", home: "/tmp/monitor-c2", side: .left)
        let providerGate = OrderedCompletionProviderGate()
        let recorder = TransitionRecorder()
        let monitor = SessionActivityMonitor(
            accounts: [c2, c1],
            provider: OrderedCompletionSessionActivityProvider(gate: providerGate),
            onTransition: { transition in
                recorder.events.append(transition)
            }
        )

        await monitor.pollNow()
        let secondPoll = Task.detached {
            await monitor.pollNow()
        }
        await providerGate.waitUntilSecondPollAccountsEntered()
        await providerGate.releaseC2()
        await providerGate.waitUntilC2Returned()
        await providerGate.releaseC1()
        await secondPoll.value

        XCTAssertEqual(recorder.events.map(\.accountID), ["C1", "C2"])
        await monitor.stop()
    }

    func testOneAccountUnavailableDoesNotBlockSiblingSessionStart() async {
        let c1 = makeAccount(id: "C1", home: "/tmp/monitor-c1", side: .left)
        let c2 = makeAccount(id: "C2", home: "/tmp/monitor-c2", side: .left)
        let queue = SnapshotQueue(values: [
            "C1": [.unavailable(accountID: "C1"), .unavailable(accountID: "C1")],
            "C2": [
                .empty(accountID: "C2"),
                snapshot(accountID: "C2", sessionID: "session-2", status: .working),
            ],
        ])
        let recorder = TransitionRecorder()
        let monitor = makeMonitor(accounts: [c1, c2], queue: queue, recorder: recorder)

        await monitor.pollNow()
        await monitor.pollNow()

        XCTAssertEqual(recorder.events.map(\.accountID), ["C2"])
        let c1Snapshot = await monitor.currentSnapshots["C1"]
        XCTAssertEqual(c1Snapshot?.state, .unavailable)
    }

    func testMismatchedSnapshotAccountIDIsRejectedWithoutBlockingSiblingTransitions() async {
        let c1 = makeAccount(id: "C1", home: "/tmp/monitor-c1", side: .left)
        let c2 = makeAccount(id: "C2", home: "/tmp/monitor-c2", side: .right)
        let queue = SnapshotQueue(values: [
            "C1": [
                snapshot(accountID: "C2", sessionID: "wrong-session", status: .working),
                snapshot(accountID: "C2", sessionID: "wrong-session-2", status: .completed),
            ],
            "C2": [
                .empty(accountID: "C2"),
                snapshot(accountID: "C2", sessionID: "valid-session", status: .working),
            ],
        ])
        let recorder = TransitionRecorder()
        let monitor = makeMonitor(accounts: [c1, c2], queue: queue, recorder: recorder)

        await monitor.pollNow()
        await monitor.pollNow()

        let mismatchedAccountSnapshot = await monitor.snapshot(for: "C1")
        let validSiblingSnapshot = await monitor.snapshot(for: "C2")
        XCTAssertNil(mismatchedAccountSnapshot)
        XCTAssertEqual(validSiblingSnapshot?.sessionID, "valid-session")
        XCTAssertEqual(recorder.events.map(\.accountID), ["C2"])
    }

    func testUnconfiguredAccountsAreNotPolled() async {
        let unconfigured = AccountConfig.unconfigured(id: "C1", position: .left)
        let configured = makeAccount(id: "C2", home: "/tmp/monitor-c2", side: .left)
        let callRecorder = SessionProviderCallRecorder()
        let monitor = SessionActivityMonitor(
            accounts: [unconfigured, configured],
            provider: RecordingSessionActivityProvider(recorder: callRecorder),
            onTransition: { _ in }
        )

        await monitor.pollNow()

        let polledAccountIDs = await callRecorder.accountIDs
        let unconfiguredSnapshot = await monitor.snapshot(for: "C1")
        let configuredSnapshot = await monitor.snapshot(for: "C2")
        XCTAssertEqual(Set(polledAccountIDs), ["C2"])
        XCTAssertNil(unconfiguredSnapshot)
        XCTAssertEqual(configuredSnapshot?.state, .empty)
    }

    func testPathReconfigurationResetsChangedAccountBaseline() async {
        let oldAccount = makeAccount(id: "C1", home: "/tmp/monitor-old", side: .left)
        let newAccount = makeAccount(id: "C1", home: "/tmp/monitor-new", side: .left)
        let queue = SnapshotQueue(values: [
            "C1": [
                snapshot(accountID: "C1", sessionID: "old-session", status: .working),
                snapshot(accountID: "C1", sessionID: "new-session", status: .working),
            ],
        ])
        let recorder = TransitionRecorder()
        let monitor = makeMonitor(accounts: [oldAccount], queue: queue, recorder: recorder)

        await monitor.pollNow()
        await monitor.reconfigure(accounts: [newAccount])
        await monitor.pollNow()

        XCTAssertTrue(recorder.events.isEmpty)
        let storedSessionID = await monitor.snapshot(for: "C1")?.sessionID
        XCTAssertEqual(storedSessionID, "new-session")
    }

    func testConcurrentPollRequestsShareOneProviderPoll() async {
        let account = makeAccount(id: "C1", home: "/tmp/monitor-c1", side: .left)
        let gate = BlockingProviderGate(
            snapshot: snapshot(accountID: "C1", sessionID: "session-1", status: .working)
        )
        let provider = BlockingSessionActivityProvider(gate: gate)
        let monitor = SessionActivityMonitor(
            accounts: [account],
            provider: provider,
            onTransition: { _ in }
        )

        let first = Task { await monitor.pollNow() }
        await gate.waitUntilEntered()
        let second = Task { await monitor.pollNow() }
        await Task.yield()

        let firstCallCount = await gate.callCount
        XCTAssertEqual(firstCallCount, 1)
        await gate.release()
        await first.value
        await second.value
        let secondCallCount = await gate.callCount
        XCTAssertEqual(secondCallCount, 1)
    }

    func testStartUsesTwoSecondSharedLoopAndStopCancelsIt() async {
        let account = makeAccount(id: "C1", home: "/tmp/monitor-c1", side: .left)
        let sleeper = SleeperProbe()
        let provider = StaticSessionActivityProvider(
            snapshotValue: .unavailable(accountID: "C1")
        )
        let monitor = SessionActivityMonitor(
            accounts: [account],
            provider: provider,
            sleep: { seconds in await sleeper.sleep(seconds) },
            onTransition: { _ in }
        )

        await monitor.start()
        await waitUntil { await sleeper.intervals.count >= 1 }

        let firstInterval = await sleeper.intervals.first
        XCTAssertEqual(firstInterval, SessionActivityMonitor.defaultPollInterval)
        let isRunning = await monitor.isRunning
        XCTAssertTrue(isRunning)

        await monitor.stop()

        let isRunningAfterStop = await monitor.isRunning
        XCTAssertFalse(isRunningAfterStop)
    }

    private func makeMonitor(
        accounts: [AccountConfig],
        queue: SnapshotQueue,
        recorder: TransitionRecorder
    ) -> SessionActivityMonitor {
        SessionActivityMonitor(
            accounts: accounts,
            provider: QueuedSessionActivityProvider(queue: queue),
            onTransition: { transition in
                recorder.events.append(transition)
            }
        )
    }

    private func makeMonitorWithBlockingFirstCallback(
        account: AccountConfig,
        queue: SnapshotQueue,
        recorder: TransitionRecorder,
        callbackGate: BlockingCallbackGate
    ) -> SessionActivityMonitor {
        SessionActivityMonitor(
            accounts: [account],
            provider: QueuedSessionActivityProvider(queue: queue),
            onTransition: { transition in
                recorder.events.append(transition)
                if recorder.events.count == 1 {
                    callbackGate.blockUntilReleased()
                }
            }
        )
    }

    private func makeAccount(id: String, home: String, side: AccountPosition) -> AccountConfig {
        AccountConfig(id: id, home: URL(fileURLWithPath: home), position: side)
    }

    private func snapshot(
        accountID: String,
        source: SessionActivitySource = .localActivity,
        sessionID: String?,
        status: SessionActivityStatus,
        agents: [SessionActivityAgent] = []
    ) -> SessionActivitySnapshot {
        SessionActivitySnapshot(
            accountID: accountID,
            state: .available,
            source: source,
            sessionID: sessionID,
            status: status,
            agents: agents
        )
    }

    private func agent(
        id: String,
        taskName: String,
        status: SessionActivityStatus
    ) -> SessionActivityAgent {
        SessionActivityAgent(
            threadID: id,
            parentThreadID: nil,
            taskName: taskName,
            status: status
        )
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool
    ) async {
        for _ in 0..<100 {
            if await condition() { return }
            await Task.yield()
        }
    }
}

private actor SnapshotQueue {
    private var values: [String: [SessionActivitySnapshot]]

    init(values: [String: [SessionActivitySnapshot]]) {
        self.values = values
    }

    func next(accountID: String) -> SessionActivitySnapshot {
        guard var accountValues = values[accountID], !accountValues.isEmpty else {
            return .unavailable(accountID: accountID)
        }
        let next = accountValues.removeFirst()
        values[accountID] = accountValues
        return next
    }
}

private struct QueuedSessionActivityProvider: SessionActivityProvider {
    let queue: SnapshotQueue

    func snapshot(accountID: String, home: URL) async -> SessionActivitySnapshot {
        await queue.next(accountID: accountID)
    }
}

private actor SessionProviderCallRecorder {
    private(set) var accountIDs: [String] = []

    func record(_ accountID: String) {
        accountIDs.append(accountID)
    }
}

private struct RecordingSessionActivityProvider: SessionActivityProvider {
    let recorder: SessionProviderCallRecorder

    func snapshot(accountID: String, home: URL) async -> SessionActivitySnapshot {
        await recorder.record(accountID)
        return .empty(accountID: accountID)
    }
}

private struct StaticSessionActivityProvider: SessionActivityProvider {
    let snapshotValue: SessionActivitySnapshot

    func snapshot(accountID: String, home: URL) async -> SessionActivitySnapshot {
        snapshotValue
    }
}

@MainActor
private final class TransitionRecorder: NSObject {
    var events: [SessionActivityTransition] = []
}

private actor BlockingProviderGate {
    private let snapshotValue: SessionActivitySnapshot
    private var entered = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0

    init(snapshot: SessionActivitySnapshot) {
        self.snapshotValue = snapshot
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func next() async -> SessionActivitySnapshot {
        callCount += 1
        entered = true
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return snapshotValue
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private struct BlockingSessionActivityProvider: SessionActivityProvider {
    let gate: BlockingProviderGate

    func snapshot(accountID: String, home: URL) async -> SessionActivitySnapshot {
        await gate.next()
    }
}

private actor RestartProviderGate {
    private let stale: SessionActivitySnapshot
    private let fresh: SessionActivitySnapshot
    private var firstEntered = false
    private var firstEnteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private let counter: LockedCounter
    private(set) var callCount = 0

    init(
        stale: SessionActivitySnapshot,
        fresh: SessionActivitySnapshot,
        counter: LockedCounter
    ) {
        self.stale = stale
        self.fresh = fresh
        self.counter = counter
    }

    func waitUntilFirstEntered() async {
        guard !firstEntered else { return }
        await withCheckedContinuation { continuation in
            firstEnteredContinuation = continuation
        }
    }

    func releaseFirst() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func next() async -> SessionActivitySnapshot {
        callCount += 1
        counter.increment()
        if callCount == 1 {
            firstEntered = true
            firstEnteredContinuation?.resume()
            firstEnteredContinuation = nil
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
            return stale
        }
        return fresh
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private struct RestartSessionActivityProvider: SessionActivityProvider {
    let gate: RestartProviderGate

    func snapshot(accountID: String, home: URL) async -> SessionActivitySnapshot {
        await gate.next()
    }
}

private final class BlockingCallbackGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let releaseSemaphore = DispatchSemaphore(value: 0)

    func blockUntilReleased() {
        entered.signal()
        releaseSemaphore.wait()
    }

    func waitUntilEntered() {
        entered.wait()
    }

    func release() {
        releaseSemaphore.signal()
    }
}

private actor OrderedCompletionProviderGate {
    private var callCounts: [String: Int] = [:]
    private var c1SecondEntered = false
    private var c2SecondEntered = false
    private var c2Returned = false
    private var bothEnteredContinuation: CheckedContinuation<Void, Never>?
    private var c2ReturnedContinuation: CheckedContinuation<Void, Never>?
    private var c1ReleaseContinuation: CheckedContinuation<Void, Never>?
    private var c2ReleaseContinuation: CheckedContinuation<Void, Never>?

    func waitUntilSecondPollAccountsEntered() async {
        guard !(c1SecondEntered && c2SecondEntered) else { return }
        await withCheckedContinuation { continuation in
            bothEnteredContinuation = continuation
        }
    }

    func releaseC1() {
        c1ReleaseContinuation?.resume()
        c1ReleaseContinuation = nil
    }

    func releaseC2() {
        c2ReleaseContinuation?.resume()
        c2ReleaseContinuation = nil
    }

    func waitUntilC2Returned() async {
        guard !c2Returned else { return }
        await withCheckedContinuation { continuation in
            c2ReturnedContinuation = continuation
        }
    }

    func next(accountID: String) async -> SessionActivitySnapshot {
        let callCount = (callCounts[accountID] ?? 0) + 1
        callCounts[accountID] = callCount
        guard callCount == 2 else {
            return .empty(accountID: accountID)
        }

        if accountID == "C1" {
            c1SecondEntered = true
            if c1SecondEntered && c2SecondEntered {
                bothEnteredContinuation?.resume()
                bothEnteredContinuation = nil
            }
            await withCheckedContinuation { continuation in
                c1ReleaseContinuation = continuation
            }
        } else if accountID == "C2" {
            c2SecondEntered = true
            if c1SecondEntered && c2SecondEntered {
                bothEnteredContinuation?.resume()
                bothEnteredContinuation = nil
            }
            await withCheckedContinuation { continuation in
                c2ReleaseContinuation = continuation
            }
            c2Returned = true
            c2ReturnedContinuation?.resume()
            c2ReturnedContinuation = nil
        }

        return SessionActivitySnapshot(
            accountID: accountID,
            state: .available,
            source: .localActivity,
            sessionID: "session-\(accountID)",
            status: .working,
            agents: []
        )
    }
}

private struct OrderedCompletionSessionActivityProvider: SessionActivityProvider {
    let gate: OrderedCompletionProviderGate

    func snapshot(accountID: String, home: URL) async -> SessionActivitySnapshot {
        await gate.next(accountID: accountID)
    }
}

private actor SleeperProbe {
    private(set) var intervals: [TimeInterval] = []

    func sleep(_ seconds: TimeInterval) async {
        intervals.append(seconds)
        try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
    }
}
