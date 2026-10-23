// 목적: 서버 사용량 검증·미제공 구분·계정 격리와 실패 보존 검증
// 이용처: 서버 통계의 로컬 집계 오염 방지 회귀 테스트
// 사용방법: swift test --filter AccountTokenUsageTests
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

@MainActor
final class AccountTokenUsageTests: XCTestCase {
    /// null·미제공·실제 0·빈 날짜 목록의 구분 검증
    func testNullableFieldsAndZero() throws {
        let absent = try AccountTokenUsage(result: .object(["summary": .object([:])]))
        XCTAssertNil(absent.lifetimeTokens)
        XCTAssertNil(absent.days)
        let zero = try AccountTokenUsage(result: .object(["summary": .object(["lifetimeTokens": .number(0)]), "dailyUsageBuckets": .array([])]))
        XCTAssertEqual(zero.lifetimeTokens, 0)
        XCTAssertEqual(zero.days, [])
        let null = try AccountTokenUsage(result: .object(["summary": .object(["lifetimeTokens": .null]), "dailyUsageBuckets": .null]))
        XCTAssertNil(null.lifetimeTokens)
        XCTAssertNil(null.days)
    }

    /// 날짜 자동 보정·Boolean·소수·정밀도 손실·중복 합산의 거절 검증
    func testMalformedDataNeverBecomesZeroOrPartialSuccess() throws {
        for count in [CodexJSONValue.bool(true), .number(-1), .number(1.5), .number(.infinity), .number(9_007_199_254_740_992)] {
            XCTAssertThrowsError(try AccountTokenUsage(result: .object(["summary": .object(["lifetimeTokens": count])])))
        }
        for date in ["2026-02-30", "2026-13-01", "2026-1-01", "0000-01-01", "2026-01-01\n"] {
            XCTAssertThrowsError(try AccountTokenUsage(result: payload(date: date)))
        }
        XCTAssertNoThrow(try AccountTokenUsage(result: payload(date: "2024-02-29")))
        let day: CodexJSONValue = .object(["startDate": .string("2026-01-01"), "tokens": .number(1)])
        XCTAssertThrowsError(try AccountTokenUsage(result: .object(["summary": .object([:]), "dailyUsageBuckets": .array([day, day])])))
    }

    /// 재진입 캐시·실패 후 정상값 유지·세대 및 로그인 계정 격리 검증
    func testStorePreservesSuccessAndSeparatesIdentity() async throws {
        let store = AccountTokenUsageStore()
        let account = AccountState(id: "C1", email: "one@example.test", status: .normal)
        let snapshot = try AccountTokenUsage(result: payload(date: "2026-10-23"))
        var calls = 0
        store.loader = { _ in calls += 1; return .success(snapshot) }
        await store.refresh(for: account)?.value
        XCTAssertNil(store.refresh(for: account))
        XCTAssertEqual(calls, 1)
        store.loader = { _ in .failure(.timeout) }
        await store.refresh(for: account, force: true)?.value
        XCTAssertEqual(store.snapshot(for: account), snapshot)
        XCTAssertTrue(store.hasFailed(for: account))
        var changed = account
        changed.configurationGeneration += 1
        XCTAssertNil(store.snapshot(for: changed))
        var loginChanged = account
        loginChanged.email = "two@example.test"
        XCTAssertNil(store.snapshot(for: loginChanged))
        store.invalidateAll()
        XCTAssertNil(store.snapshot(for: account))
    }

    /// 한 슬롯의 설정 변경이 다른 계정의 정상 서버 결과를 지우지 않는지 검증
    func testSlotInvalidationPreservesOtherAccounts() async throws {
        let store = AccountTokenUsageStore()
        let first = AccountState(id: "C1", status: .normal)
        let second = AccountState(id: "C2", status: .normal)
        let snapshot = try AccountTokenUsage(result: payload(date: "2026-10-23"))
        store.loader = { _ in .success(snapshot) }
        await store.refresh(for: first)?.value
        await store.refresh(for: second)?.value
        store.invalidate(accountID: first.id)
        XCTAssertNil(store.snapshot(for: first))
        XCTAssertEqual(store.snapshot(for: second), snapshot)
    }

    /// 취소를 따르지 않는 이전 응답도 새 요청 결과를 덮어쓰지 않는지 검증
    func testInvalidationRejectsLateResponse() async throws {
        let store = AccountTokenUsageStore()
        let account = AccountState(id: "C1", status: .normal)
        let old = try AccountTokenUsage(result: payload(date: "2026-10-22"))
        let current = try AccountTokenUsage(result: payload(date: "2026-10-23"))
        let gate = UsageResponseGate()
        store.loader = { _ in await gate.wait(); return .success(old) }
        let first = try XCTUnwrap(store.refresh(for: account))
        await gate.waitUntilStarted()
        XCTAssertNil(store.refresh(for: account, force: true))
        store.invalidate(accountID: account.id)
        store.loader = { _ in .success(current) }
        await store.refresh(for: account)?.value
        await gate.release()
        await first.value
        XCTAssertEqual(store.snapshot(for: account), current)
        XCTAssertFalse(store.isLoading(for: account))
    }

    /// 날짜가 있는 최소 서버 응답 구성
    private func payload(date: String) -> CodexJSONValue {
        .object(["summary": .object([:]), "dailyUsageBuckets": .array([
            .object(["startDate": .string(date), "tokens": .number(10)])
        ])])
    }
}

/// 응답 완료 시점을 제어하는 취소 비협조형 서버 대역
private actor UsageResponseGate {
    private var started = false
    private var pending: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    /// 테스트의 명시적 해제까지 응답 대기
    func wait() async {
        started = true
        observers.forEach { $0.resume() }
        observers.removeAll()
        await withCheckedContinuation { pending = $0 }
    }

    /// 서버 요청 진입 시점 대기
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { observers.append($0) }
    }

    /// 보관한 이전 응답 완료
    func release() {
        pending?.resume()
        pending = nil
    }
}
