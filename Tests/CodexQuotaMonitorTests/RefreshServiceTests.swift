import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

@MainActor
final class RefreshServiceTests: XCTestCase {
    func testCustomIntervalsNormalizeWithinOneToOneThousandFourHundredFortyMinutes() {
        XCTAssertEqual(RefreshService.normalizedIntervalMinutes(1), 1)
        XCTAssertEqual(RefreshService.normalizedIntervalMinutes(2), 2)
        XCTAssertEqual(RefreshService.normalizedIntervalMinutes(5), 5)
        XCTAssertEqual(RefreshService.normalizedIntervalMinutes(7), 7)
        XCTAssertEqual(RefreshService.normalizedIntervalMinutes(10), 10)
        XCTAssertEqual(RefreshService.normalizedIntervalMinutes(30), 30)
        XCTAssertEqual(RefreshService.normalizedIntervalMinutes(60), 60)
        XCTAssertEqual(RefreshService.normalizedIntervalMinutes(1_440), 1_440)
        XCTAssertEqual(RefreshService.normalizedIntervalMinutes(0), 5)
        XCTAssertEqual(RefreshService.normalizedIntervalMinutes(-1), 5)
        XCTAssertEqual(RefreshService.normalizedIntervalMinutes(1_441), 1_440)
    }

    func testStartRefreshesImmediatelyAndStopCancelsFutureTicks() async {
        let sleeper = RefreshSleeper()
        let refreshes = RefreshCounter()
        let service = RefreshService(intervalMinutes: 1, sleep: { seconds in
            await sleeper.sleep(seconds)
        }) {
            await refreshes.increment()
        }

        service.start()
        await refreshes.waitForCount(1)
        await sleeper.waitUntilSleeping()
        var observedCount = await refreshes.value()
        XCTAssertEqual(observedCount, 1)
        await sleeper.releaseNext()
        await refreshes.waitForCount(2)
        await sleeper.waitUntilSleeping()
        observedCount = await refreshes.value()
        XCTAssertEqual(observedCount, 2)

        service.stop()
        await sleeper.releaseAll()
        try? await Task.sleep(nanoseconds: 20_000_000)
        observedCount = await refreshes.value()
        XCTAssertEqual(observedCount, 2)
    }

    func testRestartCancelsPreviousLoopAndUsesNewInterval() async {
        let sleeper = RefreshSleeper()
        let refreshes = RefreshCounter()
        let service = RefreshService(intervalMinutes: 1, sleep: { seconds in
            await sleeper.sleep(seconds)
        }) {
            await refreshes.increment()
        }

        service.start()
        await refreshes.waitForCount(1)
        await sleeper.waitUntilSleeping()
        service.restart(intervalMinutes: 30)
        await refreshes.waitForCount(2)
        await sleeper.waitUntilRequested(1_800)
        XCTAssertEqual(service.intervalMinutes, 30)
        let intervals = await sleeper.requestedIntervals()
        XCTAssertEqual(intervals, [60, 1800])
        service.stop()
        await sleeper.releaseAll()
    }

    func testRestartDuringInFlightRefreshRunsNewImmediateRefreshBeforeNewSleep() async {
        let sleeper = RefreshSleeper()
        let callbackGate = RefreshGate()
        let callbacks = RefreshConcurrencyProbe()
        let service = RefreshService(intervalMinutes: 1, sleep: { seconds in
            await sleeper.sleep(seconds)
        }) {
            let call = await callbacks.begin()
            if call == 1 {
                await callbackGate.waitIfBlocked()
            }
            await callbacks.end()
        }

        service.start()
        let firstCallbackReached = await callbacks.waitForCount(1)
        XCTAssertTrue(firstCallbackReached)
        service.restart(intervalMinutes: 7)
        await service.refreshNow()

        await callbackGate.release()
        let secondCallbackReached = await callbacks.waitForCount(2, timeout: 1)
        XCTAssertTrue(secondCallbackReached)
        await sleeper.waitUntilRequested(420)
        let intervals = await sleeper.requestedIntervals()
        XCTAssertEqual(intervals, [420])

        let snapshot = await callbacks.snapshot()
        XCTAssertEqual(snapshot.count, 2)
        XCTAssertEqual(snapshot.maximumConcurrent, 1)
        XCTAssertTrue(service.isRunning)

        service.stop()
        await sleeper.releaseAll()
    }

