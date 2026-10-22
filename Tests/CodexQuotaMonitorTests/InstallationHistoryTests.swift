// 목적: 최초 등록의 원자적 반영과 등록 완료 이력·안내 상태의 구분 검증
// 이용처: 최초 연결·계정 재등록·전체 삭제의 회귀 테스트
// 사용방법: 최종 통합 검증 시 InstallationHistoryTests 실행
// 실행 예시: swift test --filter InstallationHistoryTests
import Foundation
import SwiftUI
import XCTest
@testable import CodexQuotaMonitorKit

/// 실행 횟수 저장 없이 설정 묶음에 보존되는 최초 등록 이력 검증
@MainActor
final class InstallationHistoryTests: XCTestCase {
    /// 미등록 재실행 시 등록일 생성과 JSON 실행 이력 쓰기 방지 검증
    func testUnregisteredRelaunchPreservesEmptyRegistrationHistory() throws {
        try withFixture { defaults, root, database in
            let file = AppConfigurationFile(fileURL: root.appendingPathComponent("config.json"))
            let first = PreferencesStore(userDefaults: defaults, configurationFile: file, quotaDatabaseURL: database)
            let next = PreferencesStore(userDefaults: defaults, configurationFile: file, quotaDatabaseURL: database)
            XCTAssertFalse(first.hasRegisteredAccount)
            XCTAssertFalse(next.hasRegisteredAccount)
            XCTAssertNil(first.firstAccountRegisteredAt)
            XCTAssertNil(next.firstAccountRegisteredAt)
            XCTAssertFalse(next.hasRegisteredAccounts)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.fileURL.path))
            let object = try bundleObject(defaults)
            XCTAssertEqual(object["hasRegisteredAccount"] as? Bool, false)
            XCTAssertNil(object["firstAccountRegisteredAt"])
            XCTAssertNil(object["launchCount"])
            XCTAssertNil(object["firstLaunchedAt"])
            XCTAssertNil(object["lastLaunchedAt"])
        }
    }

    /// 경로·활성 ID·최초 등록일의 동일 묶음 반영과 인스턴스 복원 검증
    func testRegistrationCommitsPathsVisibilityAndFirstDateTogether() throws {
        try withFixture { defaults, root, database in
            let date = Date(timeIntervalSince1970: 1_800_000_000)
            let store = PreferencesStore(userDefaults: defaults, homeDirectory: root, quotaDatabaseURL: database)
            XCTAssertTrue(store.registerAccountPaths([" ~ ", "", "", ""], enabledIDs: [" c1 ", "C1", "unknown"], now: date))
            let object = try bundleObject(defaults)
            let settings = try XCTUnwrap(object["settings"] as? [String: Any])
            XCTAssertEqual(settings["accountPaths"] as? [String], [root.path, "", "", ""])
            XCTAssertEqual(settings["enabledAccountIDs"] as? [String], ["C1"])
            XCTAssertEqual(object["hasRegisteredAccount"] as? Bool, true)
            XCTAssertEqual(object["firstAccountRegisteredAt"] as? Double, date.timeIntervalSinceReferenceDate)
            let restored = PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database)
            XCTAssertEqual(restored.accountPaths, [root.path, "", "", ""])
            XCTAssertEqual(restored.enabledAccountIDs, ["C1"])
            XCTAssertTrue(restored.hasRegisteredAccount)
            XCTAssertEqual(restored.firstAccountRegisteredAt, date)
            XCTAssertNil(restored.persistenceError)
        }
    }

    /// 잘못된 입력·슬롯 수·시각으로 인한 부분 등록과 활성 ID 변경 방지 검증
    func testRejectedRegistrationLeavesPathsVisibilityHistoryAndBundleUnchanged() throws {
        try withFixture { defaults, root, database in
            let store = PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database)
            let initial = try XCTUnwrap(defaults.data(forKey: PreferencesStore.Keys.settingsBundle))
            let attempts: [([String], Date)] = [
                (["", "", "", ""], Date()),
                ([root.path], Date()),
                ([root.path, root.appendingPathComponent("missing").path, "", ""], Date()),
                ([root.path, "", "", ""], Date(timeIntervalSince1970: .nan)),
                ([root.path, "", "", ""], Date(timeIntervalSince1970: .infinity)),
            ]
            for (paths, date) in attempts {
                XCTAssertFalse(store.registerAccountPaths(paths, enabledIDs: [], now: date))
                XCTAssertEqual(store.accountPaths, ["", "", "", ""])
                XCTAssertEqual(store.enabledAccountIDs, PreferencesStore.defaultEnabledAccountIDs)
                XCTAssertFalse(store.hasRegisteredAccount)
                XCTAssertNil(store.firstAccountRegisteredAt)
                XCTAssertEqual(defaults.data(forKey: PreferencesStore.Keys.settingsBundle), initial)
            }
            let next = PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database)
            XCTAssertFalse(next.hasRegisteredAccount)
            XCTAssertNil(next.firstAccountRegisteredAt)
        }
    }

    /// 재등록·설정 변경·전체 숨김·전체 삭제 이후 최초 등록일 유지 검증
    func testFirstRegistrationDateSurvivesReregistrationAndRemovalOfAllAccounts() throws {
        try withFixture { defaults, root, database in
            let store = PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database)
            let firstDate = Date(timeIntervalSince1970: 1_800_000_000)
            XCTAssertTrue(store.registerAccountPaths([root.path, "", "", ""], enabledIDs: ["C1"], now: firstDate))
            XCTAssertTrue(store.registerAccountPaths([root.path, "", "", ""], enabledIDs: [], now: firstDate.addingTimeInterval(60)))
            XCTAssertTrue(store.hasRegisteredAccounts)
            XCTAssertTrue(store.visibleAccounts([AccountState(id: "C1", status: .normal)]).isEmpty)
            XCTAssertEqual(store.firstAccountRegisteredAt, firstDate)
            let hidden = EmptyAccountsPresentation(hasRegisteredAccounts: store.hasRegisteredAccounts)
            XCTAssertEqual(hidden.message, "모든 계정이 비활성화되어 있습니다.")
            store.updateRefreshInterval(minutes: 17)
            XCTAssertTrue(store.updateAccountPaths(["", "", "", ""]))
            let next = PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database)
            XCTAssertFalse(next.hasRegisteredAccounts)
            XCTAssertTrue(next.hasRegisteredAccount)
            XCTAssertEqual(next.firstAccountRegisteredAt, firstDate)
            XCTAssertEqual(next.refreshIntervalMinutes, 17)
            let removed = EmptyAccountsPresentation(hasRegisteredAccounts: next.hasRegisteredAccounts)
            XCTAssertEqual(removed.message, "현재 등록된 계정이 없습니다.")
            XCTAssertNotEqual(hidden.detail, removed.detail)
            XCTAssertTrue(next.registerAccountPaths([root.path, "", "", ""], now: firstDate.addingTimeInterval(120)))
            XCTAssertEqual(PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database).firstAccountRegisteredAt, firstDate)
        }
    }

    /// 등록일을 알 수 없는 기존 계정 이관 후 임의의 최초 날짜 생성 방지 검증
    func testExistingLegacyAccountKeepsUnknownFirstRegistrationDate() throws {
        try withFixture { defaults, root, database in
            defaults.set([root.path, "", "", ""], forKey: PreferencesStore.Keys.accountPaths)
            let migrated = PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database)
            XCTAssertTrue(migrated.hasRegisteredAccount)
            XCTAssertNil(migrated.firstAccountRegisteredAt)
            XCTAssertTrue(migrated.registerAccountPaths([root.path, "", "", ""], now: Date()))
            XCTAssertTrue(migrated.updateAccountPaths(["", "", "", ""]))
            let restored = PreferencesStore(userDefaults: defaults, quotaDatabaseURL: database)
            XCTAssertTrue(restored.hasRegisteredAccount)
            XCTAssertNil(restored.firstAccountRegisteredAt)
        }
    }

    /// 이전 실행 시각·횟수의 무시와 등록 필드만 재인코딩하는 이관 자료형 검증
    func testLegacyHistoryDecodesRegistrationWithoutRetainingLaunchCounters() throws {
        let data = Data(#"{"schemaVersion":1,"firstLaunchedAt":"2026-01-01T00:00:00Z","lastLaunchedAt":"2026-01-02T00:00:00Z","launchCount":4,"hasRegisteredAccount":true,"firstAccountRegisteredAt":"2026-01-01T01:00:00Z"}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let history = try decoder.decode(InstallationHistory.self, from: data)
        XCTAssertTrue(history.hasRegisteredAccount)
        XCTAssertEqual(history.firstAccountRegisteredAt, ISO8601DateFormatter().date(from: "2026-01-01T01:00:00Z"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(history)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "hasRegisteredAccount", "firstAccountRegisteredAt"])
        let unknownDate = try decoder.decode(InstallationHistory.self, from: Data(#"{"schemaVersion":1,"launchCount":12,"hasRegisteredAccount":true}"#.utf8))
        XCTAssertTrue(unknownDate.hasRegisteredAccount)
        XCTAssertNil(unknownDate.firstAccountRegisteredAt)
    }

    /// 미등록·전체 비활성화 안내의 팝오버 내부 렌더 높이 검증
    func testEmptyAccountMessagesFitPopover() throws {
        for registered in [false, true] {
            let renderer = ImageRenderer(content: EmptyAccountsView(hasRegisteredAccounts: registered, onOpenSettings: {}))
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(image.width, Int(EmptyAccountsView.contentSize.width))
            XCTAssertLessThanOrEqual(image.height, Int(EmptyAccountsView.contentSize.height))
        }
    }

    /// 외부 저장 경계에서 등록 정보와 설정의 단일 묶음 검사
    private func bundleObject(_ defaults: UserDefaults) throws -> [String: Any] {
        let data = try XCTUnwrap(defaults.data(forKey: PreferencesStore.Keys.settingsBundle))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// 실제 사용자 이력과 분리된 설정 도메인·폴더·SQLite 경로 제공
    private func withFixture(_ body: (UserDefaults, URL, URL) throws -> Void) throws {
        let suite = "InstallationHistoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(defaults, root, root.appendingPathComponent("quota.sqlite"))
    }
}
