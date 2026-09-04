import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

@MainActor
final class DualQuotaTests: XCTestCase {
    func testAccountStateKeepsPrimaryFiveHourAndSecondaryOverallValuesAndResets() throws {
        let primaryReset = Date(timeIntervalSince1970: 1_700_000_000)
        let secondaryReset = Date(timeIntervalSince1970: 1_700_001_000)
        let original = AccountState(
            id: "C1",
            primaryUsedPercent: 20,
            secondaryUsedPercent: 60,
            primaryResetAt: primaryReset,
            secondaryResetAt: secondaryReset,
            status: .normal
        )

        XCTAssertEqual(original.primaryRemainingPercent, 80)
        XCTAssertEqual(original.secondaryRemainingPercent, 40)
        XCTAssertEqual(original.fiveHourRemainingPercent, 80)
        XCTAssertEqual(original.overallRemainingPercent, 40)
        XCTAssertEqual(original.primaryResetAt, primaryReset)
        XCTAssertEqual(original.secondaryResetAt, secondaryReset)

        let decoded = try JSONDecoder().decode(
            AccountState.self,
            from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.primaryResetAt, primaryReset)
        XCTAssertEqual(decoded.secondaryResetAt, secondaryReset)
    }

    func testCodexQuotaServiceMapsPrimaryToFiveHourAndSecondaryToOverall() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("auth.json"))

        let primaryReset = 1_700_000_000.0
        let secondaryReset = 1_700_001_000.0
        let transport = DualQuotaRecordingTransport(responses: [
            0: CodexMessage(id: 0, result: .object([:])),
            1: CodexMessage(id: 1, result: .object([:])),
            2: CodexMessage(
                id: 2,
                result: .object([
                    "rateLimits": .object([
                        "primary": .object([
                            "usedPercent": .number(20),
                            "resetsAt": .number(primaryReset),
                        ]),
                        "secondary": .object([
                            "usedPercent": .number(60),
                            "resetsAt": .number(secondaryReset),
                        ]),
                    ])
                ])
            ),
        ])
        let service = CodexQuotaService(
            locator: DualQuotaFixedLocator(url: directory.appendingPathComponent("codex")),
            processFactory: { transport }
        )
        let config = AccountConfig(id: "C1", home: directory, position: .left)

        guard case let .success(quota) = service.fetchSync(for: config) else {
            return XCTFail("Expected a successful dual quota result")
        }

        XCTAssertEqual(quota.primaryUsedPercent, 20)
        XCTAssertEqual(quota.primaryRemainingPercent, 80)
        XCTAssertEqual(quota.secondaryUsedPercent, 60)
        XCTAssertEqual(quota.secondaryRemainingPercent, 40)
        XCTAssertEqual(quota.primaryResetAt, Date(timeIntervalSince1970: primaryReset))
        XCTAssertEqual(quota.secondaryResetAt, Date(timeIntervalSince1970: secondaryReset))
    }

    func testMissingSecondaryKeepsFiveHourValueButLeavesOverallUnavailable() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("auth.json"))

        let transport = DualQuotaRecordingTransport(responses: [
            0: CodexMessage(id: 0, result: .object([:])),
            1: CodexMessage(id: 1, result: .object([:])),
            2: CodexMessage(
                id: 2,
                result: .object([
                    "rateLimits": .object([
                        "primary": .object(["usedPercent": .number(20)])
                    ])
                ])
            ),
        ])
        let service = CodexQuotaService(
            locator: DualQuotaFixedLocator(url: directory.appendingPathComponent("codex")),
            processFactory: { transport }
        )
        let config = AccountConfig(id: "C1", home: directory, position: .left)

        let state = service.stateSync(for: config)

        XCTAssertEqual(state.status, .normal)
        XCTAssertEqual(state.primaryRemainingPercent, 80)
        XCTAssertNil(state.secondaryRemainingPercent)
        XCTAssertNil(state.overallRemainingPercent)
        XCTAssertEqual(QuotaDonutPresentation(account: state).centerPercent, 80)
        XCTAssertNil(QuotaDonutPresentation(account: state).ringPercent)
    }

    func testDonutUsesFiveHourValueInCenterAndOverallValueForRingAndColor() {
        let account = AccountState(
            id: "C1",
            primaryUsedPercent: 20,
            secondaryUsedPercent: 60,
            status: .normal
        )

        let presentation = QuotaDonutPresentation(account: account)

        XCTAssertEqual(presentation.centerPercent, 80)
        XCTAssertEqual(presentation.ringPercent, 40)
        XCTAssertEqual(presentation.ringColor, QuotaColors.color(for: 40))
        XCTAssertEqual(QuotaDonutState(account: account).percent, 40)
    }

    func testRateLimitsByIDOnlyResponseStillParsesBothCodexQuotas() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("auth.json"))

        let transport = DualQuotaRecordingTransport(responses: [
            0: CodexMessage(id: 0, result: .object([:])),
            1: CodexMessage(id: 1, result: .object([:])),
            2: CodexMessage(
                id: 2,
                result: .object([
                    "rateLimitsByLimitId": .object([
                        "codex": .object([
                            "primary": .object(["usedPercent": .number(15)]),
                            "secondary": .object(["usedPercent": .number(55)]),
                        ])
                    ])
                ])
            ),
        ])
        let service = CodexQuotaService(
            locator: DualQuotaFixedLocator(url: directory.appendingPathComponent("codex")),
            processFactory: { transport }
        )
        let config = AccountConfig(id: "C1", home: directory, position: .left)

        guard case let .success(quota) = service.fetchSync(for: config) else {
            return XCTFail("Expected by-ID-only quota response to succeed")
        }
        XCTAssertEqual(quota.primaryRemainingPercent, 85)
        XCTAssertEqual(quota.secondaryRemainingPercent, 45)
    }

    func testLegacyQuotaAssignmentsKeepCenterAndRingInSync() {
        var account = AccountState(id: "C1", usedPercent: 20, status: .normal)

        account.usedPercent = 35
        XCTAssertEqual(QuotaDonutPresentation(account: account).centerPercent, 65)
        XCTAssertEqual(QuotaDonutPresentation(account: account).ringPercent, 65)

        account.remainingPercent = 25
        XCTAssertEqual(QuotaDonutPresentation(account: account).centerPercent, 25)
        XCTAssertEqual(QuotaDonutPresentation(account: account).ringPercent, 25)
    }

    func testQuotaSnapshotRestoresBothQuotasAndAccountStorePreservesBothOnError() async throws {
        let defaults = UserDefaults(suiteName: "CodexQuotaMonitorTests.\(UUID().uuidString)")!
        let preferences = PreferencesStore(userDefaults: defaults)
        let configs = (1...4).map { index in
            AccountConfig(
                id: "C\(index)",
                home: URL(fileURLWithPath: "/tmp/dual-quota-\(index)"),
                position: index <= 2 ? .left : .right
            )
        }
        let primaryReset = Date(timeIntervalSince1970: 1_700_000_000)
        let secondaryReset = Date(timeIntervalSince1970: 1_700_001_000)
        let loader = DualQuotaStateLoader()
        let store = AccountStore(configs: configs, preferencesStore: preferences) { config in
            try await loader.load(config)
        }

        await store.refresh(accountID: "C1")
        let reloadedPreferences = PreferencesStore(userDefaults: defaults)
        let snapshot = reloadedPreferences.quotaSnapshot(for: configs[0].home)
        XCTAssertEqual(snapshot?.primaryRemainingPercent, 80)
        XCTAssertEqual(snapshot?.secondaryRemainingPercent, 40)
        XCTAssertEqual(snapshot?.primaryResetAt, primaryReset)
        XCTAssertEqual(snapshot?.secondaryResetAt, secondaryReset)

        await loader.failNext()
        await store.refresh(accountID: "C1")
        let stale = store.state(for: "C1")
        XCTAssertEqual(stale?.status, .error)
        XCTAssertEqual(stale?.primaryRemainingPercent, 80)
        XCTAssertEqual(stale?.secondaryRemainingPercent, 40)
        XCTAssertEqual(stale?.primaryResetAt, primaryReset)
        XCTAssertEqual(stale?.secondaryResetAt, secondaryReset)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct DualQuotaFixedLocator: CodexLocating {
    let url: URL?

    func locate() -> URL? { url }
}

private final class DualQuotaRecordingTransport: CodexProcessTransport, @unchecked Sendable {
    let responses: [Int: CodexMessage]

    init(responses: [Int: CodexMessage]) {
        self.responses = responses
    }

    func launch(executable: URL, home: URL) throws {}
    func send(_ request: CodexRequest) throws {}

    func readResponses(for ids: Set<Int>, until deadline: Date) throws -> [Int: CodexMessage] {
        responses.filter { ids.contains($0.key) }
    }

    func terminate() {}
}

private actor DualQuotaStateLoader {
    private var shouldFail = false

    func failNext() {
        shouldFail = true
    }

    func load(_ config: AccountConfig) throws -> AccountState {
        if shouldFail {
            shouldFail = false
            throw DualQuotaLoaderError.failed
        }
        return AccountState(
            id: config.id,
            primaryUsedPercent: 20,
            secondaryUsedPercent: 60,
            primaryResetAt: Date(timeIntervalSince1970: 1_700_000_000),
            secondaryResetAt: Date(timeIntervalSince1970: 1_700_001_000),
            status: .normal
        )
    }
}

private enum DualQuotaLoaderError: Error {
    case failed
}
