// 목적: 표시 계정·순서 저장 실패 시 화면 초안과 실제 설정의 일치 검증
// 이용처: 설정 바인딩 저장 경계의 회귀 테스트
// 사용방법: swift test --filter SettingsDisplayPersistenceTests
import Foundation
import SwiftUI
import XCTest
@testable import CodexQuotaMonitorKit

/// 실제 파일 저장 실패와 복구 이후 표시 설정 재시도 검증
@MainActor
final class SettingsDisplayPersistenceTests: XCTestCase {
    /// 표시 계정 저장 실패 시 이전 선택 복원 및 재시도 성공 검증
    func testVisibilityDraftMatchesPersistedValuesAfterFailureAndRetry() throws {
        try verifyFailureAndRetry(proposed: ["C3"], binding: { store in
            Binding(get: { store.enabledAccountIDs }, set: { store.updateEnabledAccountIDs($0) })
        }, restored: { $0.enabledAccountIDs })
    }

    /// 순서 저장 실패 시 이전 배치 복원 및 재시도 성공 검증
    func testOrderDraftMatchesPersistedValuesAfterFailureAndRetry() throws {
        try verifyFailureAndRetry(proposed: ["C4", "C3", "C2", "C1"], binding: { store in
            Binding(get: { store.accountDisplayOrder }, set: { store.updateAccountDisplayOrder($0) })
        }, restored: { $0.accountDisplayOrder })
    }

    /// 격리된 설정 파일 손상으로 저장 실패 유발 후 실제 UI 저장 경계 검증
    private func verifyFailureAndRetry(
        proposed: [String],
        binding: (PreferencesStore) -> Binding<[String]>,
        restored: (PreferencesStore) -> [String]
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "SettingsDisplayPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = AppConfigurationFile(fileURL: root.appendingPathComponent("config.json"))
        let store = PreferencesStore(userDefaults: defaults, configurationFile: file)
        let original = try Data(contentsOf: file.fileURL)
        let values = binding(store)
        let previous = values.wrappedValue
        let committed = defaults.data(forKey: PreferencesStore.Keys.settingsBundle)
        try Data("invalid marker".utf8).write(to: file.fileURL)
        let failedDraft = SettingsView.applyDisplayChange(proposed, binding: values)
        XCTAssertNotNil(store.persistenceError)
        XCTAssertEqual(failedDraft, previous)
        XCTAssertEqual(values.wrappedValue, previous)
        XCTAssertEqual(defaults.data(forKey: PreferencesStore.Keys.settingsBundle), committed)
        try original.write(to: file.fileURL)
        let acceptedDraft = SettingsView.applyDisplayChange(proposed, binding: values)
        XCTAssertNil(store.persistenceError)
        XCTAssertEqual(acceptedDraft, proposed)
        let reloaded = PreferencesStore(userDefaults: defaults, configurationFile: file)
        XCTAssertEqual(restored(reloaded), acceptedDraft)
    }
}