    func testManualRefreshIsImmediateAndDoesNotOverlapAnInFlightRefresh() async {
        let refreshGate = RefreshGate()
        let refreshes = RefreshCounter()
        let service = RefreshService(intervalMinutes: 30, sleep: { _ in }) {
            await refreshes.increment()
            await refreshGate.waitIfBlocked()
        }

        let first = Task { @MainActor in await service.refreshNow() }
        await refreshes.waitForCount(1)
        let second = Task { @MainActor in await service.refreshNow() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        var observedCount = await refreshes.value()
        XCTAssertEqual(observedCount, 1)
        await refreshGate.release()
        await first.value
        await second.value
        observedCount = await refreshes.value()
        XCTAssertEqual(observedCount, 2)
    }

    func testAutomaticRefreshResumesAfterBlockedManualRefreshCompletes() async {
        let sleeper = RefreshSleeper()
        let callbackGate = RefreshGate()
        let callbacks = RefreshConcurrencyProbe()
        let service = RefreshService(intervalMinutes: 7, sleep: { seconds in
            await sleeper.sleep(seconds)
        }) {
            let call = await callbacks.begin()
            if call == 1 {
                await callbackGate.waitIfBlocked()
            }
            await callbacks.end()
        }

        let manual = Task { @MainActor in await service.refreshNow() }
        let firstCallbackReached = await callbacks.waitForCount(1)
        XCTAssertTrue(firstCallbackReached)

        service.start()
        for _ in 0..<10 {
            await Task.yield()
        }
        await callbackGate.release()
        await manual.value

        let automaticCallbackReached = await callbacks.waitForCount(2, timeout: 1)
        XCTAssertTrue(automaticCallbackReached)
        let automaticSleepReached = await sleeper.waitUntilRequestedWithin(420, timeout: 1)
        XCTAssertTrue(automaticSleepReached)

        let snapshot = await callbacks.snapshot()
        XCTAssertEqual(snapshot.count, 2)
        XCTAssertEqual(snapshot.maximumConcurrent, 1)

        service.stop()
        await sleeper.releaseAll()
    }

    func testDroppingServiceDoesNotLeaveItsLoopRetainingTheService() async {
        let sleeper = RefreshSleeper()
        var service: RefreshService? = RefreshService(intervalMinutes: 30, sleep: { seconds in
            await sleeper.sleep(seconds)
        }) {
            // The callback intentionally does not capture the service.
        }
        weak var weakService: RefreshService?
        weakService = service

        service?.start()
        service = nil

        XCTAssertNil(weakService)
        await sleeper.releaseAll()
    }

    func testImmediateRestartBeforeFirstLoopWorkKeepsNewestLoopRunning() async {
        let sleeper = RefreshSleeper()
        let refreshes = RefreshCounter()
        let service = RefreshService(intervalMinutes: 1, sleep: { seconds in
            await sleeper.sleep(seconds)
        }) {
            await refreshes.increment()
        }

        service.start()
        service.restart(intervalMinutes: 30)

        await refreshes.waitForCount(1)
        await sleeper.waitUntilRequested(1_800)
        XCTAssertTrue(service.isRunning)
        XCTAssertEqual(service.intervalMinutes, 30)

        service.stop()
        await sleeper.releaseAll()
    }

    func testSevenMinuteScheduleUsesExactSecondsAndOneIntegratedCallback() async {
        let sleeper = RefreshSleeper()
        let refreshes = RefreshCounter()
        let service = RefreshService(intervalMinutes: 7, sleep: { seconds in
            await sleeper.sleep(seconds)
        }) {
            await refreshes.increment()
        }

        service.start()
        await refreshes.waitForCount(1)
        await sleeper.waitUntilRequested(420)
        let initialRefreshCount = await refreshes.value()
        let initialIntervals = await sleeper.requestedIntervals()
        XCTAssertEqual(initialRefreshCount, 1)
        XCTAssertEqual(initialIntervals, [420])

        await sleeper.releaseNext()
        await refreshes.waitForCount(2)
        let scheduledRefreshCount = await refreshes.value()
        XCTAssertEqual(scheduledRefreshCount, 2)
        service.stop()
        await sleeper.releaseAll()
    }

    func testRefreshLoopGateRejectsDelayedStaleGenerationMessages() async {
        let refreshes = RefreshCounter()
        let gate = RefreshLoopGate(
            refreshAction: { await refreshes.increment() },
            sleep: { _ in }
        )

        let firstActivation = await gate.activate(generation: 2)
        XCTAssertTrue(firstActivation)
        let newestActivation = await gate.activate(generation: 5)
        XCTAssertTrue(newestActivation)
        let staleActivation = await gate.activate(generation: 3)
        XCTAssertFalse(staleActivation)
        let staleManual = await gate.requestManual(generation: 3)
        XCTAssertFalse(staleManual)
        let staleStop = await gate.stop(generation: 4)
        XCTAssertFalse(staleStop)
        let countBeforeCurrentManual = await refreshes.value()
        XCTAssertEqual(countBeforeCurrentManual, 0)

        let currentManual = await gate.requestManual(generation: 5)
        XCTAssertTrue(currentManual)
        let countAfterCurrentManual = await refreshes.value()
        XCTAssertEqual(countAfterCurrentManual, 1)
        let currentStop = await gate.stop(generation: 6)
        XCTAssertTrue(currentStop)
        let delayedActivation = await gate.activate(generation: 5)
        XCTAssertFalse(delayedActivation)
    }
}

private actor RefreshSleeper {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var intervals: [TimeInterval] = []

    func sleep(_ seconds: TimeInterval) async {
        intervals.append(seconds)
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func releaseNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func releaseAll() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitUntilSleeping() async {
        while continuations.isEmpty {
            await Task.yield()
        }
    }

    func waitUntilRequested(_ expected: TimeInterval) async {
        while !intervals.contains(expected) {
            await Task.yield()
        }
    }

    func waitUntilRequestedWithin(_ expected: TimeInterval, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !intervals.contains(expected), Date() < deadline {
            await Task.yield()
        }
        return intervals.contains(expected)
    }

    func requestedIntervals() -> [TimeInterval] { intervals }
}

private actor RefreshCounter {
    private var count = 0

    func increment() { count += 1 }
    func value() -> Int { count }

    func waitForCount(_ expected: Int) async {
        while count < expected {
            await Task.yield()
        }
    }
}

private actor RefreshConcurrencyProbe {
    private var count = 0
    private var active = 0
    private var maximumConcurrent = 0

    func begin() -> Int {
        count += 1
        active += 1
        maximumConcurrent = max(maximumConcurrent, active)
        return count
    }

    func end() {
        active -= 1
    }

    func snapshot() -> (count: Int, maximumConcurrent: Int) {
        (count, maximumConcurrent)
    }

    func waitForCount(_ expected: Int, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while count < expected, Date() < deadline {
            await Task.yield()
        }
        return count >= expected
    }
}

private actor RefreshGate {
    private var blocked = true

    func waitIfBlocked() async {
        while blocked {
            await Task.yield()
        }
    }

    func release() { blocked = false }
}
