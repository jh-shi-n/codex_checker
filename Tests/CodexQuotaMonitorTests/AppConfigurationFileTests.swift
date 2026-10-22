// 목적: JSON 설정의 단일 기준·기존 설정 이관·인증정보 저장 제외 검증
// 이용처: 계정 등록·설정 변경·실행 이력의 통합 회귀 테스트
// 사용방법: swift test --filter AppConfigurationFileTests
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 실제 인증 파일 없이 격리된 설정 파일의 저장·로드 동작 검증
@MainActor
final class AppConfigurationFileTests: XCTestCase {
    /// 기존 plist 설정만 이전하고 허용되지 않은 인증 관련 값은 저장하지 않는지 검증
    func testLegacyPreferencesMigrateWithoutAuthenticationFields() throws {
        try withFixture { file, defaults, folder in
            defaults.set([folder.path, "", "", ""], forKey: PreferencesStore.Keys.accountPaths)
            defaults.set(7, forKey: PreferencesStore.Keys.refreshIntervalMinutes)
            defaults.set("SECRET-MUST-NOT-BE-COPIED", forKey: "CodexQuotaMonitor.accessToken")
            let preferences = PreferencesStore(userDefaults: defaults, configurationFile: file)
            XCTAssertEqual(preferences.accountPaths[0], folder.path)
            XCTAssertEqual(try file.read()?.settings?.refreshIntervalMinutes, 7)
            let text = try String(contentsOf: file.fileURL, encoding: .utf8)
            XCTAssertFalse(text.contains("SECRET-MUST-NOT-BE-COPIED"))
            XCTAssertFalse(text.contains("accessToken"))
            XCTAssertNil(preferences.persistenceError)
        }
    }

    /// 모든 사용자 설정의 JSON 저장과 새로운 설정 모델에서의 복원 검증
    func testEverySettingRoundTripsThroughConfigJSON() throws {
        try withFixture { file, defaults, folder in
            let preferences = PreferencesStore(userDefaults: defaults, configurationFile: file)
            preferences.updateAccountPaths([folder.path, "", "", ""])
            preferences.updateEnabledAccountIDs([])
            preferences.updateAccountDisplayOrder(["C4", "C3", "C2", "C1"])
            preferences.updateRefreshInterval(minutes: 7)
            preferences.updateResetReminder(minutes: 3)
            preferences.updateActivityNotificationDuration(seconds: 8)
            preferences.updateShowAccountLabels(true)
            preferences.updateLaunchAtLogin(true)
            let loaded = PreferencesStore(userDefaults: defaults, configurationFile: file)
            XCTAssertEqual(loaded.accountPaths, [folder.path, "", "", ""])
            XCTAssertEqual(loaded.enabledAccountIDs, [])
            XCTAssertEqual(loaded.accountDisplayOrder, ["C4", "C3", "C2", "C1"])
            XCTAssertEqual(loaded.refreshIntervalMinutes, 7)
            XCTAssertEqual(loaded.resetReminderMinutes, 3)
            XCTAssertEqual(loaded.activityNotificationDurationSeconds, 8)
            XCTAssertTrue(loaded.showAccountLabels)
            XCTAssertTrue(loaded.launchAtLogin)
            XCTAssertNil(defaults.object(forKey: PreferencesStore.Keys.accountPaths))
            XCTAssertNil(defaults.object(forKey: PreferencesStore.Keys.refreshIntervalMinutes))
        }
    }

    /// JSON 도입 후 plist의 오래된 값으로 계정·설정을 복구하지 않는지 검증
    func testConfigTakesPrecedenceAndDeletedAccountsStayDeleted() throws {
        try withFixture { file, defaults, folder in
            defaults.set([folder.path, "", "", ""], forKey: PreferencesStore.Keys.accountPaths)
            let preferences = PreferencesStore(userDefaults: defaults, configurationFile: file)
            preferences.updateAccountPaths(["", "", "", ""])
            preferences.updateRefreshInterval(minutes: 11)
            defaults.set(99, forKey: PreferencesStore.Keys.refreshIntervalMinutes)
            let loaded = PreferencesStore(userDefaults: defaults, configurationFile: file)
            XCTAssertEqual(loaded.accountPaths, ["", "", "", ""])
            XCTAssertEqual(loaded.refreshIntervalMinutes, 11)
        }
    }

