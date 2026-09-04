import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

final class CodexQuotaServiceTests: XCTestCase {
    func testLocatorPrefersPathBeforeFallbackLocations() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pathCodex = directory.appendingPathComponent("codex")
        try Data("#!/bin/sh\n".utf8).write(to: pathCodex)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: pathCodex.path
        )

        let locator = CodexLocator(
            pathEnvironment: directory.path,
            candidatePaths: [URL(fileURLWithPath: "/does/not/exist/codex")]
        )

        XCTAssertEqual(locator.locate(), pathCodex.standardizedFileURL)
    }

    func testMissingAuthReturnsLoginRequiredWithoutLaunchingProcess() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let locator = FixedCodexLocator(url: directory.appendingPathComponent("codex"))
        let transport = RecordingTransport()
        let service = CodexQuotaService(locator: locator, processFactory: { transport })
        let config = AccountConfig(id: "C1", home: directory, position: .left)

        let result = service.fetchSync(for: config)

        XCTAssertEqual(result, .failure(.loginRequired))
        XCTAssertEqual(transport.launchCount, 0)
    }

    func testUnconfiguredAccountReturnsExplicitStateWithoutReadingAuthOrLaunchingProcess() {
        let transport = RecordingTransport()
        let service = CodexQuotaService(
            locator: FixedCodexLocator(url: URL(fileURLWithPath: "/tmp/should-not-be-used")),
            processFactory: { transport }
        )
        let config = AccountConfig.unconfigured(id: "C1", position: .left)

        XCTAssertEqual(service.fetchSync(for: config), .failure(.notConfigured))
        XCTAssertEqual(service.stateSync(for: config), AccountState.notConfigured(id: "C1"))
        XCTAssertEqual(transport.launchCount, 0)
    }

    func testSuccessfulQueryWaitsForInitializeThenReadsBothAccountResponses() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("auth.json"))

        let locator = FixedCodexLocator(url: directory.appendingPathComponent("codex"))
        let transport = RecordingTransport(responses: [
            0: CodexMessage(id: 0, result: .object([:])),
            1: CodexMessage(
                id: 1,
                result: .object([
                    "account": .object([
                        "email": .string("user@example.com"),
                        "planType": .string("team"),
                    ])
                ])
            ),
            2: CodexMessage(
                id: 2,
                result: .object([
                    "rateLimits": .object([
                        "primary": .object([
                            "usedPercent": .number(16),
                            "resetsAt": .number(1_786_868_452),
                        ])
                    ])
                ])
            ),
        ])
        let service = CodexQuotaService(locator: locator, processFactory: { transport })
        let config = AccountConfig(id: "C1", home: directory, position: .left)

        let result = service.fetchSync(for: config)

        guard case let .success(quota) = result else {
            return XCTFail("Expected a successful quota result, got \(result)")
        }
        XCTAssertEqual(quota.email, "user@example.com")
        XCTAssertEqual(quota.planType, "team")
        XCTAssertEqual(quota.usedPercent, 16)
        XCTAssertEqual(quota.remainingPercent, 84)
        XCTAssertEqual(transport.launchCount, 1)
        XCTAssertEqual(transport.sentRequests.map(\.method), [
            "initialize",
            "initialized",
            "account/read",
            "account/rateLimits/read",
        ])
        XCTAssertEqual(transport.readIDs, [[0], [1, 2]])
    }

    func testProtocolErrorIsMappedWithoutOpeningBrowserLogin() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("auth.json"))

        let locator = FixedCodexLocator(url: directory.appendingPathComponent("codex"))
        let transport = RecordingTransport(responses: [
            0: CodexMessage(id: 0, result: .object([:])),
            1: CodexMessage(
                id: 1,
                error: CodexProtocolError(code: -1, message: "account unavailable")
            ),
            2: CodexMessage(id: 2, result: .object([:])),
        ])
        let service = CodexQuotaService(locator: locator, processFactory: { transport })
        let config = AccountConfig(id: "C1", home: directory, position: .left)

        let result = service.fetchSync(for: config)

        guard case let .failure(error) = result else {
            return XCTFail("Expected protocol failure, got \(result)")
        }
        guard case let .protocolError(message) = error else {
            return XCTFail("Expected protocol error, got \(error)")
        }
        XCTAssertEqual(message, "account unavailable")
    }

    func testMissingBinaryIsMappedWithoutLaunchingProcess() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("auth.json"))

        let transport = RecordingTransport()
        let service = CodexQuotaService(
            locator: FixedCodexLocator(url: nil),
            processFactory: { transport }
        )
        let config = AccountConfig(id: "C1", home: directory, position: .left)

        XCTAssertEqual(service.fetchSync(for: config), .failure(.codexNotFound))
        XCTAssertEqual(transport.launchCount, 0)
    }

    func testMissingResponseIsMappedToTimeout() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("auth.json"))

        let transport = RecordingTransport()
        let service = CodexQuotaService(
            locator: FixedCodexLocator(url: directory.appendingPathComponent("codex")),
            processFactory: { transport }
        )
        let config = AccountConfig(id: "C1", home: directory, position: .left)

        XCTAssertEqual(service.fetchSync(for: config), .failure(.timeout))
    }

    func testInitializeTimeoutIsMappedBeforeFollowUpRequestsAreSent() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("auth.json"))

        let transport = RecordingTransport(responsesByRequestIDs: [
            Set([0]): [:],
            Set([1, 2]): [
                1: CodexMessage(id: 1, result: .object([:])),
                2: CodexMessage(id: 2, result: .object([:])),
            ],
        ])
        let service = CodexQuotaService(
            locator: FixedCodexLocator(url: directory.appendingPathComponent("codex")),
            processFactory: { transport }
        )
        let config = AccountConfig(id: "C1", home: directory, position: .left)

        XCTAssertEqual(service.fetchSync(for: config), .failure(.timeout))
        XCTAssertEqual(transport.sentRequests.map(\.method), ["initialize"])
    }

    func testProcessCrashIsMappedToProcessCrashed() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("auth.json"))

        let transport = RecordingTransport(readError: .processExited(17))
        let service = CodexQuotaService(
            locator: FixedCodexLocator(url: directory.appendingPathComponent("codex")),
            processFactory: { transport }
        )
        let config = AccountConfig(id: "C1", home: directory, position: .left)

        XCTAssertEqual(service.fetchSync(for: config), .failure(.processCrashed(17)))
    }

    func testLaunchFailurePreservesTransportMessageInsteadOfNotFound() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("auth.json"))

        let transport = RecordingTransport(launchError: .launchFailed("permission denied"))
        let service = CodexQuotaService(
            locator: FixedCodexLocator(url: directory.appendingPathComponent("codex")),
            processFactory: { transport }
        )
        let config = AccountConfig(id: "C1", home: directory, position: .left)

        XCTAssertEqual(
            service.fetchSync(for: config),
            .failure(.transport("permission denied"))
        )
    }

    func testIncompleteRateLimitPayloadIsMappedToMalformedResponse() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("auth.json"))

        let transport = RecordingTransport(responses: [
            0: CodexMessage(id: 0, result: .object([:])),
            1: CodexMessage(id: 1, result: .object([:])),
            2: CodexMessage(id: 2, result: .object(["rateLimits": .object([:])])),
        ])
        let service = CodexQuotaService(
            locator: FixedCodexLocator(url: directory.appendingPathComponent("codex")),
            processFactory: { transport }
        )
        let config = AccountConfig(id: "C1", home: directory, position: .left)

        guard case let .failure(error) = service.fetchSync(for: config) else {
            return XCTFail("Expected malformed-response failure")
        }
        guard case .malformedResponse = error else {
            return XCTFail("Expected malformed response, got \(error)")
        }
    }

    func testRateLimitsFallsBackToCodexBucketWhenHistoricalPrimaryIsNull() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("auth.json"))

        let resetAt = 1_786_868_452.0
        let transport = RecordingTransport(responses: [
            0: CodexMessage(id: 0, result: .object([:])),
            1: CodexMessage(
                id: 1,
                result: .object([
                    "account": .object(["planType": .string("team")]),
                ])
            ),
            2: CodexMessage(
                id: 2,
                result: .object([
                    "rateLimits": .object(["primary": .null]),
                    "rateLimitsByLimitId": .object([
                        "codex": .object([
                            "primary": .object([
                                "usedPercent": .number(37),
                                "resetsAt": .number(resetAt),
                            ]),
                        ]),
                        "other": .object([
                            "primary": .object(["usedPercent": .number(99)]),
                        ]),
                    ]),
                ])
            ),
        ])
        let service = CodexQuotaService(
            locator: FixedCodexLocator(url: directory.appendingPathComponent("codex")),
            processFactory: { transport }
        )
        let config = AccountConfig(id: "C1", home: directory, position: .left)

        guard case let .success(quota) = service.fetchSync(for: config) else {
            return XCTFail("Expected a successful quota result")
        }
        XCTAssertEqual(quota.planType, "team")
        XCTAssertEqual(quota.usedPercent, 37)
        XCTAssertEqual(quota.remainingPercent, 63)
        XCTAssertEqual(quota.resetAt, Date(timeIntervalSince1970: resetAt))
    }

    func testCodexQuotaUsesFiniteComplementPolicy() {
        let nan = CodexQuota(usedPercent: .nan)
        let positiveInfinity = CodexQuota(usedPercent: .infinity)
        let negativeInfinity = CodexQuota(usedPercent: -.infinity)

        XCTAssertEqual(nan.usedPercent, 0)
        XCTAssertEqual(nan.remainingPercent, 100)
        XCTAssertEqual(positiveInfinity.usedPercent, 100)
        XCTAssertEqual(positiveInfinity.remainingPercent, 0)
        XCTAssertEqual(negativeInfinity.usedPercent, 0)
        XCTAssertEqual(negativeInfinity.remainingPercent, 100)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct FixedCodexLocator: CodexLocating {
    let url: URL?

    func locate() -> URL? { url }
}

private final class RecordingTransport: CodexProcessTransport, @unchecked Sendable {
    let responses: [Int: CodexMessage]
    let responsesByRequestIDs: [Set<Int>: [Int: CodexMessage]]
    let launchError: CodexProcessError?
    let readError: CodexProcessError?
    private(set) var launchCount = 0
    private(set) var sentRequests: [CodexRequest] = []
    private(set) var readIDs: [[Int]] = []

    init(
        responses: [Int: CodexMessage] = [:],
        responsesByRequestIDs: [Set<Int>: [Int: CodexMessage]] = [:],
        launchError: CodexProcessError? = nil,
        readError: CodexProcessError? = nil
    ) {
        self.responses = responses
        self.responsesByRequestIDs = responsesByRequestIDs
        self.launchError = launchError
        self.readError = readError
    }

    func launch(executable: URL, home: URL) throws {
        launchCount += 1
        if let launchError { throw launchError }
    }

    func send(_ request: CodexRequest) throws {
        sentRequests.append(request)
    }

    func readResponses(for ids: Set<Int>, until deadline: Date) throws -> [Int: CodexMessage] {
        readIDs.append(ids.sorted())
        if let readError { throw readError }
        if let responses = responsesByRequestIDs[ids] { return responses }
        return responses.filter { ids.contains($0.key) }
    }

    func terminate() {}
}
