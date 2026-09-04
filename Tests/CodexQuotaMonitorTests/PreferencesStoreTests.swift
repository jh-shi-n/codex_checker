import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

@MainActor
final class PreferencesStoreTests: XCTestCase {
    func testMissingValuesUseFiveMinuteIntervalAndFourDefaultPaths() {
        let defaults = isolatedDefaults()
        let store = PreferencesStore(userDefaults: defaults)

        XCTAssertEqual(store.refreshIntervalMinutes, 5)
        XCTAssertEqual(store.accountPaths.count, 4)
        XCTAssertEqual(store.accountPaths, AccountConfig.defaultAccounts().map { $0.home.path })
        XCTAssertFalse(store.launchAtLogin)
        XCTAssertFalse(store.showAccountLabels)
        XCTAssertEqual(store.activityNotificationDurationSeconds, 3)
    }

    func testActivityNotificationDurationNormalizesAndPersistsAcrossInstances() {
        let defaults = isolatedDefaults()
        let store = PreferencesStore(userDefaults: defaults)

        XCTAssertEqual(store.activityNotificationDurationSeconds, 3)
        store.updateActivityNotificationDuration(seconds: 0)
        XCTAssertEqual(store.activityNotificationDurationSeconds, 1)
        store.updateActivityNotificationDuration(seconds: 11)
        XCTAssertEqual(store.activityNotificationDurationSeconds, 10)
        store.setActivityNotificationDuration(seconds: 7)

        let reloaded = PreferencesStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.activityNotificationDurationSeconds, 7)
        XCTAssertEqual(
            defaults.object(forKey: PreferencesStore.Keys.activityNotificationDurationSeconds) as? Int,
            7
        )
    }

    func testInvalidActivityNotificationDurationRawValueIsCanonicalizedAtInitialization() {
        let defaults = isolatedDefaults()
        defaults.set(99, forKey: PreferencesStore.Keys.activityNotificationDurationSeconds)

        let store = PreferencesStore(userDefaults: defaults)

        XCTAssertEqual(store.activityNotificationDurationSeconds, 10)
        XCTAssertEqual(
            defaults.object(forKey: PreferencesStore.Keys.activityNotificationDurationSeconds) as? Int,
            10
        )
    }

    func testInvalidIntervalAndPathCountAreNormalizedToDefaults() {
        let defaults = isolatedDefaults()
        defaults.set(0, forKey: PreferencesStore.Keys.refreshIntervalMinutes)
        defaults.set(["/tmp/only-one"], forKey: PreferencesStore.Keys.accountPaths)

        let store = PreferencesStore(userDefaults: defaults)

        XCTAssertEqual(store.refreshIntervalMinutes, 5)
        XCTAssertEqual(store.accountPaths, AccountConfig.defaultAccounts().map { $0.home.path })
    }

    func testCustomRefreshIntervalPersistsAcrossInstances() {
        let defaults = isolatedDefaults()
        let store = PreferencesStore(userDefaults: defaults)

        store.updateRefreshInterval(minutes: 7)

        let reloaded = PreferencesStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.refreshIntervalMinutes, 7)
        XCTAssertEqual(defaults.object(forKey: PreferencesStore.Keys.refreshIntervalMinutes) as? Int, 7)
    }

    func testRefreshIntervalAboveMaximumClampsAndNonPositiveUpdatesUseDefault() {
        let defaults = isolatedDefaults()
        let store = PreferencesStore(userDefaults: defaults)

        store.updateRefreshInterval(minutes: 1_441)
        XCTAssertEqual(store.refreshIntervalMinutes, 1_440)
        store.updateRefreshInterval(minutes: -1)
        XCTAssertEqual(store.refreshIntervalMinutes, 5)
    }

    func testInvalidIntervalUpdatesPersistCanonicalValuesAcrossReloads() {
        let defaults = isolatedDefaults()
        let store = PreferencesStore(userDefaults: defaults)

        store.updateRefreshInterval(minutes: 0)
        XCTAssertEqual(defaults.object(forKey: PreferencesStore.Keys.refreshIntervalMinutes) as? Int, 5)
        XCTAssertEqual(PreferencesStore(userDefaults: defaults).refreshIntervalMinutes, 5)

        store.updateRefreshInterval(minutes: 1_441)
        XCTAssertEqual(defaults.object(forKey: PreferencesStore.Keys.refreshIntervalMinutes) as? Int, 1_440)
        XCTAssertEqual(PreferencesStore(userDefaults: defaults).refreshIntervalMinutes, 1_440)
    }

    func testValidIntervalFourPathsAndLaunchPreferencePersistAcrossInstances() {
        let defaults = isolatedDefaults()
        let fixtureRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let paths = (1...4).map { index in
            makeDirectory(
                at: fixtureRoot.appendingPathComponent("c\(index)", isDirectory: true)
            ).path
        }
        let store = PreferencesStore(userDefaults: defaults)

        store.updateRefreshInterval(minutes: 10)
        store.updateAccountPaths(paths)
        store.updateLaunchAtLogin(true)
        store.updateShowAccountLabels(true)

        let reloaded = PreferencesStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.refreshIntervalMinutes, 10)
        XCTAssertEqual(reloaded.accountPaths, paths)
        XCTAssertTrue(reloaded.launchAtLogin)
        XCTAssertTrue(reloaded.showAccountLabels)
    }

    func testShowAccountLabelsCanBeDisabledAndPersistsFalse() {
        let defaults = isolatedDefaults()
        let store = PreferencesStore(userDefaults: defaults)

        store.updateShowAccountLabels(true)
        store.setShowAccountLabels(false)

        let reloaded = PreferencesStore(userDefaults: defaults)
        XCTAssertFalse(reloaded.showAccountLabels)
        XCTAssertEqual(defaults.object(forKey: PreferencesStore.Keys.showAccountLabels) as? Bool, false)
    }

    func testInvalidShowAccountLabelsRawValueNormalizesToFalse() {
        let defaults = isolatedDefaults()
        defaults.set("yes", forKey: PreferencesStore.Keys.showAccountLabels)

        let store = PreferencesStore(userDefaults: defaults)

        XCTAssertFalse(store.showAccountLabels)
        XCTAssertEqual(defaults.object(forKey: PreferencesStore.Keys.showAccountLabels) as? Bool, false)
    }

    func testInvalidUpdatesAreNormalizedBeforePersistence() {
        let defaults = isolatedDefaults()
        let fixtureRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let defaultsPaths = (1...4).map { index in
            makeDirectory(
                at: fixtureRoot.appendingPathComponent("default-\(index)", isDirectory: true)
            ).path
        }
        let validReplacement = makeDirectory(
            at: fixtureRoot.appendingPathComponent("replacement", isDirectory: true)
        ).path
        let store = PreferencesStore(userDefaults: defaults)

        store.updateRefreshInterval(minutes: -1)
        store.updateAccountPaths([validReplacement, "", "/path/does/not/exist", "/path/also/missing"])

        XCTAssertEqual(store.refreshIntervalMinutes, 5)
        XCTAssertEqual(store.accountPaths.count, 4)
        XCTAssertEqual(store.accountPaths[0], validReplacement)
        XCTAssertEqual(store.accountPaths[1], "")
        XCTAssertEqual(store.accountPaths[2], AccountConfig.defaultAccounts()[2].home.path)
        XCTAssertEqual(store.accountPaths[3], AccountConfig.defaultAccounts()[3].home.path)

        let storeWithInjectedDefaults = PreferencesStore(
            userDefaults: isolatedDefaults(),
            defaultPaths: defaultsPaths,
            homeDirectory: fixtureRoot
        )
        storeWithInjectedDefaults.updateAccountPaths([
            validReplacement,
            "",
            "/path/does/not/exist",
            "/path/also/missing",
        ])
        XCTAssertEqual(storeWithInjectedDefaults.accountPaths, [
            validReplacement,
            "",
            defaultsPaths[2],
            defaultsPaths[3],
        ])
    }

    func testInvalidRawPreferencesAreCanonicalizedAtInitialization() {
        let defaults = isolatedDefaults()
        let home = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let first = makeDirectory(at: home.appendingPathComponent(".codex-1", isDirectory: true))
        let second = makeDirectory(at: home.appendingPathComponent("custom-c2", isDirectory: true))
        let fourth = makeDirectory(at: home.appendingPathComponent("c4", isDirectory: true))
        let defaultPaths = (1...4).map { home.appendingPathComponent("default-\($0)", isDirectory: true).path }
        defaults.set(7, forKey: PreferencesStore.Keys.refreshIntervalMinutes)
        defaults.set(["~/.codex-1", "~/custom-c2", "", fourth.path], forKey: PreferencesStore.Keys.accountPaths)

        let store = PreferencesStore(
            userDefaults: defaults,
            defaultPaths: defaultPaths,
            homeDirectory: home
        )

        let expectedPaths = [
            first.path,
            second.path,
            "",
            fourth.path,
        ]
        XCTAssertEqual(store.refreshIntervalMinutes, 7)
        XCTAssertEqual(store.accountPaths, expectedPaths)
        XCTAssertEqual(defaults.object(forKey: PreferencesStore.Keys.refreshIntervalMinutes) as? Int, 7)
        XCTAssertEqual(defaults.object(forKey: PreferencesStore.Keys.accountPaths) as? [String], expectedPaths)
    }

    func testLeadingTildePathsExpandAgainstInjectedHomeDirectory() {
        let home = URL(fileURLWithPath: "/tmp/injected-home", isDirectory: true)
        let defaults = (1...4).map { "/tmp/default-\($0)" }

        let normalized = PreferencesStore.normalizedPaths(
            ["~", "~/one", "~/.codex-3", "/tmp/four"],
            defaults: defaults,
            homeDirectory: home
        )

        XCTAssertEqual(normalized, [
            home.path,
            home.appendingPathComponent("one").path,
            home.appendingPathComponent(".codex-3").path,
            "/tmp/four",
        ])
    }

    func testAccountPathValidationDistinguishesEmptyMissingFileUnreadableAndDirectory() {
        let fixtureRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let valid = makeDirectory(at: fixtureRoot.appendingPathComponent("valid", isDirectory: true))
        let unreadable = makeDirectory(at: fixtureRoot.appendingPathComponent("unreadable", isDirectory: true))
        let regularFile = fixtureRoot.appendingPathComponent("regular.txt", isDirectory: false)
        XCTAssertTrue(FileManager.default.createFile(atPath: regularFile.path, contents: Data()))

        let liveFileSystem = AccountPathFileSystem.live
        let fileSystem = AccountPathFileSystem { path in
            if path == unreadable.path {
                return AccountPathFileMetadata(exists: true, isDirectory: true, isReadable: false)
            }
            return liveFileSystem.metadata(path)
        }

        XCTAssertEqual(AccountConfig.validatePath("", homeDirectory: fixtureRoot, fileSystem: fileSystem), .empty)
        XCTAssertEqual(
            AccountConfig.validatePath(
                fixtureRoot.appendingPathComponent("missing").path,
                homeDirectory: fixtureRoot,
                fileSystem: fileSystem
            ),
            .missing
        )
        XCTAssertEqual(
            AccountConfig.validatePath(regularFile.path, homeDirectory: fixtureRoot, fileSystem: fileSystem),
            .notDirectory
        )
        XCTAssertEqual(
            AccountConfig.validatePath(unreadable.path, homeDirectory: fixtureRoot, fileSystem: fileSystem),
            .unreadable
        )
        XCTAssertEqual(
            AccountConfig.validatePath(valid.path, homeDirectory: fixtureRoot, fileSystem: fileSystem),
            .valid
        )
    }

    func testInvalidAccountPathsAreNotPersistedWhileEmptyAndValidPathsAreAccepted() {
        let fixtureRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let defaultsPaths = (1...4).map { index in
            makeDirectory(
                at: fixtureRoot.appendingPathComponent("default-\(index)", isDirectory: true)
            ).path
        }
        let replacement = makeDirectory(
            at: fixtureRoot.appendingPathComponent("replacement", isDirectory: true)
        ).path
        let regularFile = fixtureRoot.appendingPathComponent("regular.txt", isDirectory: false)
        XCTAssertTrue(FileManager.default.createFile(atPath: regularFile.path, contents: Data()))
        let unreadable = makeDirectory(at: fixtureRoot.appendingPathComponent("unreadable", isDirectory: true))
        let missing = fixtureRoot.appendingPathComponent("missing", isDirectory: true).path

        let liveFileSystem = AccountPathFileSystem.live
        let fileSystem = AccountPathFileSystem { path in
            if path == unreadable.path {
                return AccountPathFileMetadata(exists: true, isDirectory: true, isReadable: false)
            }
            return liveFileSystem.metadata(path)
        }
        let defaults = isolatedDefaults()
        let store = PreferencesStore(
            userDefaults: defaults,
            defaultPaths: defaultsPaths,
            homeDirectory: fixtureRoot,
            fileSystem: fileSystem
        )

        store.updateAccountPaths([replacement, missing, regularFile.path, unreadable.path])
        XCTAssertEqual(store.accountPaths, [replacement] + Array(defaultsPaths.dropFirst()))
        XCTAssertEqual(
            defaults.object(forKey: PreferencesStore.Keys.accountPaths) as? [String],
            [replacement] + Array(defaultsPaths.dropFirst())
        )

        store.updateAccountPaths([replacement, "", defaultsPaths[2], defaultsPaths[3]])
        XCTAssertEqual(store.accountPaths, [replacement, "", defaultsPaths[2], defaultsPaths[3]])
    }

    func testQuotaSnapshotPersistsByNormalizedPathAndExcludesSensitivePayloadFields() {
        let home = URL(fileURLWithPath: "/tmp/quota-snapshot-home", isDirectory: true)
        let defaults = isolatedDefaults()
        let defaultPaths = (1...4).map { home.appendingPathComponent(".codex-\($0)").path }
        let snapshot = PreferencesStore.QuotaSnapshot(
            usedPercent: 23,
            remainingPercent: 77,
            resetAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let store = PreferencesStore(
            userDefaults: defaults,
            defaultPaths: defaultPaths,
            homeDirectory: home
        )

        store.updateQuotaSnapshot(for: "~/account-one", snapshot: snapshot)

        let reloaded = PreferencesStore(
            userDefaults: defaults,
            defaultPaths: defaultPaths,
            homeDirectory: home
        )
        XCTAssertEqual(reloaded.quotaSnapshot(for: home.appendingPathComponent("account-one")), snapshot)
        XCTAssertNil(reloaded.quotaSnapshot(for: home.appendingPathComponent("account-two")))

        let payload = defaults.data(forKey: PreferencesStore.Keys.lastSuccessfulQuotaSnapshots)
        let payloadText = payload.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertFalse(payloadText.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(payloadText.localizedCaseInsensitiveContains("auth"))
        XCTAssertFalse(payloadText.localizedCaseInsensitiveContains("rawResponse"))
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "CodexQuotaMonitorTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexQuotaMonitorTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeDirectory(at directory: URL) -> URL {
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