    /// 실행·등록 이력과 설정 저장이 서로의 섹션을 덮어쓰지 않는지 검증
    func testHistoryAndSettingsPreserveEachOther() throws {
        try withFixture { file, defaults, folder in
            let preferences = PreferencesStore(userDefaults: defaults, configurationFile: file)
            let history = InstallationHistoryStore(fileURL: file.fileURL)
            XCTAssertTrue(history.isFirstLaunch)
            preferences.updateAccountPaths([folder.path, "", "", ""])
            XCTAssertTrue(history.markAccountRegistered())
            preferences.updateRefreshInterval(minutes: 17)
            XCTAssertTrue(history.markAccountRegistered())
            let document = try XCTUnwrap(file.read())
            XCTAssertEqual(document.settings?.refreshIntervalMinutes, 17)
            XCTAssertEqual(document.settings?.accountPaths[0], folder.path)
            XCTAssertEqual(document.installation?.hasRegisteredAccount, true)
            preferences.updateAccountPaths(["", "", "", ""])
            let next = InstallationHistoryStore(fileURL: file.fileURL)
            XCTAssertFalse(next.requiresAccountSetup)
            XCTAssertEqual(try file.read()?.settings?.accountPaths, ["", "", "", ""])
        }
    }

    /// 설정 창 재진입 로드에서 외부 파일 변경을 반영하는지 검증
    func testSettingsReloadUsesCurrentFileContents() throws {
        try withFixture { file, defaults, folder in
            let preferences = PreferencesStore(userDefaults: defaults, configurationFile: file)
            var settings = try XCTUnwrap(file.read()?.settings)
            settings.accountPaths = [folder.path, "", "", ""]
            settings.enabledAccountIDs = []
            settings.refreshIntervalMinutes = 13
            try file.saveSettings(settings)
            XCTAssertTrue(preferences.reloadFromConfiguration())
            XCTAssertEqual(preferences.accountPaths[0], folder.path)
            XCTAssertEqual(preferences.enabledAccountIDs, [])
            XCTAssertEqual(preferences.refreshIntervalMinutes, 13)
        }
    }

    /// 손상 파일에서 기존 plist로 우회하거나 손상 원본을 덮어쓰지 않는지 검증
    func testCorruptConfigDoesNotFallBackToLegacyOrOverwriteFile() throws {
        try withFixture { file, defaults, folder in
            defaults.set([folder.path, "", "", ""], forKey: PreferencesStore.Keys.accountPaths)
            let bytes = Data("invalid json".utf8)
            try bytes.write(to: file.fileURL)
            let preferences = PreferencesStore(userDefaults: defaults, configurationFile: file)
            XCTAssertFalse(preferences.hasRegisteredAccounts)
            XCTAssertNotNil(preferences.persistenceError)
            preferences.updateRefreshInterval(minutes: 9)
            XCTAssertNotNil(preferences.persistenceError)
            XCTAssertFalse(preferences.reloadFromConfiguration())
            XCTAssertEqual(try Data(contentsOf: file.fileURL), bytes)
        }
    }

    /// 버전 1 실행 이력을 설정과 함께 버전 2로 이전하는지 검증
    func testVersionOneHistoryMigratesAndPreservesInitialRegistration() throws {
        try withFixture { file, defaults, _ in
            let bytes = Data(#"{"schemaVersion":1,"firstLaunchedAt":"2026-01-01T00:00:00Z","lastLaunchedAt":"2026-01-01T00:00:00Z","launchCount":4,"hasRegisteredAccount":true}"#.utf8)
            try bytes.write(to: file.fileURL)
            _ = PreferencesStore(userDefaults: defaults, configurationFile: file)
            let history = InstallationHistoryStore(fileURL: file.fileURL)
            XCTAssertFalse(history.requiresAccountSetup)
            XCTAssertEqual(history.history.launchCount, 5)
            XCTAssertEqual(try file.read()?.schemaVersion, 2)
            XCTAssertNotNil(try file.read()?.settings)
        }
    }

    /// 설정 파일에 허용된 필드만 기록하고 경로 내부 인증 파일을 참조하지 않는지 검증
    func testConfigSettingsContainOnlyAllowedFields() throws {
        try withFixture { file, defaults, folder in
            try Data("AUTH-FILE-SECRET".utf8).write(to: folder.appendingPathComponent("auth.json"))
            let preferences = PreferencesStore(userDefaults: defaults, configurationFile: file)
            preferences.updateAccountPaths([folder.path, "", "", ""])
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file.fileURL)) as? [String: Any])
            let settings = try XCTUnwrap(json["settings"] as? [String: Any])
            XCTAssertEqual(Set(settings.keys), ["accountPaths", "enabledAccountIDs", "accountDisplayOrder", "refreshIntervalMinutes", "resetReminderMinutes", "activityNotificationDurationSeconds", "showAccountLabels", "launchAtLogin"])
            XCTAssertFalse(try String(contentsOf: file.fileURL, encoding: .utf8).contains("AUTH-FILE-SECRET"))
            let attributes = try FileManager.default.attributesOfItem(atPath: file.fileURL.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    /// 사용자 설정과 인증 파일에서 분리된 임시 폴더·UserDefaults 생성 및 정리
    private func withFixture(_ body: (AppConfigurationFile, UserDefaults, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppConfigurationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "AppConfigurationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(AppConfigurationFile(fileURL: root.appendingPathComponent("config.json")), defaults, root)
    }
}
