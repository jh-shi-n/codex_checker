// 목적: 이전 JSON 설정·등록 이력의 이관과 원본 보존 검증
// 이용처: UserDefaults 설정 묶음 도입과 이전 파일 호환성 회귀 테스트
// 사용방법: 최종 통합 검증 시 AppConfigurationFileTests 실행
// 실행 예시: swift test --filter AppConfigurationFileTests
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 인증정보를 제외한 이관 경계와 손상 원본 보존 검증
@MainActor
final class AppConfigurationFileTests: XCTestCase {
    /// 이전 개별 설정의 허용 필드만 묶음으로 이관하고 JSON 생성 방지 검증
    func testLegacyPreferencesMigrateToBundleWithoutAuthenticationFieldsOrJSONWrites() throws {
        try withFixture { file, defaults, root in
            defaults.set([root.path, "", "", ""], forKey: PreferencesStore.Keys.accountPaths)
            defaults.set(7, forKey: PreferencesStore.Keys.refreshIntervalMinutes)
            defaults.set("SECRET-MUST-NOT-BE-COPIED", forKey: "CodexQuotaMonitor.accessToken")
            try Data("AUTH-FILE-SECRET".utf8).write(to: root.appendingPathComponent("auth.json"))
            let store = PreferencesStore(userDefaults: defaults, configurationFile: file, quotaDatabaseURL: root.appendingPathComponent("quota.sqlite"))
            XCTAssertEqual(store.accountPaths, [root.path, "", "", ""])
            XCTAssertEqual(store.refreshIntervalMinutes, 7)
            XCTAssertNil(store.persistenceError)
            let data = try XCTUnwrap(defaults.data(forKey: PreferencesStore.Keys.settingsBundle))
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains("SECRET-MUST-NOT-BE-COPIED"))
            XCTAssertFalse(text.contains("accessToken"))
            XCTAssertFalse(text.contains("AUTH-FILE-SECRET"))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["schemaVersion", "settings", "hasRegisteredAccount"])
            let settings = try XCTUnwrap(object["settings"] as? [String: Any])
            XCTAssertEqual(Set(settings.keys), allowedSettingFields)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.fileURL.path))
            let restored = PreferencesStore(userDefaults: defaults, configurationFile: file, quotaDatabaseURL: root.appendingPathComponent("quota.sqlite"))
            XCTAssertEqual(restored.accountPaths, store.accountPaths)
            XCTAssertEqual(restored.refreshIntervalMinutes, 7)
            XCTAssertNil(defaults.object(forKey: PreferencesStore.Keys.accountPaths))
            XCTAssertNil(defaults.object(forKey: PreferencesStore.Keys.refreshIntervalMinutes))
            XCTAssertEqual(defaults.string(forKey: "CodexQuotaMonitor.accessToken"), "SECRET-MUST-NOT-BE-COPIED")
        }
    }

    /// 버전 2 JSON의 설정·등록일 이관과 원본 파일 불변 검증
    func testVersionTwoConfigMigratesSettingsAndRegistrationWithoutRewritingSource() throws {
        try withFixture { file, defaults, root in
            let date = Date(timeIntervalSince1970: 1_800_000_000)
            var settings = payload(paths: [root.path, "", "", ""])
            settings.enabledAccountIDs = []
            settings.accountDisplayOrder = ["C4", "C3", "C2", "C1"]
            settings.refreshIntervalMinutes = 13
            settings.resetReminderMinutes = 3
            settings.activityNotificationDurationSeconds = 8
            settings.showAccountLabels = true
            settings.launchAtLogin = true
            try file.saveSettings(settings)
            try file.saveInstallation(InstallationHistory(hasRegisteredAccount: true, firstAccountRegisteredAt: date))
            let original = try Data(contentsOf: file.fileURL)
            let database = root.appendingPathComponent("quota.sqlite")
            let store = PreferencesStore(userDefaults: defaults, configurationFile: file, quotaDatabaseURL: database)
            XCTAssertEqual(store.accountPaths, settings.accountPaths)
            XCTAssertEqual(store.enabledAccountIDs, [])
            XCTAssertEqual(store.accountDisplayOrder, settings.accountDisplayOrder)
            XCTAssertEqual(store.refreshIntervalMinutes, 13)
            XCTAssertEqual(store.resetReminderMinutes, 3)
            XCTAssertEqual(store.activityNotificationDurationSeconds, 8)
            XCTAssertTrue(store.showAccountLabels)
            XCTAssertTrue(store.launchAtLogin)
            XCTAssertTrue(store.hasRegisteredAccount)
            XCTAssertEqual(store.firstAccountRegisteredAt, date)
            XCTAssertNotNil(defaults.data(forKey: PreferencesStore.Keys.settingsBundle))
            XCTAssertEqual(try Data(contentsOf: file.fileURL), original)
            store.updateRefreshInterval(minutes: 17)
            let restored = PreferencesStore(userDefaults: defaults, configurationFile: file, quotaDatabaseURL: database)
            XCTAssertEqual(restored.refreshIntervalMinutes, 17)
            XCTAssertEqual(restored.firstAccountRegisteredAt, date)
            XCTAssertEqual(try Data(contentsOf: file.fileURL), original)
        }
    }

    /// 이관 완료 묶음의 외부 JSON·개별 키보다 높은 우선순위와 삭제 상태 보존 검증
    func testBundleRemainsAuthoritativeAfterLegacyFileChangesOrCorruption() throws {
        try withFixture { file, defaults, root in
            try file.saveSettings(payload(paths: [root.path, "", "", ""]))
            let database = root.appendingPathComponent("quota.sqlite")
            let store = PreferencesStore(userDefaults: defaults, configurationFile: file, quotaDatabaseURL: database)
            XCTAssertTrue(store.updateAccountPaths(["", "", "", ""]))
            store.updateRefreshInterval(minutes: 11)
            var staleSettings = payload(paths: [root.path, "", "", ""])
            staleSettings.refreshIntervalMinutes = 99
            try file.saveSettings(staleSettings)
            defaults.set(99, forKey: PreferencesStore.Keys.refreshIntervalMinutes)
            defaults.set([root.path, "", "", ""], forKey: PreferencesStore.Keys.accountPaths)
            let restored = PreferencesStore(userDefaults: defaults, configurationFile: file, quotaDatabaseURL: database)
            XCTAssertEqual(restored.accountPaths, ["", "", "", ""])
            XCTAssertEqual(restored.refreshIntervalMinutes, 11)
            XCTAssertTrue(restored.hasRegisteredAccount)
            let corrupt = Data("changed externally to invalid json".utf8)
            try corrupt.write(to: file.fileURL)
            let next = PreferencesStore(userDefaults: defaults, configurationFile: file, quotaDatabaseURL: database)
            XCTAssertEqual(next.accountPaths, ["", "", "", ""])
            XCTAssertEqual(next.refreshIntervalMinutes, 11)
            XCTAssertNil(next.persistenceError)
            next.updateShowAccountLabels(true)
            XCTAssertTrue(next.showAccountLabels)
            XCTAssertEqual(try Data(contentsOf: file.fileURL), corrupt)
        }
    }

    /// 버전 1 등록 이력의 이전 파일명 복원과 실행 이력 재기록 방지 검증
    func testLegacyInstallationFilenameMigratesWithoutCreatingOrUpdatingJSON() throws {
        try withFixture { file, defaults, root in
            let legacy = root.appendingPathComponent("installation.json")
            let original = Data(#"{"schemaVersion":1,"firstLaunchedAt":"2026-01-01T00:00:00Z","lastLaunchedAt":"2026-01-02T00:00:00Z","launchCount":4,"hasRegisteredAccount":true,"firstAccountRegisteredAt":"2026-01-01T01:00:00Z"}"#.utf8)
            try original.write(to: legacy)
            let document = try XCTUnwrap(file.read())
            XCTAssertEqual(document.schemaVersion, 2)
            XCTAssertEqual(document.installation?.hasRegisteredAccount, true)
            XCTAssertNil(document.settings)
            let database = root.appendingPathComponent("quota.sqlite")
            let migrated = PreferencesStore(userDefaults: defaults, configurationFile: file, quotaDatabaseURL: database)
            let date = ISO8601DateFormatter().date(from: "2026-01-01T01:00:00Z")
            XCTAssertTrue(migrated.hasRegisteredAccount)
            XCTAssertEqual(migrated.firstAccountRegisteredAt, date)
            XCTAssertEqual(migrated.accountPaths, ["", "", "", ""])
            let restored = PreferencesStore(userDefaults: defaults, configurationFile: file, quotaDatabaseURL: database)
            XCTAssertTrue(restored.hasRegisteredAccount)
            XCTAssertEqual(restored.firstAccountRegisteredAt, date)
            XCTAssertEqual(try Data(contentsOf: legacy), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.fileURL.path))
        }
    }

    /// 버전 1 config.json의 알려지지 않은 최초 등록일 유지 검증
    func testVersionOneConfigKeepsUnknownRegistrationDateDuringMigration() throws {
        try withFixture { file, defaults, root in
            let original = Data(#"{"schemaVersion":1,"firstLaunchedAt":"2026-01-01T00:00:00Z","launchCount":4,"hasRegisteredAccount":true}"#.utf8)
            try original.write(to: file.fileURL)
            let store = PreferencesStore(userDefaults: defaults, configurationFile: file, quotaDatabaseURL: root.appendingPathComponent("quota.sqlite"))
            XCTAssertTrue(store.hasRegisteredAccount)
            XCTAssertNil(store.firstAccountRegisteredAt)
            XCTAssertTrue(store.registerAccountPaths([root.path, "", "", ""], now: Date()))
            XCTAssertNil(store.firstAccountRegisteredAt)
            XCTAssertEqual(try Data(contentsOf: file.fileURL), original)
            XCTAssertEqual(try file.read()?.schemaVersion, 2)
        }
    }

    /// config.json 존재 시 이전 installation.json의 내용보다 우선하는 읽기 계약 검증
    func testCurrentConfigTakesPrecedenceOverLegacyInstallationFile() throws {
        try withFixture { file, _, root in
            let settings = payload(paths: [root.path, "", "", ""])
            try file.saveSettings(settings)
            let legacy = root.appendingPathComponent("installation.json")
            let bytes = Data("corrupt legacy file".utf8)
            try bytes.write(to: legacy)
            let document = try XCTUnwrap(file.read())
            XCTAssertEqual(document.settings, settings)
            XCTAssertNil(document.installation)
            XCTAssertEqual(try Data(contentsOf: legacy), bytes)
        }
    }

    /// 손상·미지원·불일치 이력의 개별 키·이전 파일 우회 및 덮어쓰기 차단 검증
    func testCorruptConfigBlocksMigrationAndPreservesAllOriginalSources() throws {
        let cases = [
            Data("invalid json".utf8),
            Data(#"{"schemaVersion":999}"#.utf8),
            Data(#"{"schemaVersion":1}"#.utf8),
            Data(#"{"schemaVersion":2,"installation":{"schemaVersion":999,"hasRegisteredAccount":true}}"#.utf8),
            Data(#"{"schemaVersion":2,"installation":{"schemaVersion":1,"hasRegisteredAccount":false,"firstAccountRegisteredAt":"2026-01-01T00:00:00Z"}}"#.utf8),
        ]
        for bytes in cases {
            try withFixture { file, defaults, root in
                let legacy = root.appendingPathComponent("installation.json")
                let legacyBytes = Data(#"{"schemaVersion":1,"hasRegisteredAccount":true}"#.utf8)
                try legacyBytes.write(to: legacy)
                try bytes.write(to: file.fileURL)
                defaults.set([root.path, "", "", ""], forKey: PreferencesStore.Keys.accountPaths)
                defaults.set(17, forKey: PreferencesStore.Keys.refreshIntervalMinutes)
                XCTAssertThrowsError(try file.read())
                let store = PreferencesStore(userDefaults: defaults, configurationFile: file, quotaDatabaseURL: root.appendingPathComponent("quota.sqlite"))
                XCTAssertFalse(store.hasRegisteredAccounts)
                XCTAssertFalse(store.hasRegisteredAccount)
                XCTAssertNil(store.firstAccountRegisteredAt)
                XCTAssertEqual(store.refreshIntervalMinutes, 5)
                XCTAssertNotNil(store.persistenceError)
                store.updateRefreshInterval(minutes: 9)
                XCTAssertFalse(store.registerAccountPaths([root.path, "", "", ""]))
                XCTAssertFalse(store.persist())
                XCTAssertEqual(store.refreshIntervalMinutes, 5)
                XCTAssertNil(defaults.object(forKey: PreferencesStore.Keys.settingsBundle))
                XCTAssertEqual(defaults.integer(forKey: PreferencesStore.Keys.refreshIntervalMinutes), 17)
                XCTAssertThrowsError(try file.saveSettings(payload(paths: [root.path, "", "", ""])))
                XCTAssertThrowsError(try file.saveInstallation(InstallationHistory(hasRegisteredAccount: true)))
                XCTAssertEqual(try Data(contentsOf: file.fileURL), bytes)
                XCTAssertEqual(try Data(contentsOf: legacy), legacyBytes)
            }
        }
    }

    /// 이관 어댑터의 섹션 보존·허용 필드·파일 권한 검증
    func testLegacyFileAdapterPreservesOtherSectionAndRestrictsSavedFields() throws {
        try withFixture { file, _, root in
            XCTAssertEqual(AppConfigurationFile.defaultFileURL.lastPathComponent, "config.json")
            XCTAssertNil(try file.read())
            let date = Date(timeIntervalSince1970: 1_800_000_000)
            let history = InstallationHistory(hasRegisteredAccount: true, firstAccountRegisteredAt: date)
            var settings = payload(paths: [root.path, "", "", ""])
            try file.saveSettings(settings)
            try file.saveInstallation(history)
            XCTAssertEqual(try file.read()?.settings, settings)
            settings.refreshIntervalMinutes = 17
            try file.saveSettings(settings)
            XCTAssertEqual(try file.read()?.installation, history)
            try file.saveInstallation(history)
            XCTAssertEqual(try file.read()?.settings, settings)
            let data = try Data(contentsOf: file.fileURL)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["schemaVersion", "settings", "installation"])
            let savedSettings = try XCTUnwrap(object["settings"] as? [String: Any])
            XCTAssertEqual(Set(savedSettings.keys), allowedSettingFields)
            let installation = try XCTUnwrap(object["installation"] as? [String: Any])
            XCTAssertEqual(Set(installation.keys), ["schemaVersion", "hasRegisteredAccount", "firstAccountRegisteredAt"])
            let attributes = try FileManager.default.attributesOfItem(atPath: file.fileURL.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            try file.saveSettings(settings)
            XCTAssertEqual(try Data(contentsOf: file.fileURL), data)
        }
    }

    /// 이전 JSON 저장 경로가 파일에 막혀도 묶음 등록·복원 허용 검증
    func testUnavailableLegacyWritePathDoesNotBlockBundleRegistration() throws {
        try withFixture { _, defaults, root in
            let parent = root.appendingPathComponent("blocked")
            let bytes = Data("parent is a file".utf8)
            try bytes.write(to: parent)
            let file = AppConfigurationFile(fileURL: parent.appendingPathComponent("config.json"))
            XCTAssertThrowsError(try file.saveSettings(payload(paths: [root.path, "", "", ""])))
            let database = root.appendingPathComponent("quota.sqlite")
            let store = PreferencesStore(userDefaults: defaults, configurationFile: file, quotaDatabaseURL: database)
            XCTAssertTrue(store.registerAccountPaths([root.path, "", "", ""]))
            XCTAssertNil(store.persistenceError)
            let next = PreferencesStore(userDefaults: defaults, configurationFile: file, quotaDatabaseURL: database)
            XCTAssertEqual(next.accountPaths, [root.path, "", "", ""])
            XCTAssertTrue(next.hasRegisteredAccount)
            XCTAssertEqual(try Data(contentsOf: parent), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.fileURL.path))
        }
    }

    /// 저장 허용 목록의 명시적 외부 계약
    private var allowedSettingFields: Set<String> {
        ["accountPaths", "enabledAccountIDs", "accountDisplayOrder", "refreshIntervalMinutes",
         "resetReminderMinutes", "activityNotificationDurationSeconds", "showAccountLabels", "launchAtLogin"]
    }

    /// 인증정보 없는 이전 설정 파일의 기본 테스트 자료 생성
    private func payload(paths: [String]) -> AppPreferencesPayload {
        AppPreferencesPayload(accountPaths: paths, enabledAccountIDs: ["C1", "C2", "C3", "C4"],
            accountDisplayOrder: ["C1", "C2", "C3", "C4"], refreshIntervalMinutes: 5,
            resetReminderMinutes: 5, activityNotificationDurationSeconds: 3,
            showAccountLabels: false, launchAtLogin: false)
    }

    /// 사용자 설정과 분리된 이전 파일·도메인·폴더 제공 및 정리
    private func withFixture(_ body: (AppConfigurationFile, UserDefaults, URL) throws -> Void) throws {
        let suite = "AppConfigurationFileTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(AppConfigurationFile(fileURL: root.appendingPathComponent("config.json")), defaults, root)
    }
}
