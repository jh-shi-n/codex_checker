// 목적: 최초 등록 전 실행과 등록 후 계정 삭제·숨김 상태의 구분 검증
// 이용처: 실행 이력 JSON과 메뉴 막대 안내의 회귀 방지
// 사용방법: swift test --filter InstallationHistoryTests
import Foundation
import SwiftUI
import XCTest
@testable import CodexQuotaMonitorKit

/// 격리된 임시 파일을 이용한 실행 이력·안내 정책 검증
@MainActor
final class InstallationHistoryTests: XCTestCase {
    /// 실제 첫 실행 시 이력 파일 생성과 미등록 상태 보존 검증
    func testFirstLaunchCreatesJSONAndRequiresInitialRegistration() throws {
        XCTAssertEqual(InstallationHistoryStore.defaultFileURL.lastPathComponent, "config.json")
        let file = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let store = InstallationHistoryStore(fileURL: file, now: date)
        XCTAssertTrue(store.isFirstLaunch)
        XCTAssertTrue(store.requiresAccountSetup)
        XCTAssertEqual(store.history.launchCount, 1)
        XCTAssertEqual(store.history.firstLaunchedAt, date)
        XCTAssertNil(store.storageError)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let installation = try XCTUnwrap(json["installation"] as? [String: Any])
        XCTAssertEqual(installation["hasRegisteredAccount"] as? Bool, false)
        XCTAssertEqual(Set(json.keys), ["schemaVersion", "installation"])
    }

    /// 첫 계정 미등록 상태로 재실행 시 최초 연결 안내 유지 검증
    func testRelaunchBeforeRegistrationKeepsGuideAndUpdatesHistory() {
        let file = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let firstDate = Date(timeIntervalSince1970: 1_800_000_000)
        _ = InstallationHistoryStore(fileURL: file, now: firstDate)
        let nextDate = firstDate.addingTimeInterval(60)
        let next = InstallationHistoryStore(fileURL: file, now: nextDate)
        XCTAssertFalse(next.isFirstLaunch)
        XCTAssertTrue(next.requiresAccountSetup)
        XCTAssertEqual(next.history.launchCount, 2)
        XCTAssertEqual(next.history.firstLaunchedAt, firstDate)
        XCTAssertEqual(next.history.lastLaunchedAt, nextDate)
    }

    /// 등록 완료 이후 모든 계정을 삭제한 상태로 재실행해도 연결 안내 재진입 방지 검증
    func testRegistrationSurvivesDeletionOfAllAccountsAndRelaunch() {
        let file = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = InstallationHistoryStore(fileURL: file)
        XCTAssertTrue(store.markAccountRegistered())
        XCTAssertFalse(store.requiresAccountSetup)
        let next = InstallationHistoryStore(fileURL: file, hasExistingAccount: false)
        XCTAssertFalse(next.requiresAccountSetup)
        XCTAssertTrue(next.history.hasRegisteredAccount)
        let copy = EmptyAccountsPresentation(hasRegisteredAccounts: false)
        XCTAssertEqual(copy.message, "현재 등록된 계정이 없습니다.")
    }

    /// 실행 이력 파일이 없는 기존 사용자의 계정 등록 상태 이관 검증
    func testExistingAccountMigratesToCompletedSetup() {
        let file = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = InstallationHistoryStore(fileURL: file, hasExistingAccount: true)
        XCTAssertFalse(store.requiresAccountSetup)
        XCTAssertTrue(store.history.hasRegisteredAccount)
        let next = InstallationHistoryStore(fileURL: file, hasExistingAccount: false)
        XCTAssertFalse(next.requiresAccountSetup)
    }

