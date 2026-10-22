// 목적: 리셋권 중복 사용·응답 유실 재시도·만료 차단 검증
// 이용처: 리셋권 사용 상태 회귀 테스트
// 사용방법: swift test --filter ResetCreditRedemptionTests
// 실행 예시: swift test --filter ResetCreditRedemptionTests
import XCTest
@testable import CodexQuotaMonitorKit

/// 실제 리셋권 소모 없이 사용 요청 수명 검증
@MainActor
final class ResetCreditRedemptionTests: XCTestCase {
    /// 승인 전 요청 부재·연속 클릭 차단·사용 완료 재실행 차단 검증
    func testSingleRequestAndSuccessfulCreditCannotBeReused() async {
        let store = ResetCreditRedemptionStore()
        let credit = RateLimitResetCredits.Credit(id: "a")
        let account = makeAccount(credit)
        var calls = 0
        let runner: ResetCreditRunner = { _, _, _ in
            calls += 1
            return .success(.reset)
        }
        XCTAssertEqual(calls, 0)
        let task = store.start(credit: credit, account: account, runner: runner)
        XCTAssertTrue(store.isRunning(for: account))
        XCTAssertNil(store.start(credit: credit, account: account, runner: runner))
        await task?.value
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(store.isRunning(for: account))
        XCTAssertNil(store.start(credit: credit, account: account, runner: runner))
        XCTAssertEqual(store.message(for: account), ResetCreditOutcome.reset.message)
    }

    /// 응답 유실 후 같은 시도 키 재사용 및 서버 중복 처리 결과 반영 검증
    func testUncertainRetryReusesKeyAndConfigurationIsIsolated() async {
        let store = ResetCreditRedemptionStore()
        let credit = RateLimitResetCredits.Credit(id: "a")
        let account = makeAccount(credit)
        var keys: [String] = []
        let runner: ResetCreditRunner = { _, id, key in
            XCTAssertEqual(id, "a")
            keys.append(key)
            return keys.count == 1 ? .failure(.timeout) : .success(.alreadyRedeemed)
        }
        await store.start(credit: credit, account: account, runner: runner)?.value
        await store.start(credit: credit, account: account, runner: runner)?.value
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys.first, keys.last)
        XCTAssertFalse(store.canUse(credit, for: account))
        var reconfigured = account
        reconfigured.configurationGeneration += 1
        XCTAssertTrue(store.canUse(credit, for: reconfigured))
        XCTAssertNil(store.message(for: reconfigured))
    }

    /// 소멸·가용 상태 변경·목록에서 삭제된 리셋권 사용 차단 검증
    func testExpiredUnavailableAndMissingCreditAreBlocked() {
        let store = ResetCreditRedemptionStore()
        let expired = RateLimitResetCredits.Credit(id: "a", expiresAt: .distantPast)
        XCTAssertFalse(store.canUse(expired, for: makeAccount(expired)))
        let used = RateLimitResetCredits.Credit(id: "a", status: "used")
        XCTAssertFalse(store.canUse(used, for: makeAccount(used)))
        let credit = RateLimitResetCredits.Credit(id: "a")
        XCTAssertFalse(store.canUse(credit, for: makeAccount(.init(id: "b"))))
        var empty = makeAccount(credit)
        empty.resetCredits = .init(availableCount: 0)
        XCTAssertFalse(store.canUse(credit, for: empty))
    }

    /// 사용 가능한 단일 리셋권 계정 구성
    private func makeAccount(_ credit: RateLimitResetCredits.Credit) -> AccountState {
        AccountState(id: "C1", resetCredits: .init(availableCount: 1, credits: [credit]), status: .normal)
    }
}
