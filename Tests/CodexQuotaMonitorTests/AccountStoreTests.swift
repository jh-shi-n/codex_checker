import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

@MainActor
final class AccountStoreTests: XCTestCase {
    func testRefreshAllLoadsFourAccountsConcurrentlyAndPublishesEachResult() async {
        let configs = makeConfigs()
        let probe = AccountLoaderProbe()
        let store = AccountStore(configs: configs) { config in
            await probe.started(config.id)
            await probe.waitUntilReleased()
            return AccountState(
                id: config.id,
                email: "\(config.id.lowercased())@example.com",
                usedPercent: 20,
                status: .normal
            )
        }

        let refreshTask = Task { @MainActor in
            await store.refreshAll()
        }

        await probe.waitForStartedCount(4)
        XCTAssertEqual(store.states.map(\.status), Array(repeating: .loading, count: 4))
        await probe.release()
        await refreshTask.value

        XCTAssertEqual(store.states.map(\.id), ["C1", "C2", "C3", "C4"])
        XCTAssertTrue(store.states.allSatisfy { $0.status == .normal })
        XCTAssertEqual(store.states.compactMap(\.remainingPercent), [80, 80, 80, 80])
        XCTAssertEqual(store.leftStates.map(\.id), ["C1", "C2"])
        XCTAssertEqual(store.rightStates.map(\.id), ["C3", "C4"])
    }

    func testOneAccountFailureDoesNotBlockOtherAccountResults() async {
        let configs = makeConfigs()
        let store = AccountStore(configs: configs) { config in
            if config.id == "C2" {
                throw TestLoaderError.failed
            }
            return AccountState(id: config.id, usedPercent: 10, status: .normal)
        }

        await store.refreshAll()

        XCTAssertEqual(store.state(for: "C1")?.status, .normal)
        XCTAssertEqual(store.state(for: "C2")?.status, .error)
        XCTAssertEqual(store.state(for: "C3")?.status, .normal)
        XCTAssertEqual(store.state(for: "C4")?.status, .normal)
        XCTAssertTrue(store.state(for: "C2")?.errorMessage?.contains("failed") == true)
    }

    func testReturnedTransientStatesPreservePreviousSnapshotButDefinitiveStatesDoNot() async {
        let loader = ReturnedStateLoader()
        let store = AccountStore(configs: makeConfigs()) { config in
            await loader.load(config)
        }

        await store.refreshAll()
        await loader.setStatus(.timeout, for: "C1")
        await loader.setStatus(.error, for: "C2")
        await loader.setStatus(.loginRequired, for: "C3")
        await loader.setStatus(.codexNotFound, for: "C4")
        await store.refreshAll()

        let timeout = store.state(for: "C1")
        XCTAssertEqual(timeout?.status, .timeout)
        XCTAssertEqual(timeout?.errorMessage, "timed out")
        XCTAssertEqual(timeout?.email, "C1@example.com")
        XCTAssertEqual(timeout?.planType, "team")
        XCTAssertEqual(timeout?.remainingPercent, 80)
        XCTAssertEqual(timeout?.resetAt, ReturnedStateLoader.resetDate)
        XCTAssertEqual(timeout?.lastUpdated, ReturnedStateLoader.updatedDate)

        let transientError = store.state(for: "C2")
        XCTAssertEqual(transientError?.status, .error)
        XCTAssertEqual(transientError?.errorMessage, "returned error")
        XCTAssertEqual(transientError?.email, "C2@example.com")
        XCTAssertEqual(transientError?.planType, "team")
        XCTAssertEqual(transientError?.remainingPercent, 80)
        XCTAssertEqual(transientError?.resetAt, ReturnedStateLoader.resetDate)
        XCTAssertEqual(transientError?.lastUpdated, ReturnedStateLoader.updatedDate)

        let loginRequired = store.state(for: "C3")
        XCTAssertEqual(loginRequired?.status, .loginRequired)
        XCTAssertEqual(loginRequired?.errorMessage, "login required")
        XCTAssertNil(loginRequired?.email)
        XCTAssertNil(loginRequired?.planType)
        XCTAssertNil(loginRequired?.remainingPercent)
        XCTAssertNil(loginRequired?.resetAt)
        XCTAssertNil(loginRequired?.lastUpdated)

        let codexNotFound = store.state(for: "C4")
        XCTAssertEqual(codexNotFound?.status, .codexNotFound)
        XCTAssertEqual(codexNotFound?.errorMessage, "returned error")
        XCTAssertNil(codexNotFound?.email)
        XCTAssertNil(codexNotFound?.planType)
        XCTAssertNil(codexNotFound?.remainingPercent)
        XCTAssertNil(codexNotFound?.resetAt)
        XCTAssertNil(codexNotFound?.lastUpdated)
    }

