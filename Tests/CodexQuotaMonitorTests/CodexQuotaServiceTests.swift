import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

final class CodexQuotaServiceTests: XCTestCase {
    /// 서버 토큰 조회의 초기화·무인자 요청 및 기존 할당량 요청과의 분리 검증
    func testAccountTokenUsageRequestAndUnsupportedRPC() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("auth.json"))
        for response in [
            CodexMessage(id: 4, result: .object(["summary": .object(["lifetimeTokens": .number(123)]),
                "dailyUsageBuckets": .array([.object(["startDate": .string("2026-10-23"), "tokens": .number(0)])])])),
            CodexMessage(id: 4, error: CodexProtocolError(code: -32601, message: "Method not found")),
        ] {
            let transport = RecordingTransport(responses: [0: CodexMessage(id: 0, result: .object([:])),
                1: CodexMessage(id: 1, result: .object(["account": .object(["email": .string("test@example.test")])])), 4: response])
            let service = CodexQuotaService(locator: FixedCodexLocator(url: directory.appendingPathComponent("codex")),
                                            processFactory: { transport })
            let result = service.fetchTokenUsageSync(for: AccountConfig(id: "C1", home: directory, position: .left))
            if response.error == nil {
                XCTAssertEqual(try result.get().lifetimeTokens, 123)
                XCTAssertEqual(try result.get().accountEmail, "test@example.test")
                XCTAssertEqual(try result.get().days?.first?.tokens, 0)
            } else {
                XCTAssertEqual(result, .failure(.protocolError("Method not found")))
            }
            XCTAssertEqual(transport.sentRequests.map(\.method), ["initialize", "initialized", "account/read", "account/usage/read"])
            XCTAssertNil(transport.sentRequests.last?.params)
            XCTAssertEqual(transport.readIDs, [[0], [1, 4]])
        }
    }

    /// 선택 리셋권·재시도 키 전송 및 서버 결과 4종 구분 검증
    func testResetCreditConsumptionUsesSelectedIDAndIdempotencyKey() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("auth.json"))
        for outcome in [ResetCreditOutcome.reset, .nothingToReset, .noCredit, .alreadyRedeemed] {
            let transport = RecordingTransport(responses: [
                0: CodexMessage(id: 0, result: .object([:])),
                3: CodexMessage(id: 3, result: .object(["outcome": .string(outcome.rawValue)])),
            ])
            let service = CodexQuotaService(
                locator: FixedCodexLocator(url: directory.appendingPathComponent("codex")),
                processFactory: { transport }
            )
            XCTAssertEqual(service.consumeResetCreditSync(
                for: AccountConfig(id: "C1", home: directory, position: .left),
                creditID: "selected-credit", idempotencyKey: "same-attempt"
            ), .success(outcome))
            XCTAssertEqual(transport.sentRequests.map(\.method), [
                "initialize", "initialized", "account/rateLimitResetCredit/consume",
            ])
            XCTAssertEqual(transport.sentRequests.last?.params, .object([
                "creditId": .string("selected-credit"), "idempotencyKey": .string("same-attempt"),
            ]))
            XCTAssertEqual(transport.readIDs, [[0], [3]])
        }
    }

    /// 서버 오류·미지원·알 수 없는 응답을 성공으로 오인하지 않는 경계 검증
    func testResetCreditConsumptionRejectsErrorsAndUnknownOutcome() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("auth.json"))
        for response in [
            CodexMessage(id: 3, error: CodexProtocolError(code: -32601, message: "Method not found")),
            CodexMessage(id: 3, result: .object(["outcome": .string("unknown")])),
        ] {
            let transport = RecordingTransport(responses: [
                0: CodexMessage(id: 0, result: .object([:])), 3: response,
            ])
            let service = CodexQuotaService(
                locator: FixedCodexLocator(url: directory.appendingPathComponent("codex")),
                processFactory: { transport }
            )
            if case .success = service.consumeResetCreditSync(
                for: AccountConfig(id: "C1", home: directory, position: .left),
                creditID: "selected-credit", idempotencyKey: "same-attempt"
            ) { XCTFail("실패 또는 미확인 응답의 성공 처리") }
            XCTAssertEqual(transport.sentRequests.filter { $0.method.hasSuffix("/consume") }.count, 1)
        }
    }

    /// 서버 리셋권 응답의 계정 상태 전달 및 일부 상세에서도 통합 개수 유지 확인
    func testRateLimitResetCreditsReachAccountState() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("auth.json"))
        let transport = RecordingTransport(responses: [
            0: CodexMessage(id: 0, result: .object([:])),
            1: CodexMessage(id: 1, result: .object([:])),
            2: CodexMessage(id: 2, result: .object([
                "rateLimits": .object(["primary": .object(["usedPercent": .number(20)])]),
                "rateLimitResetCredits": .object([
                    "availableCount": .number(2),
                    "credits": .array([.object([
                        "id": .string("credit-1"), "status": .string("available"),
                        "expiresAt": .number(1_800_000_000),
                    ])]),
                ]),
            ])),
        ])
        let service = CodexQuotaService(
            locator: FixedCodexLocator(url: directory.appendingPathComponent("codex")),
            processFactory: { transport }
        )
        let state = service.stateSync(for: AccountConfig(id: "C1", home: directory, position: .left))
        XCTAssertEqual(state.status, .normal)
        XCTAssertEqual(state.resetCredits?.availableCount, 2)
        XCTAssertEqual(state.resetCredits?.credits?.first?.expiresAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(state.resetCredits?.hasCompleteDetails, false)
    }

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

    /// 서버 토큰 조회 중 취소 시 transport 대기 해제와 프로세스 종료 검증
    func testTokenUsageCancellationStopsTransport() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("auth.json"))
        let transport = BlockingCancellationTransport()
        let service = CodexQuotaService(locator: FixedCodexLocator(url: directory.appendingPathComponent("codex")),
                                        processFactory: { transport })
        let task = Task { await service.fetchTokenUsage(for: AccountConfig(id: "C1", home: directory, position: .left)) }
        XCTAssertEqual(transport.readStarted.wait(timeout: .now() + 1), .success)
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .failure(.cancelled))
        XCTAssertEqual(transport.cancelCount, 1)
        XCTAssertEqual(transport.terminationCount, 1)
    }

    func testFetchCancellationWakesTransportReadAndReturnsCancelled() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("auth.json"))

        let transport = BlockingCancellationTransport()
        let service = CodexQuotaService(
            locator: FixedCodexLocator(url: directory.appendingPathComponent("codex")),
            processFactory: { transport }
        )
        let config = AccountConfig(id: "C1", home: directory, position: .left)
        let task = Task { await service.fetch(for: config) }
        XCTAssertEqual(transport.readStarted.wait(timeout: .now() + 1), .success)

        task.cancel()
        let result = await task.value

        XCTAssertEqual(result, .failure(.cancelled))
        XCTAssertEqual(transport.cancelCount, 1)
        XCTAssertEqual(transport.terminationCount, 1)
    }

    func testStateCancellationStopsTransportAndDoesNotPublishStaleFailure() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("auth.json"))

        let transport = BlockingCancellationTransport()
        let service = CodexQuotaService(
            locator: FixedCodexLocator(url: directory.appendingPathComponent("codex")),
            processFactory: { transport }
        )
        let config = AccountConfig(id: "C1", home: directory, position: .left)
        let task = Task { await service.state(for: config) }
        XCTAssertEqual(transport.readStarted.wait(timeout: .now() + 1), .success)

        task.cancel()
        let state = await task.value

        XCTAssertEqual(state.status, .loading)
        XCTAssertEqual(state.errorMessage, nil)
        XCTAssertEqual(transport.cancelCount, 1)
        XCTAssertEqual(transport.terminationCount, 1)
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

/// 취소 wakeup과 worker 종료를 세마포어로 검증하는 동기 fake transport
private final class BlockingCancellationTransport: CodexProcessTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let cancellation = DispatchSemaphore(value: 0)
    private var didCancel = false
    private var cancellations = 0
    private var terminations = 0
    let readStarted = DispatchSemaphore(value: 0)

    var cancelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancellations
    }

    var terminationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return terminations
    }

    func launch(executable: URL, home: URL) throws {}

    func send(_ request: CodexRequest) throws {}

    func readResponses(for ids: Set<Int>, until deadline: Date) throws -> [Int: CodexMessage] {
        readStarted.signal()
        let remaining = max(0, deadline.timeIntervalSinceNow)
        _ = cancellation.wait(timeout: .now() + remaining)
        lock.lock()
        let wasCancelled = didCancel
        lock.unlock()
        if wasCancelled { throw CodexProcessError.cancelled }
        throw CodexProcessError.timeout
    }

    func cancel() {
        lock.lock()
        didCancel = true
        cancellations += 1
        lock.unlock()
        cancellation.signal()
    }

    func terminate() {
        lock.lock()
        terminations += 1
        lock.unlock()
    }
}
