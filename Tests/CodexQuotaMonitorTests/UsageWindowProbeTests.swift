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
            "--enable", "skip_host_skill_discovery",
            "--disable", "apps",
            "--disable", "plugins",
            "--disable", "multi_agent",
            "--disable", "skill_search",
            "--disable", "shell_tool",
            "--disable", "unified_exec",
            "--disable", "sleep_tool",
            "--disable", "browser_use",
            "--disable", "browser_use_external",
            "--disable", "browser_use_full_cdp_access",
            "--disable", "computer_use",
            "--disable", "image_generation",
            "-c",
            "project_doc_max_bytes=0",
            "-c",
            "suppress_unstable_features_warning=true",
            "-c",
            "features.code_mode.enabled=false",
            "-c",
            "include_permissions_instructions=false",
            "-c",
            "include_apps_instructions=false",
            "-c",
            "include_collaboration_mode_instructions=false",
            "-c",
            "include_environment_context=false",
            "-c",
            "web_search=\"disabled\"",
            "--sandbox",
            "read-only",
            "--model",
            "gpt-5.6-luna",
            "-c",
            "model_reasoning_effort=\"none\"",
            "-c", "skills.include_instructions=false",
            "-c", "skills.bundled.enabled=false",
            "-c", "tools.update_plan.enabled=false",
            "-c", "tools.experimental_request_user_input.enabled=false",
            "--disable", "view_image",
            "--disable", "goals",
            "--disable", "workspace_dependencies",
            "--disable", "default_mode_request_user_input",
            "--disable", "tool_suggest",
            "--json",
            ".",
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

    func testExecutionIsolationContainsAuthLinkMinimalInstructionsAndEmptyWorkingDirectory() throws {
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
        XCTAssertEqual(
            Set(rootContents.map(\.lastPathComponent)),
            ["codex-home", "working-directory", "ping-instructions"]
        )

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
        XCTAssertEqual(
            try Data(contentsOf: isolation.modelInstructionsURL),
            Data("Silence".utf8)
        )
        if let permissions = try fileManager.attributesOfItem(atPath: isolation.modelInstructionsURL.path)[.posixPermissions] as? NSNumber {
            XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        }

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

    /// assistant 출력과 turn 완료가 모두 있을 때 usage 및 완료 시각 반환
    func testSuccessParsesCommonUsageDictionaryAndDates() async {
        let output = probeOutput(
            usage: ["input_tokens": 12, "output_tokens": 7, "total_tokens": 19]
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

    /// usage 정보가 없어도 유효한 probe 출력이면 성공 처리
    func testZeroExitWithExpectedOutputWithoutUsageIsSuccessful() async {
        let runner = RecordingRunner(result: .init(exitStatus: 0, stdout: probeOutput()))
        let service = makeService(
            fileSystem: RecordingFileSystem(metadata: .init(exists: true)),
            locator: RecordingLocator(url: executableURL),
            runner: runner
        )

        let result = await service.probe(config())

        XCTAssertTrue(result.isSuccess)
        XCTAssertNil(result.usage)
    }

    /// 빈 응답과 정상 완료 이벤트의 성공 처리
    func testEmptyAssistantOutputSucceedsWithTurnCompletion() async {
        let runner = RecordingRunner(result: .init(
            exitStatus: 0,
            stdout: probeOutput(assistantText: nil)
        ))
        let service = makeService(
            fileSystem: RecordingFileSystem(metadata: .init(exists: true)),
            locator: RecordingLocator(url: executableURL),
            runner: runner
        )

        let result = await service.probe(config())

        XCTAssertTrue(result.isSuccess)
    }

    /// 응답 내용에 의존하지 않는 정상 완료 판정
    func testArbitraryAssistantOutputSucceedsWithTurnCompletion() async {
        let runner = RecordingRunner(result: .init(
            exitStatus: 0,
            stdout: probeOutput(assistantText: "2")
        ))
        let service = makeService(
            fileSystem: RecordingFileSystem(metadata: .init(exists: true)),
            locator: RecordingLocator(url: executableURL),
            runner: runner
        )

        let result = await service.probe(config())

        XCTAssertTrue(result.isSuccess)
    }

    /// item 완료만 있고 turn 완료가 없으면 실패 처리
    func testAssistantOutputWithoutTurnCompletionFails() async {
        let runner = RecordingRunner(result: .init(
            exitStatus: 0,
            stdout: probeOutput(turnCompleted: false)
        ))
        let service = makeService(
            fileSystem: RecordingFileSystem(metadata: .init(exists: true)),
            locator: RecordingLocator(url: executableURL),
            runner: runner
        )

        let result = await service.probe(config())

        XCTAssertEqual(result.failureCategory, .malformedOutput)
    }

    /// 빈 JSONL stream을 정상 완료로 오인하지 않도록 검증
    func testEmptyStreamFails() async {
        let runner = RecordingRunner(result: .init(exitStatus: 0, stdout: Data()))
        let service = makeService(
            fileSystem: RecordingFileSystem(metadata: .init(exists: true)),
            locator: RecordingLocator(url: executableURL),
            runner: runner
        )

        let result = await service.probe(config())

        XCTAssertEqual(result.failureCategory, .malformedOutput)
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
            "{\"type\":\"response.completed\",\"error\":{\"message\":\"authentication required\"}}\n".utf8
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

    func testCancellationStaysDistinctInProbeResultAndLatestState() async {
        let runner = RecordingRunner(error: .cancelled)
        let service = makeService(
            fileSystem: RecordingFileSystem(metadata: .init(exists: true)),
            locator: RecordingLocator(url: executableURL),
            runner: runner
        )

        let result = await service.probe(config())
        let state = await service.state(for: "C1")

        XCTAssertEqual(result.status, .cancelled)
        XCTAssertTrue(result.isCancelled)
        XCTAssertNil(result.failureCategory)
        XCTAssertEqual(result.userMessage, "사용량 확인이 취소되었습니다.")
        XCTAssertEqual(state.status, .cancelled)
        XCTAssertEqual(state.result, result)
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

    func testTokenUsageRejectsBooleanFractionAndOutOfRangeCounts() {
        var parser = UsageWindowProbeJSONLParser()
        parser.append(Data(
            "{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":true,\"output_tokens\":1.5,\"total_tokens\":9223372036854775808}}\n".utf8
        ))

        let result = parser.finish()

        XCTAssertNil(result.usage?.inputTokens)
        XCTAssertNil(result.usage?.outputTokens)
        XCTAssertNil(result.usage?.totalTokens)
    }

    func testTokenUsagePreservesIntMaxWithoutFloatingPointConversion() {
        var parser = UsageWindowProbeJSONLParser()
        parser.append(Data(
            "{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":\(Int.max)}}\n".utf8
        ))

        XCTAssertEqual(parser.finish().usage?.inputTokens, Int.max)
    }

    /// 중복 실행 차단 후 첫 실행의 완료 결과 검증
    func testSameAccountOverlapIsRejectedWhileFirstCallRuns() async {
        let runner = BlockingRunner(result: .init(exitStatus: 0, stdout: probeOutput()))
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

    /// 제한된 상속 PATH에서도 실행 파일의 interpreter 탐색 경로 유지
    func testLiveRunnerAddsExecutableDirectoryToRestrictedPath() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("usage-window-path-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let configuredHome = root.appendingPathComponent("account", isDirectory: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: configuredHome, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let authURL = configuredHome.appendingPathComponent("auth.json")
        XCTAssertTrue(fileManager.createFile(atPath: authURL.path, contents: Data("auth".utf8)))
        let executable = bin.appendingPathComponent("codex")
        let interpreter = bin.appendingPathComponent("probe-runtime")
        try Data("#!/usr/bin/env probe-runtime\n".utf8).write(to: executable)
        try Data("""
        #!/bin/sh
        if [ "$1" = "debug" ]; then
          printf '%s\\n' '{"models":[{"slug":"gpt-5.6-luna","tool_mode":"code_mode_only","apply_patch_tool_type":"freeform","use_responses_lite":true}]}'
          exit 0
        fi
        printf '%s\\n' "$PATH"
        printf '%s\\n' "$@"
        for argument in "$@"; do
          case "$argument" in
            model_catalog_json=*)
              catalog_path="${argument#*=}"
              catalog_path="${catalog_path#\\\"}"
              catalog_path="${catalog_path%\\\"}"
              /bin/cat "$catalog_path"
              ;;
          esac
        done
        """.utf8).write(to: interpreter)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: executable.path)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: interpreter.path)

        let command = UsageWindowProbeCommandBuilder().build(
            executable: executable,
            configuredAccountHome: configuredHome
        )
        let runner = UsageWindowProbeLiveProcessRunner(inheritedEnvironment: ["PATH": "/usr/bin:/bin"])
        let result = try await runner.run(command: command, timeout: 5)

        XCTAssertEqual(result.exitStatus, 0)
        let childPath = String(decoding: result.stdout, as: UTF8.self)
        XCTAssertTrue(childPath.hasPrefix(bin.path + ":"))
        XCTAssertTrue(childPath.contains("/usr/bin:/bin"))
        XCTAssertTrue(childPath.contains("model_instructions_file=\""))
        XCTAssertTrue(childPath.contains("/ping-instructions\""))
        XCTAssertTrue(childPath.contains("\"tool_mode\":\"direct\""))
        XCTAssertTrue(childPath.contains("\"apply_patch_tool_type\":null"))
        XCTAssertTrue(childPath.contains("\"use_responses_lite\":false"))
        let catalogLine = try XCTUnwrap(childPath.split(separator: "\n").first(where: { $0.hasPrefix("model_catalog_json=") }))
        let path = String(catalogLine.dropFirst("model_catalog_json=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        XCTAssertFalse(fileManager.fileExists(atPath: path))
    }

    func testLiveRunnerCancellationKillsSignalIgnoringChildPromptly() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("usage-window-cancel-\(UUID().uuidString)", isDirectory: true)
        let accountHome = root.appendingPathComponent("account", isDirectory: true)
        try fileManager.createDirectory(at: accountHome, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        XCTAssertTrue(fileManager.createFile(
            atPath: accountHome.appendingPathComponent("auth.json").path,
            contents: Data("synthetic auth fixture".utf8)
        ))

        let marker = root.appendingPathComponent("child-started")
        let executable = root.appendingPathComponent("fake-codex")
        try Data("#!/bin/sh\ntrap '' TERM\n: > \"$CANCEL_MARKER\"\nwhile :; do :; done\n".utf8)
            .write(to: executable)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executable.path
        )

        let command = UsageWindowProbeCommand(
            executableURL: executable,
            configuredAccountHome: accountHome,
            arguments: ["exec", "print 1"],
            environmentOverrides: ["CANCEL_MARKER": marker.path]
        )
        let runner = UsageWindowProbeLiveProcessRunner(
            gracefulTerminationTimeout: 0.05,
            forcedTerminationTimeout: 0.1
        )
        let task = Task { try await runner.run(command: command, timeout: 1.5) }
        let startDeadline = Date().addingTimeInterval(1)
        while !fileManager.fileExists(atPath: marker.path), Date() < startDeadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(fileManager.fileExists(atPath: marker.path))

        let cancellationStart = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? UsageWindowProbeProcessError, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancellationStart), 0.75)
    }

    /// 지원되지 않는 카탈로그에서 요청 실행 없이 명시적 구성 실패 반환
    func testUnsupportedCatalogFailsWithoutExecutingProbe() async throws {
        try await withCatalogExecutable(body: "printf '%s\\n' '{\"models\":[]}'") { command in
            let runner = UsageWindowProbeLiveProcessRunner()
            do {
                _ = try await runner.run(command: command, timeout: 2)
                XCTFail("구성 실패 필요")
            } catch {
                XCTAssertEqual(error as? UsageWindowProbeProcessError, .configurationFailure)
            }
        }
    }

    /// 카탈로그의 무한 출력과 종료 지연에 대한 제한·정리 검증
    func testCatalogOutputAndTimeLimits() async throws {
        for (body, timeout, expected) in [
            ("while :; do printf '%1024s' x; done", 3.0, UsageWindowProbeProcessError.configurationFailure),
            ("while :; do :; done", 0.1, UsageWindowProbeProcessError.timeout),
        ] {
            try await withCatalogExecutable(body: body) { command in
                let runner = UsageWindowProbeLiveProcessRunner(gracefulTerminationTimeout: 0.05, forcedTerminationTimeout: 0.1)
                do {
                    _ = try await runner.run(command: command, timeout: timeout)
                    XCTFail("출력·시간 제한 실패 필요")
                } catch {
                    XCTAssertEqual(error as? UsageWindowProbeProcessError, expected)
                }
            }
        }
    }

    /// 카탈로그 단계의 동작만 노출하는 인증정보 없는 임시 실행 파일 생성
    private func withCatalogExecutable(
        body: String,
        operation: (UsageWindowProbeCommand) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-codex")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let command = UsageWindowProbeCommandBuilder().build(executable: executable, configuredAccountHome: root)
        try await operation(command)
    }

    /// JSONL event 배열을 CLI stdout 형태의 byte stream으로 직렬화
    private func probeOutput(
        assistantText: String? = " 1 \n",
        turnCompleted: Bool = true,
        usage: [String: Int]? = nil
    ) -> Data {
        var events: [[String: Any]] = []
        if let assistantText {
            events.append([
                "type": "item.completed",
                "item": [
                    "id": "item_0",
                    "type": "agent_message",
                    "text": assistantText,
                ],
            ])
        }
        if turnCompleted {
            var event: [String: Any] = [
                "type": "turn.completed",
                "error": NSNull(),
                "errors": [Any](),
                "failure": false,
                "failed": "",
            ]
            if let usage { event["usage"] = usage }
            events.append(event)
        }
        let lines = events.map { event -> String in
            let data = try! JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }
        return Data(lines.joined(separator: "\n").utf8)
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
