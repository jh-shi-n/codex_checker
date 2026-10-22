// 목적: 초기화 갱신 전체 과정의 로그 연결과 결과 구분 검증
// 이용처: 메뉴·Ping·할당량·화면 결과의 통합 회귀 테스트
// 사용방법: swift test --filter DiagnosticLogContextTests
// 실행 예시: 실제 인증·프로세스 없이 주입 서비스로 작업 ID 확인
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// UI 작업과 분리된 조회에도 동일 요청 문맥을 유지하는지 검증
@MainActor
final class DiagnosticLogContextTests: XCTestCase {
    /// 메뉴·가짜 Ping·강제 조회·화면 결과의 작업 ID 연결 및 원본 계정 데이터 제외
    func testProbeAndDetachedQuotaRefreshShareOperationID() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = DiagnosticLogger(directory: root, osLogEnabled: false, timerEnabled: false)
        let config = AccountConfig(id: "C3", home: root.appendingPathComponent("account"), position: .right)
        let before = Date().addingTimeInterval(1_000)
        let after = before.addingTimeInterval(100)
        let suite = "DiagnosticLogContextTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = AccountStore(configs: [config], preferencesStore: PreferencesStore(userDefaults: defaults)) { config in
            AccountState(id: config.id, email: "private@example.com", primaryResetAt: after,
                         status: .normal, errorMessage: "private-error-with-account-path")
        }
        let service = UsageWindowProbeService(
            fileSystem: .init(metadata: { _ in .init(exists: true) }),
            executableLocator: CodexLocator(pathEnvironment: nil, candidatePaths: [URL(fileURLWithPath: "/usr/bin/true")]),
            processRunner: DiagnosticSuccessfulProbeRunner()
        )
        let store = UsageWindowProbeStore()
        let task = try XCTUnwrap(DiagnosticLogContext.$logger.withValue(logger) {
            store.start(for: AccountState(id: "C3", primaryResetAt: before, status: .normal)) { account in
                let result = await service.probe(config)
                let refresh = await accounts.refreshOutcome(accountID: account.id, forceFresh: true)
                return UsageWindowProbePresentationResult(
                    result: result, primaryResetBefore: before, primaryResetAfter: accounts.state(for: account.id)?.primaryResetAt,
                    quotaRefreshSucceeded: refresh.isSuccess
                )
            }
        })
        await task.value
        logger.flush()
        let rows = try readRows(root)
        let expected: Set<String> = ["probeRequested", "probeStarted", "probeFinished", "quotaRefreshStarted",
                                     "quotaRefreshFinished", "quotaResultApplied", "probeResultApplied"]
        XCTAssertEqual(Set(rows.compactMap { $0["event"] as? String }), expected)
        XCTAssertEqual(Set(rows.compactMap { $0["operationID"] as? String }).count, 1)
        XCTAssertEqual(rows.filter { $0["accountID"] as? String == "C3" }.count, rows.count)
        let serialized = String(decoding: try JSONSerialization.data(withJSONObject: rows), as: UTF8.self)
        XCTAssertFalse(serialized.contains("private"))
        let applied = try XCTUnwrap(rows.first { $0["event"] as? String == "probeResultApplied" })
        let fields = try XCTUnwrap(applied["fields"] as? [String: [String: Any]])
        XCTAssertEqual(fields["reason"]?["value"] as? String, "reset_times_changed")
        XCTAssertNotNil(fields["primaryResetBefore"])
        XCTAssertNotNil(fields["primaryResetAfter"])
    }

    /// 계정 세대가 달라진 응답을 화면 미반영으로 기록
    func testObsoleteProbeResultIsLoggedAsDiscarded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = DiagnosticLogger(directory: root, osLogEnabled: false, timerEnabled: false)
        let store = UsageWindowProbeStore()
        let task = try XCTUnwrap(DiagnosticLogContext.$logger.withValue(logger) {
            store.start(for: AccountState(id: "C3", status: .normal)) { account in
                UsageWindowProbePresentationResult(
                    result: .init(accountID: account.id, status: .success, startedAt: Date(), completedAt: Date()),
                    isCurrentAccount: false
                )
            }
        })
        await task.value
        logger.flush()
        let events = try readRows(root).compactMap { $0["event"] as? String }
        XCTAssertTrue(events.contains("probeResultDiscarded"))
        XCTAssertFalse(events.contains("probeResultApplied"))
    }

    /// 리셋권 사용·후속 한도 조회의 작업 연결 및 리셋권·재시도 키의 로그 제외
    func testResetCreditAndFollowupQuotaShareSafeOperationContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = DiagnosticLogger(directory: root, osLogEnabled: false, timerEnabled: false)
        let credit = RateLimitResetCredits.Credit(id: "private-credit-must-not-be-logged")
        let account = AccountState(id: "C3", email: "private@example.com",
                                   resetCredits: .init(availableCount: 1, credits: [credit]), status: .normal)
        let store = ResetCreditRedemptionStore()
        var attemptKey = ""
        let task = try XCTUnwrap(DiagnosticLogContext.$logger.withValue(logger) {
            store.start(credit: credit, account: account) { state, _, attempt in
                attemptKey = attempt
                DiagnosticLogContext.record(.quotaRefreshStarted, accountID: state.id)
                return .success(.reset)
            }
        })
        await task.value
        logger.flush()
        let rows = try readRows(root)
        XCTAssertEqual(Set(rows.compactMap { $0["event"] as? String }),
                       Set(["resetCreditRequested", "quotaRefreshStarted", "resetCreditFinished"]))
        XCTAssertEqual(Set(rows.compactMap { $0["operationID"] as? String }).count, 1)
        let serialized = String(decoding: try JSONSerialization.data(withJSONObject: rows), as: UTF8.self)
        XCTAssertFalse(serialized.contains(credit.id))
        XCTAssertFalse(serialized.contains(attemptKey))
        XCTAssertFalse(serialized.contains("private@example.com"))
        XCTAssertEqual(store.message(for: account), ResetCreditOutcome.reset.message)
    }

    /// 원문 전송 오류의 미저장 및 실패 로그의 분류 확인
    func testResetCreditFailureStoresCategoryWithoutRawError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = DiagnosticLogger(directory: root, osLogEnabled: false, timerEnabled: false)
        let credit = RateLimitResetCredits.Credit(id: "private-credit")
        let account = AccountState(id: "C3", resetCredits: .init(availableCount: 1, credits: [credit]), status: .normal)
        let store = ResetCreditRedemptionStore()
        let task = try XCTUnwrap(DiagnosticLogContext.$logger.withValue(logger) {
            store.start(credit: credit, account: account) { _, _, _ in
                .failure(.transport("private-secret-and-account-path"))
            }
        })
        await task.value
        logger.flush()
        let rows = try readRows(root)
        let finished = try XCTUnwrap(rows.first { $0["event"] as? String == "resetCreditFinished" })
        XCTAssertEqual(finished["level"] as? String, "error")
        let fields = try XCTUnwrap(finished["fields"] as? [String: [String: Any]])
        XCTAssertEqual(fields["failure"]?["value"] as? String, "transport")
        let serialized = String(decoding: try JSONSerialization.data(withJSONObject: rows), as: UTF8.self)
        XCTAssertFalse(serialized.contains("private"))
    }

    /// 관리 대상 JSONL만 구조화된 행 목록으로 로드
    private func readRows(_ directory: URL) throws -> [[String: Any]] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
            .flatMap { url in
                try Data(contentsOf: url).split(separator: 0x0A).map {
                    try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
                }
            }
    }
}

/// 실제 CLI 호출 없이 완료 이벤트를 반환하는 테스트 경계
private struct DiagnosticSuccessfulProbeRunner: UsageWindowProbeProcessRunning {
    /// 사용량과 정상 종료를 포함한 최소 JSONL 반환
    func run(command: UsageWindowProbeCommand, timeout: TimeInterval) async throws -> UsageWindowProbeProcessResult {
        UsageWindowProbeProcessResult(
            exitStatus: 0,
            stdout: Data("{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}\n".utf8)
        )
    }
}
