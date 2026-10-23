// 목적: 계정 전환 중 토큰 새로고침 지속·계정별 결과 격리 검증
// 이용처: 상세 화면 수명과 집계 작업 수명 분리 회귀 테스트
// 사용방법: swift test --filter TokenUsageRefreshStoreTests
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 실제 캐시 저장과 제어된 비동기 응답을 이용한 새로고침 검증
@MainActor
final class TokenUsageRefreshStoreTests: XCTestCase {
    /// 화면 대기 취소·다른 계정 갱신 이후에도 원래 집계의 완료와 재시작 복원 보장
    func testAccountSwitchAndCancelledWaiterPreserveBothAccountsOnDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let provider = RefreshStoreProvider(now: now)
        let homes = ["C1": directory.appendingPathComponent("first"), "C2": directory.appendingPathComponent("second")]
        let database = directory.appendingPathComponent("cache.sqlite")
        let history = directory.appendingPathComponent("history.sqlite")
        let cache = TokenUsageSnapshotCache(provider: provider, databaseURL: database,
            accountHomes: homes, now: { now }, historyDatabaseURL: history)
        let store = TokenUsageRefreshStore()
        let first = AccountState(id: "C1", status: .normal)
        let second = AccountState(id: "C2", status: .normal)
        let runner: TokenUsageSnapshotRefresh = { account in
            await cache.refresh(accountID: account.id, home: homes[account.id]!)
        }
        let firstTask = try XCTUnwrap(store.start(for: first, runner: runner))
        await provider.gate.waitUntilStarted()
        let screenWaiter = Task { await firstTask.value }
        screenWaiter.cancel()
        XCTAssertTrue(store.isRunning(for: first))
        XCTAssertNil(store.start(for: first, runner: runner))
        let secondTask = try XCTUnwrap(store.start(for: second, runner: runner))
        await secondTask.value
        XCTAssertEqual(store.result(for: second)?.today.inputTokens, 222)
        XCTAssertFalse(store.isRunning(for: second))
        XCTAssertTrue(store.isRunning(for: first))
        XCTAssertNil(store.result(for: first))
        await provider.gate.release()
        await screenWaiter.value
        XCTAssertFalse(store.isRunning(for: first))
        XCTAssertEqual(store.result(for: first)?.today.inputTokens, 111)
        let restarted = TokenUsageSnapshotCache(databaseURL: database, accountHomes: homes,
            now: { now }, historyDatabaseURL: history)
        let restoredFirst = await restarted.cachedSnapshot(for: "C1")
        let restoredSecond = await restarted.cachedSnapshot(for: "C2")
        XCTAssertEqual(restoredFirst?.today.inputTokens, 111)
        XCTAssertEqual(restoredSecond?.today.inputTokens, 222)
    }

    /// 경로 교체 전 작업의 늦은 완료가 새 계정 결과·실행 상태에 섞이지 않는지 검증
    func testAccountGenerationSeparatesRunningWorkAndResults() async throws {
        let store = TokenUsageRefreshStore()
        let old = AccountState(id: "C1", status: .normal)
        var current = old
        current.configurationGeneration += 1
        let gate = RefreshStoreGate()
        let oldTask = try XCTUnwrap(store.start(for: old) { _ in
            await gate.wait()
            return self.snapshot(11)
        })
        await gate.waitUntilStarted()
        XCTAssertFalse(store.isRunning(for: current))
        XCTAssertNil(store.result(for: current))
        let currentTask = try XCTUnwrap(store.start(for: current) { _ in self.snapshot(22) })
        await currentTask.value
        await gate.release()
        await oldTask.value
        XCTAssertEqual(store.result(for: current)?.today.inputTokens, 22)
        XCTAssertEqual(store.result(for: old)?.today.inputTokens, 11)
    }

    /// 실패 이후 실행 상태 해제·다른 계정 오류 격리·동일 계정 재시도 검증
    func testFailureCanBeRetriedWithoutLeakingToAnotherAccount() async throws {
        let store = TokenUsageRefreshStore()
        let first = AccountState(id: "C1", status: .normal)
        let second = AccountState(id: "C2", status: .normal)
        let failure = try XCTUnwrap(store.start(for: first) { _ in
            TokenUsageSnapshot(generatedAt: Date(), dailyPoints: [], availability: .unavailable, error: .rolloutReadFailed)
        })
        await failure.value
        XCTAssertFalse(store.isRunning(for: first))
        XCTAssertEqual(store.result(for: first)?.error, .rolloutReadFailed)
        XCTAssertNil(store.result(for: second))
        let retry = try XCTUnwrap(store.start(for: first) { _ in self.snapshot(33) })
        await retry.value
        XCTAssertEqual(store.result(for: first)?.today.inputTokens, 33)
        XCTAssertNil(store.result(for: first)?.error)
    }

    /// 앱 종료 취소 후 이전 응답이 새 요청의 진행 상태와 결과를 지우지 않는지 검증
    func testShutdownDiscardsLateCompletionAndPreservesRestartedWork() async throws {
        let store = TokenUsageRefreshStore()
        let account = AccountState(id: "C1", status: .normal)
        let oldGate = RefreshStoreGate()
        let old = try XCTUnwrap(store.start(for: account) { _ in
            await oldGate.wait()
            XCTAssertTrue(Task.isCancelled)
            return self.snapshot(1)
        })
        await oldGate.waitUntilStarted()
        store.cancelAll()
        XCTAssertFalse(store.isRunning(for: account))
        let newGate = RefreshStoreGate()
        let current = try XCTUnwrap(store.start(for: account) { _ in
            await newGate.wait()
            return self.snapshot(2)
        })
        await newGate.waitUntilStarted()
        await oldGate.release()
        await old.value
        XCTAssertTrue(store.isRunning(for: account))
        XCTAssertNil(store.result(for: account))
        await newGate.release()
        await current.value
        XCTAssertFalse(store.isRunning(for: account))
        XCTAssertEqual(store.result(for: account)?.today.inputTokens, 2)
    }

    /// 현재 날짜의 구분 가능한 입력 토큰 집계 생성
    private func snapshot(_ input: Int64) -> TokenUsageSnapshot {
        let now = Date()
        return TokenUsageAggregator().aggregate(dailyPoints: [TokenUsageDailyPoint(
            date: now, inputTokens: input, outputTokens: 0, cachedInputTokens: nil, sessionCount: 1)], generatedAt: now)
    }
}