    func testRecoverableErrorRefreshPublishesNewQuotaAndReturnsToNormal() async {
        let loader = ReturnedStateLoader()
        let store = AccountStore(configs: makeConfigs()) { config in
            await loader.load(config)
        }

        await store.refresh(accountID: "C1")
        await loader.setStatus(.error, for: "C1")
        await store.refresh(accountID: "C1")

        XCTAssertEqual(store.state(for: "C1")?.status, .error)
        XCTAssertEqual(store.state(for: "C1")?.remainingPercent, 80)

        await loader.setUsedPercent(40, for: "C1")
        await loader.setStatus(.normal, for: "C1")
        await store.refresh(accountID: "C1")

        XCTAssertEqual(store.state(for: "C1")?.status, .normal)
        XCTAssertEqual(store.state(for: "C1")?.usedPercent, 40)
        XCTAssertEqual(store.state(for: "C1")?.remainingPercent, 60)
    }

    func testChangingHomeClearsPreviousFieldsBeforeReturnedLoginRequiredState() async {
        let oldConfigs = makeConfigs()
        let replacementConfigs = oldConfigs.map { config in
            config.id == "C1"
                ? AccountConfig(
                    id: config.id,
                    home: URL(fileURLWithPath: "/tmp/account-new-C1"),
                    position: config.position
                )
                : config
        }
        let store = AccountStore(configs: oldConfigs) { config in
            if config.id == "C1" && config.home.path == "/tmp/account-new-C1" {
                return AccountState(id: config.id, status: .loginRequired, errorMessage: "new login required")
            }
            return AccountState(
                id: config.id,
                email: "\(config.id.lowercased())@new.example.com",
                planType: "team",
                usedPercent: 20,
                resetAt: ReturnedStateLoader.resetDate,
                lastUpdated: ReturnedStateLoader.updatedDate,
                status: .normal
            )
        }

        await store.refreshAll()
        let oldC1 = store.state(for: "C1")
        store.reconfigure(replacementConfigs)
        XCTAssertEqual(store.state(for: "C1")?.status, .loading)
        XCTAssertNil(store.state(for: "C1")?.email)
        XCTAssertEqual(store.state(for: "C2")?.email, "c2@new.example.com")

        await store.refresh(accountID: "C1")

        let newC1 = store.state(for: "C1")
        XCTAssertEqual(newC1?.status, .loginRequired)
        XCTAssertEqual(newC1?.errorMessage, "new login required")
        XCTAssertNil(newC1?.email)
        XCTAssertNil(newC1?.planType)
        XCTAssertNil(newC1?.remainingPercent)
        XCTAssertNil(newC1?.resetAt)
        XCTAssertNil(newC1?.lastUpdated)
        XCTAssertNotEqual(newC1?.email, oldC1?.email)
        XCTAssertEqual(store.state(for: "C2")?.email, "c2@new.example.com")
        XCTAssertEqual(store.state(for: "C2")?.remainingPercent, 80)
    }

    func testOverlappingRefreshesDiscardOlderGenerationResults() async {
        let configs = makeConfigs()
        let probe = OverlappingLoaderProbe()
        let store = AccountStore(configs: configs) { config in
            await probe.load(config.id)
        }

        let first = Task { @MainActor in
            await store.refreshAll()
        }
        await probe.waitForGeneration(1)

        store.reconfigure(configs.map {
            AccountConfig(id: $0.id, home: URL(fileURLWithPath: "/tmp/overlap-new-\($0.id)"), position: $0.position)
        })
        let second = Task { @MainActor in
            await store.refreshAll()
        }
        await probe.waitForGeneration(2)

        await probe.release(generation: 2)
        await second.value
        await probe.release(generation: 1)
        await first.value

        XCTAssertTrue(store.states.allSatisfy { $0.email == "generation-2" })
        XCTAssertTrue(store.states.allSatisfy { $0.status == .normal })
    }

