import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

final class UsageWindowProbeTests: XCTestCase {
    private let executableURL = URL(fileURLWithPath: "/test/bin/codex")
    private let accountHome = URL(fileURLWithPath: "/test/accounts/c1", isDirectory: true)

    func testCommandBuilderUsesExactReadOnlyLunaContract() {
        let command = UsageWindowProbeCommandBuilder().build(
            executable: executableURL,
            configuredAccountHome: accountHome
        )

        XCTAssertEqual(command.executableURL, executableURL.standardizedFileURL)
        XCTAssertEqual(command.arguments, [
            "exec",
            "--ephemeral",
            "--skip-git-repo-check",
            "--ignore-rules",
            "--ignore-user-config",
            "--sandbox",
            "read-only",
            "--model",
            "gpt-5.6-luna",
            "-c",
            "model_reasoning_effort=\"low\"",
            "--json",
            "print 1",
        ])
        XCTAssertEqual(command.environmentOverrides, [
            "CODEX_HOME": accountHome.standardizedFileURL.path,
        ])
        XCTAssertNil(command.currentDirectoryURL)
        XCTAssertEqual(command.metadata.displayName, "Luna Light")
        XCTAssertEqual(command.metadata.modelIdentifier, "gpt-5.6-luna")
        XCTAssertEqual(command.metadata.sandbox, "read-only")
        XCTAssertTrue(command.metadata.isEphemeral)
        XCTAssertTrue(command.metadata.skipsGitRepositoryCheck)
        XCTAssertTrue(command.metadata.ignoresRules)
    }

