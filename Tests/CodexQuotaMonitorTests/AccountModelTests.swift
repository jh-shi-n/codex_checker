import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

final class AccountModelTests: XCTestCase {
    func testDefaultAccountsMapHomesAndPositions() {
        let home = URL(fileURLWithPath: "/tmp/codex-home", isDirectory: true)

        let accounts = AccountConfig.defaultAccounts(homeDirectory: home)

        XCTAssertEqual(accounts.map(\.id), ["C1", "C2", "C3", "C4"])
        XCTAssertEqual(accounts.map(\.home.path), [
            "/tmp/codex-home/.codex-1",
            "/tmp/codex-home/.codex-2",
            "/tmp/codex-home/.codex-3",
            "/tmp/codex-home/.codex-4",
        ])
        XCTAssertEqual(accounts.map(\.position), [.left, .left, .right, .right])
    }

    func testEmptyAndWhitespacePathsCreateExplicitUnconfiguredAccounts() {
        let home = URL(fileURLWithPath: "/tmp/codex-config-home", isDirectory: true)

        let accounts = AccountConfig.accounts(
            for: ["", " \t\n", "~/codex-three", "/tmp/codex-four"],
            homeDirectory: home
        )

        XCTAssertEqual(accounts.map(\.id), ["C1", "C2", "C3", "C4"])
        XCTAssertEqual(accounts.map(\.position), [.left, .left, .right, .right])
        XCTAssertFalse(accounts[0].isConfigured)
        XCTAssertFalse(accounts[1].isConfigured)
        XCTAssertNil(accounts[0].configuredHome)
        XCTAssertNil(accounts[1].configuredHome)
        XCTAssertEqual(accounts[2].configuredHome?.path, "/tmp/codex-config-home/codex-three")
        XCTAssertEqual(accounts[3].configuredHome?.path, "/tmp/codex-four")
    }

    func testUnconfiguredAccountConfigRoundTripsWithCodableCompatibility() throws {
        let original = AccountConfig.unconfigured(id: "C2", position: .left)

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AccountConfig.self, from: encoded)

        XCTAssertEqual(decoded, original)
        XCTAssertFalse(decoded.isConfigured)
        XCTAssertNil(decoded.configuredHome)
    }

    func testAccountStateLoadingStartsWithoutQuotaValues() {
        let state = AccountState.loading(id: "C2")

        XCTAssertEqual(state.id, "C2")
        XCTAssertEqual(state.status, .loading)
        XCTAssertNil(state.email)
        XCTAssertNil(state.usedPercent)
        XCTAssertNil(state.remainingPercent)
        XCTAssertNil(state.lastUpdated)
    }

    func testAccountStateNotConfiguredStartsWithoutQuotaValues() {
        let state = AccountState.notConfigured(id: "C2")

        XCTAssertEqual(state.id, "C2")
        XCTAssertEqual(state.status, .notConfigured)
        XCTAssertNil(state.email)
        XCTAssertNil(state.usedPercent)
        XCTAssertNil(state.remainingPercent)
        XCTAssertNil(state.resetAt)
        XCTAssertNil(state.lastUpdated)
    }

    func testAccountStateClampsRemainingQuota() {
        let lower = AccountState(
            id: "C1",
            usedPercent: 140,
            remainingPercent: 0,
            status: .normal
        )
        let upper = AccountState(
            id: "C1",
            usedPercent: -10,
            remainingPercent: 100,
            status: .normal
        )

        XCTAssertEqual(lower.remainingPercent, 0)
        XCTAssertEqual(upper.remainingPercent, 100)
    }

    func testAccountStateUsesFiniteComplementPolicyAtInitialization() {
        let cases: [(Double, Double, Double)] = [
            (.nan, 0, 100),
            (.infinity, 100, 0),
            (-.infinity, 0, 100),
            (-25, 0, 100),
            (125, 100, 0),
        ]

        for (input, expectedUsed, expectedRemaining) in cases {
            let state = AccountState(
                id: "C1",
                usedPercent: input,
                status: .normal
            )

            XCTAssertEqual(state.usedPercent, expectedUsed)
            XCTAssertEqual(state.remainingPercent, expectedRemaining)
        }
    }

    func testAccountStateKeepsFiniteComplementAfterPublicAssignments() {
        var state = AccountState(
            id: "C1",
            usedPercent: 50,
            status: .normal
        )

        state.remainingPercent = .nan
        XCTAssertEqual(state.remainingPercent, 0)
        XCTAssertEqual(state.usedPercent, 100)

        state.remainingPercent = .infinity
        XCTAssertEqual(state.remainingPercent, 100)
        XCTAssertEqual(state.usedPercent, 0)

        state.usedPercent = -.infinity
        XCTAssertEqual(state.usedPercent, 0)
        XCTAssertEqual(state.remainingPercent, 100)

        state.usedPercent = 125
        XCTAssertEqual(state.usedPercent, 100)
        XCTAssertEqual(state.remainingPercent, 0)
    }

    func testAccountStateNormalAndClampedValuesRoundTripThroughJSON() throws {
        let normal = AccountState(
            id: "C1",
            email: "user@example.com",
            planType: "team",
            usedPercent: 16,
            resetAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_100),
            status: .normal
        )
        let clamped = AccountState(
            id: "C2",
            usedPercent: .nan,
            status: .normal
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let normalDecoded = try decoder.decode(AccountState.self, from: encoder.encode(normal))
        let clampedDecoded = try decoder.decode(AccountState.self, from: encoder.encode(clamped))

        XCTAssertEqual(normalDecoded, normal)
        XCTAssertEqual(normalDecoded.remainingPercent, 84)
        XCTAssertEqual(clampedDecoded, AccountState(id: "C2", usedPercent: 0, status: .normal))
        XCTAssertEqual(clampedDecoded.usedPercent, 0)
        XCTAssertEqual(clampedDecoded.remainingPercent, 100)
    }

    func testAccountStateJSONUsesUsedPercentAsDocumentedConflictPrecedence() throws {
        let payload = Data(
            "{\"id\":\"C1\",\"usedPercent\":25,\"remainingPercent\":90,\"status\":\"normal\"}".utf8
        )

        let state = try JSONDecoder().decode(AccountState.self, from: payload)

        XCTAssertEqual(state.usedPercent, 25)
        XCTAssertEqual(state.remainingPercent, 75)
    }

    func testStatesThatNormalizeToTheSameValuesAreEqual() {
        let clamped = AccountState(id: "C1", usedPercent: -10, status: .normal)
        let equivalent = AccountState(
            id: "C1",
            usedPercent: 0,
            remainingPercent: 100,
            status: .normal
        )

        XCTAssertEqual(clamped, equivalent)
    }
}