    func testManualRefreshUpdatesOnlyRequestedAccount() async {
        let configs = makeConfigs()
        let callCounter = CallCounter()
        let store = AccountStore(configs: configs) { config in
            let count = await callCounter.increment(config.id)
            return AccountState(
                id: config.id,
                email: "\(config.id)-\(count)",
                usedPercent: Double(count),
                status: .normal
            )
        }

        await store.refreshAll()
        let before = Dictionary(uniqueKeysWithValues: store.states.map { ($0.id, $0.email) })
        await store.refresh(accountID: "C3")

        XCTAssertEqual(store.state(for: "C1")?.email, before["C1"])
        XCTAssertEqual(store.state(for: "C2")?.email, before["C2"])
        XCTAssertEqual(store.state(for: "C4")?.email, before["C4"])
        XCTAssertEqual(store.state(for: "C3")?.email, "C3-2")
    }

    func testRepeatedSameAccountRefreshesCoalesceIntoOneLoaderCall() async {
        let loader = CoalescingLoader()
        let store = AccountStore(configs: makeConfigs()) { config in
            await loader.load(config)
        }

        let first = Task { @MainActor in
            await store.refresh(accountID: "C3")
        }
        await loader.waitUntilStarted()
        let second = Task { @MainActor in
            await store.refresh(accountID: "C3")
        }
        for _ in 0..<10 { await Task.yield() }
        await loader.release()
        await first.value
        await second.value

        let callCount = await loader.callCount()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(store.state(for: "C3")?.status, .normal)
    }

    func testManualC3RefreshDuringRefreshAllDoesNotDiscardSiblingResults() async {
        let probe = AccountLoaderProbe()
        let store = AccountStore(configs: makeConfigs()) { config in
            await probe.started(config.id)
            await probe.waitUntilReleased()
            return AccountState(id: config.id, email: "(config.id)@example.com", usedPercent: 15, status: .normal)
        }

        let all = Task { @MainActor in
            await store.refreshAll()
        }
        await probe.waitForStartedCount(4)
        let manual = Task { @MainActor in
            await store.refresh(accountID: "C3")
        }
        for _ in 0..<10 { await Task.yield() }
        await probe.release()
        await all.value
        await manual.value

        XCTAssertTrue(["C1", "C2", "C4"].allSatisfy { id in
            store.state(for: id)?.status == .normal
        })
        XCTAssertEqual(store.state(for: "C3")?.status, .normal)
    }

    func testReconfigureKeepsStableOrderAndInvalidatesInFlightResults() async {
        let original = makeConfigs()
        let replacement = original.map {
            AccountConfig(id: $0.id, home: URL(fileURLWithPath: "/tmp/new-\($0.id)"), position: $0.position)
        }.reversed()
        let probe = OverlappingLoaderProbe()
        let store = AccountStore(configs: original) { config in
            await probe.load(config.id)
        }

        let oldRefresh = Task { @MainActor in
            await store.refreshAll()
        }
        await probe.waitForGeneration(1)
        store.reconfigure(Array(replacement))
        XCTAssertEqual(store.configs.map(\.id), ["C1", "C2", "C3", "C4"])
        XCTAssertEqual(store.configs.map(\.home.path), [
            "/tmp/new-C1", "/tmp/new-C2", "/tmp/new-C3", "/tmp/new-C4",
        ])
        await probe.release(generation: 1)
        await oldRefresh.value
        XCTAssertTrue(store.states.allSatisfy { $0.status == .loading })
    }

