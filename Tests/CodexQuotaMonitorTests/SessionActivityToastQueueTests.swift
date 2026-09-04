import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

@MainActor
final class SessionActivityToastQueueTests: XCTestCase {
    func testLeftAndRightLanesAreIndependentAndFIFO() async {
        let sleeper = ToastSleeperGate()
        let queue = makeQueue(sleeper: sleeper)
        let leftFirst = transition(accountID: "C1", side: .left, status: .working)
        let leftSecond = transition(accountID: "C2", side: .left, status: .waiting)
        let rightFirst = transition(accountID: "C3", side: .right, status: .completed)

        queue.enqueue(leftFirst)
        queue.enqueue(leftSecond)
        queue.enqueue(rightFirst)

        await sleeper.waitUntilCount(atLeast: 2)
        XCTAssertEqual(queue.currentLeft?.transition, leftFirst)
        XCTAssertEqual(queue.currentRight?.transition, rightFirst)
        XCTAssertEqual(queue.pendingLeft.map(\.transition), [leftSecond])

        await sleeper.releaseNext()
        await sleeper.waitUntilCount(atLeast: 3)
        XCTAssertEqual(queue.currentLeft?.transition, leftSecond)
        XCTAssertEqual(queue.currentRight?.transition, rightFirst)
        queue.cancel()
    }

    func testIdenticalTransitionsAreDeduplicatedAcrossCurrentAndPending() async {
        let sleeper = ToastSleeperGate()
        let queue = makeQueue(sleeper: sleeper)
        let first = transition(accountID: "C1", side: .left, status: .working)
        let second = transition(accountID: "C1", side: .left, status: .waiting)

        queue.enqueue(first)
        await sleeper.waitUntilCount(atLeast: 1)
        queue.enqueue(second)
        queue.enqueue(second)
        queue.enqueue(first)

        XCTAssertEqual(queue.pendingLeft.count, 1)
        XCTAssertEqual(queue.pendingLeft.first?.transition, second)
        queue.cancel()
    }

    func testTransitionDeduplicationIgnoresDurationChanges() async {
        let sleeper = ToastSleeperGate()
        let queue = makeQueue(sleeper: sleeper)
        let current = transition(accountID: "C1", side: .left, status: .working)
        let pending = transition(accountID: "C1", side: .left, status: .waiting)

        queue.enqueue(current)
        await sleeper.waitUntilCount(atLeast: 1)
        queue.updateDuration(seconds: 7)
        queue.enqueue(current)
        XCTAssertTrue(queue.pendingLeft.isEmpty)

        queue.enqueue(pending)
        queue.updateDuration(seconds: 9)
        queue.enqueue(pending)

        XCTAssertEqual(queue.pendingLeft.count, 1)
        XCTAssertEqual(queue.pendingLeft.first?.transition, pending)
        queue.cancel()
    }

    func testPendingEntriesAreCappedAndOverflowBecomesDeterministicSummary() async {
        let sleeper = ToastSleeperGate()
        let queue = makeQueue(sleeper: sleeper)
        queue.enqueue(transition(accountID: "C1", side: .left, status: .working))
        await sleeper.waitUntilCount(atLeast: 1)
        for index in 1...5 {
            queue.enqueue(transition(accountID: "C1", side: .left, status: status(for: index)))
        }

        XCTAssertEqual(queue.pendingLeft.count, 3)
        XCTAssertEqual(queue.pendingLeft.dropLast().count, 2)
        XCTAssertTrue(queue.pendingLeft.last?.isOverflowSummary == true)
        XCTAssertEqual(queue.pendingLeft.last?.overflowCount, 2)
        queue.cancel()
    }

    func testOverflowSummaryKeepsItsCapturedDurationAfterQueueDurationChanges() async {
        let sleeper = ToastSleeperGate()
        let queue = makeQueue(sleeper: sleeper)
        queue.enqueue(transition(accountID: "C1", side: .left, status: .working))
        await sleeper.waitUntilCount(atLeast: 1)
        for index in 1...4 {
            queue.enqueue(transition(accountID: "C1", side: .left, status: status(for: index)))
        }

        XCTAssertEqual(queue.pendingLeft.last?.durationSeconds, 3)
        queue.updateDuration(seconds: 8)
        queue.enqueue(transition(accountID: "C1", side: .left, status: .unknown))

        XCTAssertTrue(queue.pendingLeft.last?.isOverflowSummary == true)
        XCTAssertEqual(queue.pendingLeft.last?.overflowCount, 2)
        XCTAssertEqual(queue.pendingLeft.last?.durationSeconds, 3)
        queue.cancel()
    }

    func testConfiguredDurationIsPassedToInjectedSleeper() async {
        let sleeper = ToastSleeperGate()
        let queue = SessionActivityToastQueue(
            durationSeconds: 7,
            sleep: { seconds in await sleeper.sleep(seconds) }
        )
        queue.enqueue(transition(accountID: "C4", side: .right, status: .error))

        await sleeper.waitUntilCount(atLeast: 1)
        let firstInterval = await sleeper.intervals.first
        XCTAssertEqual(firstInterval, 7)
        XCTAssertEqual(queue.currentRight?.durationSeconds, 7)
        queue.cancel()
    }

    func testCancellationClearsBothLanesAndPreventsStaleCompletion() async {
        let sleeper = ToastSleeperGate()
        let queue = makeQueue(sleeper: sleeper)
        queue.enqueue(transition(accountID: "C1", side: .left, status: .working))
        queue.enqueue(transition(accountID: "C3", side: .right, status: .waiting))
        await sleeper.waitUntilCount(atLeast: 2)

        queue.cancel()
        XCTAssertNil(queue.currentLeft)
        XCTAssertNil(queue.currentRight)
        XCTAssertTrue(queue.pendingLeft.isEmpty)
        XCTAssertTrue(queue.pendingRight.isEmpty)

        await sleeper.releaseAll()
        await Task.yield()
        XCTAssertNil(queue.currentLeft)
        XCTAssertNil(queue.currentRight)
    }

    private func makeQueue(sleeper: ToastSleeperGate) -> SessionActivityToastQueue {
        SessionActivityToastQueue(
            durationSeconds: 3,
            sleep: { seconds in await sleeper.sleep(seconds) }
        )
    }

    private func transition(
        accountID: String,
        side: AccountPosition,
        status: SessionActivityStatus
    ) -> SessionActivityTransition {
        SessionActivityTransition(
            accountID: accountID,
            side: side,
            sessionID: "session-\(accountID)",
            agentLabel: nil,
            taskName: nil,
            status: status
        )
    }

    private func status(for index: Int) -> SessionActivityStatus {
        switch index {
        case 1: return .waiting
        case 2: return .completed
        case 3: return .stopped
        default: return .error
        }
    }
}

private actor ToastSleeperGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var intervals: [TimeInterval] = []

    func sleep(_ seconds: TimeInterval) async {
        intervals.append(seconds)
        let count = intervals.count
        let ready = waiters.filter { $0.0 <= count }
        waiters.removeAll { $0.0 <= count }
        for (_, continuation) in ready {
            continuation.resume()
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitUntilCount(atLeast target: Int) async {
        guard intervals.count < target else { return }
        await withCheckedContinuation { continuation in
            waiters.append((target, continuation))
        }
    }

    func releaseNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func releaseAll() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}