/// 첫 계정의 원본 수집만 보류하는 캐시 통합 검증 대역
private struct RefreshStoreProvider: TokenUsageProvider {
    let now: Date
    let gate = RefreshStoreGate()

    /// 실제 수집과 동일하게 취소 여부를 확인하고 계정별 다른 사용량 반환
    func snapshot(home: URL) async -> TokenUsageSnapshot {
        if home.lastPathComponent == "first" { await gate.wait() }
        XCTAssertFalse(Task.isCancelled)
        return TokenUsageAggregator().aggregate(dailyPoints: [TokenUsageDailyPoint(date: now,
            inputTokens: home.lastPathComponent == "first" ? 111 : 222,
            outputTokens: 0, cachedInputTokens: nil, sessionCount: 1)], generatedAt: now)
    }
}

/// 임의 시간 지연 없이 요청 시작·완료 순서를 고정하는 동기화 대역
private actor RefreshStoreGate {
    private var pending: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    /// 외부 해제까지 작업 응답 보류
    func wait() async {
        await withCheckedContinuation {
            pending = $0
            started?.resume()
            started = nil
        }
    }

    /// 집계 요청 진입 이후에만 계정 전환 진행
    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    /// 보류 중 응답 완료 허용
    func release() { pending?.resume(); pending = nil }
}