    func testSuccessfulQuotaSnapshotRestoresAfterRestartOnlyForTheSameAccountPath() async {
        let defaults = UserDefaults(suiteName: "CodexQuotaMonitorTests.\(UUID().uuidString)")!
        let preferences = PreferencesStore(userDefaults: defaults)
        let configs = makeConfigs()
        let resetDate = Date(timeIntervalSince1970: 1_700_000_000)
        let updatedDate = Date(timeIntervalSince1970: 1_700_000_100)

        let firstStore = AccountStore(configs: configs, preferencesStore: preferences) { config in
            AccountState(
                id: config.id,
                usedPercent: 37,
                resetAt: resetDate,
                lastUpdated: updatedDate,
                status: .normal
            )
        }
        await firstStore.refresh(accountID: "C1")

        let reloadedPreferences = PreferencesStore(userDefaults: defaults)
        let restartedStore = AccountStore(
            configs: configs,
            preferencesStore: reloadedPreferences
        ) { config in
            AccountState(id: config.id, status: .error, errorMessage: "not refreshed")
        }
        let restored = restartedStore.state(for: "C1")
        XCTAssertEqual(restored?.status, .loading)
        XCTAssertEqual(restored?.usedPercent, 37)
        XCTAssertEqual(restored?.remainingPercent, 63)
        XCTAssertEqual(restored?.resetAt, resetDate)
        XCTAssertEqual(restored?.lastUpdated, updatedDate)

        let changedConfigs = configs.map { config in
            config.id == "C1"
                ? AccountConfig(
                    id: config.id,
                    home: URL(fileURLWithPath: "/tmp/account-one-replacement"),
                    position: config.position
                )
                : config
        }
        let changedPathStore = AccountStore(
            configs: changedConfigs,
            preferencesStore: reloadedPreferences
        ) { config in
            AccountState(id: config.id, status: .loading)
        }
        XCTAssertNil(changedPathStore.state(for: "C1")?.usedPercent)
        XCTAssertNil(changedPathStore.state(for: "C1")?.remainingPercent)
        XCTAssertNil(changedPathStore.state(for: "C1")?.lastUpdated)
    }

    func testUnconfiguredAccountsDoNotLoadOrReadOrStoreQuota() async {
        let defaults = UserDefaults(suiteName: "CodexQuotaMonitorTests.\(UUID().uuidString)")!
        let placeholderPath = FileManager.default.currentDirectoryPath
        let unconfigured = AccountConfig.unconfigured(id: "C1", position: .left)
        let staleSnapshot = PreferencesStore.QuotaSnapshot(
            usedPercent: 91,
            remainingPercent: 9,
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_000)
        )
        defaults.set(
            try! JSONEncoder().encode([placeholderPath: staleSnapshot]),
            forKey: PreferencesStore.Keys.lastSuccessfulQuotaSnapshots
        )
        let preferencesWithStalePlaceholder = PreferencesStore(userDefaults: defaults)
        let loadRecorder = AccountLoadRecorder()
        let configs = [
            unconfigured,
            AccountConfig(id: "C2", home: URL(fileURLWithPath: "/tmp/account-2"), position: .left),
            AccountConfig(id: "C3", home: URL(fileURLWithPath: "/tmp/account-3"), position: .right),
            AccountConfig(id: "C4", home: URL(fileURLWithPath: "/tmp/account-4"), position: .right),
        ]
        let store = AccountStore(configs: configs, preferencesStore: preferencesWithStalePlaceholder) { config in
            await loadRecorder.record(config.id)
            return AccountState(id: config.id, usedPercent: 20, status: .normal)
        }

        await store.refreshAll()

        let loadedAccountIDs = await loadRecorder.ids
        XCTAssertEqual(store.state(for: "C1"), AccountState.notConfigured(id: "C1"))
        XCTAssertNil(store.state(for: "C1")?.remainingPercent)
        XCTAssertEqual(Set(loadedAccountIDs), ["C2", "C3", "C4"])
        XCTAssertEqual(preferencesWithStalePlaceholder.quotaSnapshot(for: placeholderPath), staleSnapshot)
        XCTAssertNil(preferencesWithStalePlaceholder.quotaSnapshot(for: unconfigured.home))
        XCTAssertNotNil(preferencesWithStalePlaceholder.quotaSnapshot(for: configs[1].home))
        XCTAssertNotNil(preferencesWithStalePlaceholder.quotaSnapshot(for: configs[2].home))
        XCTAssertNotNil(preferencesWithStalePlaceholder.quotaSnapshot(for: configs[3].home))
    }

    func testReconfigurePathStringsKeepsEmptySlotsUnconfiguredInStableOrder() {
        let store = AccountStore(configs: makeConfigs()) { config in
            AccountState(id: config.id, status: .normal)
        }

        store.reconfigure(pathStrings: ["", " \t", "/tmp/new-c3", "/tmp/new-c4"])

        XCTAssertEqual(store.configs.map(\.id), ["C1", "C2", "C3", "C4"])
        XCTAssertEqual(store.configs.map(\.position), [.left, .left, .right, .right])
        XCTAssertFalse(store.configs[0].isConfigured)
        XCTAssertFalse(store.configs[1].isConfigured)
        XCTAssertEqual(store.configs[2].configuredHome?.path, "/tmp/new-c3")
        XCTAssertEqual(store.configs[3].configuredHome?.path, "/tmp/new-c4")
        XCTAssertEqual(store.states.map(\.status), [.notConfigured, .notConfigured, .loading, .loading])
    }

    private func makeConfigs() -> [AccountConfig] {
        (1...4).map { index in
            AccountConfig(
                id: "C\(index)",
                home: URL(fileURLWithPath: "/tmp/account-\(index)"),
                position: index <= 2 ? .left : .right
            )
        }
    }
}