    /// 설정에서 등록·전체 숨김·전체 삭제 시 초기화 완료 이력과 안내의 분리 검증
    func testHiddenAccountsAndRemovedAccountsHaveDifferentMessages() {
        let file = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let suite = "InstallationHistoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(userDefaults: defaults)
        let history = InstallationHistoryStore(fileURL: file)
        preferences.updateAccountPaths([file.deletingLastPathComponent().path, "", "", ""])
        XCTAssertTrue(preferences.hasRegisteredAccounts)
        XCTAssertTrue(history.markAccountRegistered())
        preferences.updateEnabledAccountIDs([])
        XCTAssertFalse(history.requiresAccountSetup)
        XCTAssertTrue(preferences.visibleAccounts([AccountState(id: "C1", status: .normal)]).isEmpty)
        let hidden = EmptyAccountsPresentation(hasRegisteredAccounts: preferences.hasRegisteredAccounts)
        XCTAssertEqual(hidden.message, "모든 계정이 비활성화되어 있습니다.")
        preferences.updateAccountPaths(["", "", "", ""])
        XCTAssertFalse(preferences.hasRegisteredAccounts)
        XCTAssertFalse(history.requiresAccountSetup)
        let removed = EmptyAccountsPresentation(hasRegisteredAccounts: preferences.hasRegisteredAccounts)
        XCTAssertEqual(removed.message, "현재 등록된 계정이 없습니다.")
        XCTAssertNotEqual(hidden.detail, removed.detail)
    }

    /// 손상·미지원 버전의 파일을 초기 실행으로 오인하거나 덮어쓰지 않는지 검증
    func testUnreadableHistoryPreservesOriginalFileAndReportsError() throws {
        for data in [Data("broken json".utf8), Data(#"{"schemaVersion":999,"firstLaunchedAt":"2026-01-01T00:00:00Z","lastLaunchedAt":"2026-01-01T00:00:00Z","launchCount":1,"hasRegisteredAccount":true}"#.utf8)] {
            let file = temporaryFileURL()
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
            let history = InstallationHistoryStore(fileURL: file)
            XCTAssertFalse(history.isFirstLaunch)
            XCTAssertNotNil(history.storageError)
            XCTAssertFalse(history.markAccountRegistered())
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }

    /// 저장 경로가 파일에 막힌 경우 저장 실패의 명시적 반환 검증
    func testWriteFailureIsReported() throws {
        let file = temporaryFileURL()
        let parent = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: parent) }
        try Data("blocked".utf8).write(to: parent)
        let history = InstallationHistoryStore(fileURL: file)
        XCTAssertNotNil(history.storageError)
        XCTAssertFalse(history.markAccountRegistered())
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// 미등록·전체 비활성화 안내의 실제 렌더 높이가 팝오버 내부에 들어오는지 검증
    func testEmptyAccountMessagesFitPopover() throws {
        for registered in [false, true] {
            let renderer = ImageRenderer(content: EmptyAccountsView(hasRegisteredAccounts: registered, onOpenSettings: {}))
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(image.width, Int(EmptyAccountsView.contentSize.width))
            XCTAssertLessThanOrEqual(image.height, Int(EmptyAccountsView.contentSize.height))
        }
    }

    /// 이전 파일명에서 등록 완료·실행 이력을 잃지 않고 새 파일 생성 검증
    func testLegacyInstallationJSONMigratesToConfigJSON() throws {
        let file = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let legacy = file.deletingLastPathComponent().appendingPathComponent("installation.json")
        let firstDate = Date(timeIntervalSince1970: 1_800_000_000)
        let old = InstallationHistoryStore(fileURL: legacy, now: firstDate)
        XCTAssertTrue(old.markAccountRegistered())
        let current = InstallationHistoryStore(fileURL: file, now: firstDate.addingTimeInterval(60))
        XCTAssertFalse(current.isFirstLaunch)
        XCTAssertFalse(current.requiresAccountSetup)
        XCTAssertEqual(current.history.firstLaunchedAt, firstDate)
        XCTAssertEqual(current.history.launchCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(current.storageError)
        let next = InstallationHistoryStore(fileURL: file)
        XCTAssertEqual(next.history.launchCount, 3)
        XCTAssertFalse(next.requiresAccountSetup)
    }

    /// 새 설정 파일과 이전 파일이 공존할 때 최신 파일을 우선하는지 검증
    func testConfigJSONTakesPrecedenceOverLegacyHistory() {
        let file = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let legacy = file.deletingLastPathComponent().appendingPathComponent("installation.json")
        let old = InstallationHistoryStore(fileURL: legacy)
        XCTAssertTrue(old.markAccountRegistered())
        let current = InstallationHistoryStore(fileURL: file)
        XCTAssertEqual(current.history.launchCount, 2)
        let next = InstallationHistoryStore(fileURL: file)
        XCTAssertEqual(next.history.launchCount, 3)
    }

    /// 실제 사용자 지원 폴더와 분리된 JSON 파일 경로 생성
    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("InstallationHistoryTests-\(UUID().uuidString)")
            .appendingPathComponent("config.json")
    }
}
