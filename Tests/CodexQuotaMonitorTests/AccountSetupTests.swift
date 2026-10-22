// 목적: 초기 연결의 검증·취소·등록 조건과 빈 계정 처리 검증
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

@MainActor
final class AccountSetupTests: XCTestCase {
    /// 존재하지 않는 경로의 네트워크 조회·등록 방지 검증
    func testInvalidPathNeverChecksOrRegisters() async {
        let model = AccountSetupModel(checker: { _ in
            XCTFail("Invalid path must not reach quota service")
            return AccountState(id: "C1", status: .normal)
        })
        model.path = "/missing-account-\(UUID().uuidString)"
        await model.checkConnection()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertNil(model.registrationPath())
    }

    /// 정규화된 성공 경로의 등록 허용과 입력 변경 시 확인 무효화 검증
    func testSuccessfulConnectionRequiresUnchangedPath() async {
        let model = AccountSetupModel(validator: validValidator(), checker: { config in
            XCTAssertEqual(config.home.path, "/fixture/.codex")
            return AccountState(id: config.id, email: "demo@example.com", status: .normal)
        })
        model.path = " ~/.codex "
        await model.checkConnection()
        XCTAssertEqual(model.phase, .connected)
        XCTAssertEqual(model.registrationPath(), "/fixture/.codex")
        model.path = "/fixture/other"
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.registrationPath())
    }

    /// 조회 실패 종류별 안내와 등록 금지 검증
    func testFailedChecksNeverEnableRegistration() async {
        for status: AccountStatus in [.loginRequired, .codexNotFound, .timeout, .error] {
            let model = AccountSetupModel(validator: validValidator(), checker: { config in
                AccountState(id: config.id, status: status)
            })
            model.path = "/fixture/account"
            await model.checkConnection()
            XCTAssertEqual(model.phase, .failed)
            XCTAssertNotNil(model.message)
            XCTAssertNil(model.registrationPath())
        }
    }

    /// 경로 변경·창 닫기 이후 늦은 조회 결과 무시 검증
    func testCancelledCheckCannotRestoreSuccess() async {
        for editPath in [false, true] {
            let gate = SetupCheckGate()
            let model = AccountSetupModel(validator: validValidator(), checker: { config in
                await gate.wait()
                return AccountState(id: config.id, status: .normal)
            })
            model.path = "/fixture/account"
            let check = Task { await model.checkConnection() }
            await gate.waitUntilStarted()
            if editPath { model.path = "/fixture/other" } else { model.cancelCheck() }
            await gate.release()
            await check.value
            XCTAssertEqual(model.phase, .idle)
            XCTAssertNil(model.registrationPath())
        }
    }

    /// 등록 직전 사라진 폴더의 저장 차단 검증
    func testRemovedDirectoryCannotBeRegistered() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AccountSetupModel(checker: { AccountState(id: $0.id, status: .normal) })
        model.path = directory.path
        await model.checkConnection()
        XCTAssertTrue(model.canFinish)
        try FileManager.default.removeItem(at: directory)
        XCTAssertNil(model.registrationPath())
        XCTAssertEqual(model.phase, .failed)
    }

    /// 빈 시작 시 조회·표시 제외 및 한 계정 등록·마지막 삭제 조건 검증
    func testEmptyStartAndSingleAccountPersistence() async {
        let suite = "AccountSetupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(userDefaults: defaults)
        XCTAssertFalse(preferences.hasRegisteredAccounts)
        let store = AccountStore(configs: AccountConfig.accounts(for: preferences.accountPaths)) { config in
            XCTFail("Unconfigured account must not refresh")
            return AccountState(id: config.id, status: .normal)
        }
        await store.refreshAll()
        XCTAssertTrue(preferences.visibleAccounts(store.states).isEmpty)
        let path = FileManager.default.temporaryDirectory.path
        preferences.updateAccountPaths([path, "", "", ""])
        XCTAssertTrue(preferences.hasRegisteredAccounts)
        let reloaded = PreferencesStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.accountPaths, [path, "", "", ""])
        XCTAssertTrue(reloaded.hasRegisteredAccounts)
        XCTAssertEqual(preferences.visibleAccounts([
            AccountState(id: "C1", status: .normal), AccountState(id: "C2", status: .notConfigured)
        ]).map(\.id), ["C1"])
        preferences.updateAccountPaths(["", "", "", ""])
        XCTAssertFalse(preferences.hasRegisteredAccounts)
    }

    /// 실제 인증 파일 접근 없는 폴더 검증 대역 생성
    private func validValidator() -> AccountPathValidator {
        AccountPathValidator(homeDirectory: URL(fileURLWithPath: "/fixture"), fileSystem: .init { _ in
            AccountPathFileMetadata(exists: true, isDirectory: true, isReadable: true)
        })
    }
}

/// 취소 이후 결과 도착 순서를 제어하는 연결 확인 대역
private actor SetupCheckGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var didStart = false

    /// 조회 시작 알림 후 외부 해제까지 대기
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            didStart = true
            started?.resume()
            started = nil
        }
    }

    /// 조회 시작까지 테스트 동기화
    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { started = $0 }
    }

    /// 취소된 작업의 늦은 응답 전달
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