private actor AccountLoadRecorder {
    private(set) var ids: [String] = []

    func record(_ id: String) {
        ids.append(id)
    }
}

private enum TestLoaderError: Error {
    case failed
}

private actor AccountLoaderProbe {
    private var startedIDs: Set<String> = []
    private var isReleased = false

    func started(_ id: String) {
        startedIDs.insert(id)
    }

    func waitUntilReleased() async {
        while !isReleased {
            await Task.yield()
        }
    }

    func waitForStartedCount(_ expected: Int) async {
        while startedIDs.count < expected {
            await Task.yield()
        }
    }

    func release() {
        isReleased = true
    }
}

private actor OverlappingLoaderProbe {
    private var startedByGeneration: [Int: Int] = [:]
    private var releasedGenerations: Set<Int> = []
    private var loadCount = 0

    func load(_ id: String) async -> AccountState {
        loadCount += 1
        let generation = ((loadCount - 1) / 4) + 1
        startedByGeneration[generation, default: 0] += 1
        while !releasedGenerations.contains(generation) {
            await Task.yield()
        }
        return AccountState(id: id, email: "generation-\(generation)", usedPercent: 15, status: .normal)
    }

    func waitForGeneration(_ generation: Int) async {
        while (startedByGeneration[generation] ?? 0) < 4 {
            await Task.yield()
        }
    }

    func release(generation: Int) {
        releasedGenerations.insert(generation)
    }
}

private actor CallCounter {
    private var counts: [String: Int] = [:]

    func increment(_ id: String) -> Int {
        let count = (counts[id] ?? 0) + 1
        counts[id] = count
        return count
    }
}

private actor ReturnedStateLoader {
    static let resetDate = Date(timeIntervalSince1970: 1_700_000_000)
    static let updatedDate = Date(timeIntervalSince1970: 1_700_000_100)

    private var statuses: [String: AccountStatus] = [:]
    private var usedPercents: [String: Double] = [:]

    func setStatus(_ status: AccountStatus, for id: String) {
        statuses[id] = status
    }

    func setUsedPercent(_ usedPercent: Double, for id: String) {
        usedPercents[id] = usedPercent
    }

    func load(_ config: AccountConfig) -> AccountState {
        if let status = statuses[config.id], status != .normal {
            let errorMessage: String
            switch status {
            case .timeout:
                errorMessage = "timed out"
            case .loginRequired:
                errorMessage = "login required"
            default:
                errorMessage = "returned error"
            }
            return AccountState(id: config.id, status: status, errorMessage: errorMessage)
        }

        return AccountState(
            id: config.id,
            email: "\(config.id)@example.com",
            planType: "team",
            usedPercent: usedPercents[config.id] ?? 20,
            resetAt: Self.resetDate,
            lastUpdated: Self.updatedDate,
            status: .normal
        )
    }
}

private actor CoalescingLoader {
    private var started = false
    private var released = false
    private var calls = 0

    func load(_ config: AccountConfig) async -> AccountState {
        calls += 1
        started = true
        while !released {
            await Task.yield()
        }
        return AccountState(id: config.id, usedPercent: 20, status: .normal)
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func release() {
        released = true
    }

    func callCount() -> Int { calls }
}
