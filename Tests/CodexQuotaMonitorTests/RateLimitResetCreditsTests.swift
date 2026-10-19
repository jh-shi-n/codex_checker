// 목적: 리셋권 응답 파싱·소멸·사용 추정과 저장 호환성 검증
// 이용처: 잔여 개수 표시 및 알림 필터 회귀 검사
// 사용방법: swift test --filter RateLimitResetCreditsTests
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 일부 상세와 개수 전용 응답을 구분하는 리셋권 모델 검증
final class RateLimitResetCreditsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 상세 개수가 적어도 통합 개수 우선 및 Unix 소멸일 파싱 확인
    func testParsesAuthoritativeCountAndOptionalExpiration() {
        let parsed = RateLimitResetCredits.parse(.object([
            "availableCount": .number(3),
            "credits": .array([
                .object(["id": .string("a"), "status": .string("available"), "expiresAt": .number(1_800_000_000)]),
                .object(["id": .string("b"), "status": .string("available"), "expiresAt": .null]),
            ]),
        ]))
        XCTAssertEqual(parsed?.availableCount, 3)
        XCTAssertEqual(parsed?.credits?.first?.expiresAt, now)
        XCTAssertNil(parsed?.credits?.last?.expiresAt)
        XCTAssertEqual(parsed?.hasCompleteDetails, false)
    }

    /// 개수 전용·빈 상세·조회 불가·비정상 개수 구분 확인
    func testDistinguishesCountOnlyEmptyAndUnavailable() {
        let countOnly = RateLimitResetCredits.parse(.object(["availableCount": .number(2), "credits": .null]))
        XCTAssertEqual(countOnly?.availableCount, 2)
        XCTAssertNil(countOnly?.credits)
        let empty = RateLimitResetCredits.parse(.object(["availableCount": .number(0), "credits": .array([])]))
        XCTAssertEqual(empty?.credits, [])
        XCTAssertEqual(empty?.hasCompleteDetails, true)
        for value: CodexJSONValue? in [nil, .null, .object([:]),
            .object(["availableCount": .number(-1)]),
            .object(["availableCount": .number(1.5)])] {
            XCTAssertNil(RateLimitResetCredits.parse(value))
        }
    }

    /// 사용과 신규 지급이 동시에 발생해 개수가 같아도 미소멸 ID 소실 감지 확인
    func testDetectsUsageDespiteSimultaneousGrant() {
        let previous = credits([.init(id: "a", expiresAt: now.addingTimeInterval(60))])
        let current = credits([.init(id: "b", expiresAt: now.addingTimeInterval(120))])
        XCTAssertEqual(current.usageEvidence(comparedTo: previous, now: now), .used)
        XCTAssertEqual(credits([]).usageEvidence(comparedTo: previous, now: now), .used)
        XCTAssertEqual(previous.usageEvidence(comparedTo: previous, now: now), .notObserved)
    }

    /// 소멸일 도달과 일부 상세를 사용 여부 불명으로 분류하는 경계값 확인
    func testExpiryIsNotConsumptionAndPartialDetailsAreUnknown() {
        for expiration in [now.addingTimeInterval(-1), now] {
            let previous = credits([.init(id: "a", expiresAt: expiration)])
            XCTAssertEqual(credits([]).usageEvidence(comparedTo: previous, now: now), .unknown)
        }
        let partial = RateLimitResetCredits(availableCount: 2, credits: [.init(id: "a")])
        XCTAssertEqual(credits([]).usageEvidence(comparedTo: partial, now: now), .unknown)
        XCTAssertEqual(credits([]).usageEvidence(comparedTo: nil, now: now), .unknown)
        XCTAssertEqual(credits([]).usageEvidence(comparedTo: credits([]), now: now), .notObserved)
    }

    /// 신규 필드 왕복과 기존 스냅샷의 누락 필드 호환성 확인
    @MainActor
    func testAccountAndPersistedSnapshotRoundTrip() throws {
        let resetCredits = credits([.init(id: "a", expiresAt: now)])
        let state = AccountState(id: "C1", resetCredits: resetCredits, status: .normal)
        XCTAssertEqual(try JSONDecoder().decode(AccountState.self, from: JSONEncoder().encode(state)), state)
        let snapshot = PreferencesStore.QuotaSnapshot(usedPercent: 50, resetCredits: resetCredits)
        XCTAssertEqual(try JSONDecoder().decode(PreferencesStore.QuotaSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
        let oldSnapshot = try JSONDecoder().decode(PreferencesStore.QuotaSnapshot.self, from: Data("{\"usedPercent\":50}".utf8))
        XCTAssertNil(oldSnapshot.resetCredits)
    }

    /// 완전한 잔여 목록의 테스트 스냅샷 구성
    private func credits(_ rows: [RateLimitResetCredits.Credit]) -> RateLimitResetCredits {
        RateLimitResetCredits(availableCount: rows.count, credits: rows)
    }
}