    func testExecutionIsolationContainsOnlyAuthLinkAndEmptyWorkingDirectory() throws {
        let fileManager = FileManager.default
        let configuredHome = fileManager.temporaryDirectory
            .appendingPathComponent("usage-window-configured-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: configuredHome, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: configuredHome) }

        let sourceAuthURL = configuredHome.appendingPathComponent("auth.json")
        XCTAssertTrue(fileManager.createFile(atPath: sourceAuthURL.path, contents: Data("dummy auth".utf8)))

        let isolation = try UsageWindowProbeExecutionIsolation.create(
            configuredAccountHome: configuredHome,
            fileManager: fileManager
        )
        defer { try? isolation.cleanup(fileManager: fileManager) }

        XCTAssertFalse(
            isolation.rootURL.path == configuredHome.path ||
                isolation.rootURL.path.hasPrefix(configuredHome.path + "/")
        )
        if let permissions = try fileManager.attributesOfItem(atPath: isolation.rootURL.path)[.posixPermissions] as? NSNumber {
            XCTAssertEqual(permissions.intValue & 0o777, 0o700)
        }

        let rootContents = try fileManager.contentsOfDirectory(
            at: isolation.rootURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        XCTAssertEqual(Set(rootContents.map(\.lastPathComponent)), ["codex-home", "working-directory"])

        let codexHomeContents = try fileManager.contentsOfDirectory(
            at: isolation.codexHomeURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        XCTAssertEqual(codexHomeContents.map(\.lastPathComponent), ["auth.json"])
        let isolatedAuthURL = isolation.codexHomeURL.appendingPathComponent("auth.json")
        XCTAssertEqual(
            try fileManager.destinationOfSymbolicLink(atPath: isolatedAuthURL.path),
            sourceAuthURL.path
        )

        let workingDirectoryContents = try fileManager.contentsOfDirectory(
            at: isolation.workingDirectoryURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        XCTAssertTrue(workingDirectoryContents.isEmpty)

        let forbiddenNames = [
            "AGENTS.md", ".md", "config.toml", "sessions", "history", "memory",
            "plugins", "mcp", "skills",
        ]
        for name in forbiddenNames {
            XCTAssertFalse(fileManager.fileExists(atPath: isolation.codexHomeURL.appendingPathComponent(name).path))
            XCTAssertFalse(fileManager.fileExists(atPath: isolation.workingDirectoryURL.appendingPathComponent(name).path))
        }

        try isolation.cleanup(fileManager: fileManager)
        XCTAssertFalse(fileManager.fileExists(atPath: isolation.rootURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: sourceAuthURL.path))
        try isolation.cleanup(fileManager: fileManager)
    }

    func testUnconfiguredAccountDoesNotInspectAuthOrLaunch() async {
        let fileSystem = RecordingFileSystem(metadata: .init(exists: true))
        let locator = RecordingLocator(url: executableURL)
        let runner = RecordingRunner(result: .init(exitStatus: 0))
        let service = UsageWindowProbeService(
            fileSystem: fileSystem.seam,
            executableLocator: locator,
            processRunner: runner
        )

        let result = await service.probe(.unconfigured(id: "C1", position: .left))

        XCTAssertEqual(result.status, .failure)
        XCTAssertEqual(result.failureCategory, .notConfigured)
        XCTAssertEqual(fileSystem.metadataCalls, 0)
        XCTAssertEqual(locator.calls, 0)
        XCTAssertEqual(runner.calls, 0)
    }

    func testMissingAuthenticationUsesMetadataOnly() async {
        let fileSystem = RecordingFileSystem(metadata: .init(exists: false))
        let locator = RecordingLocator(url: executableURL)
        let runner = RecordingRunner(result: .init(exitStatus: 0))
        let service = makeService(fileSystem: fileSystem, locator: locator, runner: runner)

        let result = await service.probe(config())

        XCTAssertEqual(result.failureCategory, .missingAuthentication)
        XCTAssertEqual(fileSystem.metadataCalls, 1)
        XCTAssertEqual(fileSystem.lastPath, config().authFile.path)
        XCTAssertEqual(locator.calls, 0)
        XCTAssertEqual(runner.calls, 0)
    }

    func testMissingExecutableDoesNotLaunch() async {
        let fileSystem = RecordingFileSystem(metadata: .init(exists: true))
        let locator = RecordingLocator(url: nil)
        let runner = RecordingRunner(result: .init(exitStatus: 0))
        let service = makeService(fileSystem: fileSystem, locator: locator, runner: runner)

        let result = await service.probe(config())

        XCTAssertEqual(result.failureCategory, .executableUnavailable)
        XCTAssertEqual(locator.calls, 1)
        XCTAssertEqual(runner.calls, 0)
    }

    func testSuccessParsesCommonUsageDictionaryAndDates() async {
        let output = Data(
            "{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":12,\"output_tokens\":7,\"total_tokens\":19}}\n".utf8
        )
        let fileSystem = RecordingFileSystem(metadata: .init(exists: true))
        let runner = RecordingRunner(result: .init(exitStatus: 0, stdout: output))
        let service = makeService(fileSystem: fileSystem, locator: RecordingLocator(url: executableURL), runner: runner)

        let result = await service.probe(config())

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.usage, UsageWindowProbeTokenUsage(inputTokens: 12, outputTokens: 7, totalTokens: 19))
        XCTAssertLessThanOrEqual(result.startedAt, result.completedAt)
        XCTAssertNil(result.failureCategory)
        let state = await service.state(for: "C1")
        XCTAssertEqual(state.status, .success)
        XCTAssertEqual(state.usage, result.usage)
    }

    func testZeroExitWithoutUsageIsSuccessfulWithNilUsage() async {
        let output = Data("{\"type\":\"turn.completed\"}\n".utf8)
        let runner = RecordingRunner(result: .init(exitStatus: 0, stdout: output))
        let service = makeService(
            fileSystem: RecordingFileSystem(metadata: .init(exists: true)),
            locator: RecordingLocator(url: executableURL),
            runner: runner
        )

        let result = await service.probe(config())

        XCTAssertTrue(result.isSuccess)
        XCTAssertNil(result.usage)
    }

    func testFailureDoesNotSurfaceRawProcessOutput() async {
        let secret = "secret-local-path-and-cli-text"
        let runner = RecordingRunner(result: .init(
            exitStatus: 17,
            stdout: Data("{\"error\":\"\(secret)\"}\n".utf8),
            stderr: Data(secret.utf8)
        ))
        let service = makeService(
            fileSystem: RecordingFileSystem(metadata: .init(exists: true)),
            locator: RecordingLocator(url: executableURL),
            runner: runner
        )

        let result = await service.probe(config())

        XCTAssertEqual(result.failureCategory, .nonZeroExit)
        XCTAssertFalse(result.userMessage.contains(secret))
        XCTAssertFalse(result.userMessage.contains("17"))
    }

    func testUnsupportedModelFromBoundedStderrGetsSafeCategory() async {
        let secret = "gpt-5.6-luna /Users/private/account"
        let runner = RecordingRunner(result: .init(
            exitStatus: 1,
            stderr: Data("Error: model gpt-5.6-luna not found at \(secret)\n".utf8)
        ))
        let service = makeService(
            fileSystem: RecordingFileSystem(metadata: .init(exists: true)),
            locator: RecordingLocator(url: executableURL),
            runner: runner
        )

        let result = await service.probe(config())

        XCTAssertEqual(result.failureCategory, .unsupportedModel)
        XCTAssertFalse(result.userMessage.contains(secret))
        XCTAssertFalse(result.userMessage.contains("/Users/private"))
    }

    func testAuthenticationAndRateLimitJSONErrorsStayCategorical() async {
        let output = Data(
            "{\"type\":\"error\",\"error\":{\"message\":\"authentication required\"}}\n".utf8
        )
        let runner = RecordingRunner(result: .init(exitStatus: 1, stdout: output))
        let service = makeService(
            fileSystem: RecordingFileSystem(metadata: .init(exists: true)),
            locator: RecordingLocator(url: executableURL),
            runner: runner
        )

        let result = await service.probe(config())

        XCTAssertEqual(result.failureCategory, .authenticationFailure)
        XCTAssertFalse(result.userMessage.contains("authentication required"))

        let rateOutput = Data("{\"type\":\"error\",\"message\":\"429 too many requests\"}\n".utf8)
        let rateRunner = RecordingRunner(result: .init(exitStatus: 1, stdout: rateOutput))
        let rateService = makeService(
            fileSystem: RecordingFileSystem(metadata: .init(exists: true)),
            locator: RecordingLocator(url: executableURL),
            runner: rateRunner
        )
        let rateResult = await rateService.probe(config())
        XCTAssertEqual(rateResult.failureCategory, .rateLimited)
        XCTAssertFalse(rateResult.userMessage.contains("429"))
    }

    func testRunnerFailureReturnsTerminalResultAndReleasesSameAccountGate() async {
        let runner = RecordingRunner(error: .launchFailure)
        let service = makeService(
            fileSystem: RecordingFileSystem(metadata: .init(exists: true)),
            locator: RecordingLocator(url: executableURL),
            runner: runner
        )

        let first = await service.probe(config())
        let second = await service.probe(config())

        XCTAssertEqual(first.failureCategory, .launchFailure)
        XCTAssertEqual(second.failureCategory, .launchFailure)
        XCTAssertEqual(runner.calls, 2)
        let state = await service.state(for: "C1")
        XCTAssertEqual(state.status, .failure)
    }

    func testTimeoutMapsToSafeTimeoutCategory() async {
        let runner = RecordingRunner(error: .timeout)
        let service = makeService(
            fileSystem: RecordingFileSystem(metadata: .init(exists: true)),
            locator: RecordingLocator(url: executableURL),
            runner: runner
        )

        let result = await service.probe(config())

        XCTAssertEqual(result.failureCategory, .timeout)
        XCTAssertEqual(result.userMessage, UsageWindowProbeFailureCategory.timeout.userMessage)
    }

    func testMalformedOnlyOutputIsSafeFailure() async {
        let runner = RecordingRunner(result: .init(exitStatus: 0, stdout: Data("not json\n".utf8)))
        let service = makeService(
            fileSystem: RecordingFileSystem(metadata: .init(exists: true)),
            locator: RecordingLocator(url: executableURL),
            runner: runner
        )

        let result = await service.probe(config())

        XCTAssertEqual(result.failureCategory, .malformedOutput)
        XCTAssertEqual(result.status, .failure)
    }

    func testProcessResultBoundsBothStreams() {
        let stdout = Data(repeating: 0x41, count: UsageWindowProbeProcessResult.maximumStandardOutputBytes + 99)
        let stderr = Data(repeating: 0x42, count: UsageWindowProbeProcessResult.maximumStandardErrorBytes + 99)

        let result = UsageWindowProbeProcessResult(exitStatus: 0, stdout: stdout, stderr: stderr)

        XCTAssertEqual(result.stdout.count, UsageWindowProbeProcessResult.maximumStandardOutputBytes)
        XCTAssertEqual(result.stderr.count, UsageWindowProbeProcessResult.maximumStandardErrorBytes)
    }

    func testSameAccountOverlapIsRejectedWhileFirstCallRuns() async {
        let runner = BlockingRunner(result: .init(exitStatus: 0))
        let service = makeService(
            fileSystem: RecordingFileSystem(metadata: .init(exists: true)),
            locator: RecordingLocator(url: executableURL),
            runner: runner
        )
        let account = config()
        let firstTask = Task { await service.probe(account) }
        XCTAssertEqual(runner.started.wait(timeout: .now() + 1), .success)

        let overlap = await service.probe(account)
        XCTAssertEqual(overlap.failureCategory, .alreadyRunning)
        let callCount = await runner.numberOfCalls()
        XCTAssertEqual(callCount, 1)

        await runner.release()
        let first = await firstTask.value
        XCTAssertTrue(first.isSuccess)
    }

    private func config() -> AccountConfig {
        AccountConfig(id: "C1", home: accountHome, position: .left)
    }

    private func makeService(
        fileSystem: RecordingFileSystem,
        locator: RecordingLocator,
        runner: UsageWindowProbeProcessRunning,
        timeout: TimeInterval = 60
    ) -> UsageWindowProbeService {
        UsageWindowProbeService(
            fileSystem: fileSystem.seam,
            executableLocator: locator,
            processRunner: runner,
            timeout: timeout
        )
    }
}

private final class RecordingFileSystem: @unchecked Sendable {
    private let lock = NSLock()
    private let metadataValue: UsageWindowProbeFileMetadata
    private(set) var metadataCalls = 0
    private(set) var lastPath: String?

    init(metadata: UsageWindowProbeFileMetadata) {
        self.metadataValue = metadata
    }

    var seam: UsageWindowProbeFileSystem {
        UsageWindowProbeFileSystem { [self] url in
            lock.lock()
            metadataCalls += 1
            lastPath = url.path
            lock.unlock()
            return metadataValue
        }
    }
}

private struct RecordingLocator: CodexLocating, @unchecked Sendable {
    let url: URL?
    private let storage: Counter

    init(url: URL?, storage: Counter = Counter()) {
        self.url = url
        self.storage = storage
    }

    var calls: Int { storage.value }

    func locate() -> URL? {
        storage.increment()
        return url
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class RecordingRunner: UsageWindowProbeProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let output: UsageWindowProbeProcessResult?
    private let thrownError: UsageWindowProbeProcessError?
    private(set) var calls = 0
    private(set) var receivedCommands: [UsageWindowProbeCommand] = []

    init(result: UsageWindowProbeProcessResult) {
        self.output = result
        self.thrownError = nil
    }

    init(error: UsageWindowProbeProcessError) {
        self.output = nil
        self.thrownError = error
    }

    func run(
        command: UsageWindowProbeCommand,
        timeout: TimeInterval
    ) async throws -> UsageWindowProbeProcessResult {
        record(command: command)
        if let thrownError { throw thrownError }
        return output!
    }

    private func record(command: UsageWindowProbeCommand) {
        lock.lock()
        calls += 1
        receivedCommands.append(command)
        lock.unlock()
    }
}

private actor BlockingRunner: UsageWindowProbeProcessRunning {
    nonisolated let started = DispatchSemaphore(value: 0)
    private let output: UsageWindowProbeProcessResult
    private var continuation: CheckedContinuation<UsageWindowProbeProcessResult, Error>?
    private(set) var callCount = 0

    init(result: UsageWindowProbeProcessResult) {
        self.output = result
    }

    func run(
        command: UsageWindowProbeCommand,
        timeout: TimeInterval
    ) async throws -> UsageWindowProbeProcessResult {
        callCount += 1
        started.signal()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume(returning: output)
        continuation = nil
    }

    func numberOfCalls() -> Int {
        callCount
    }
}
