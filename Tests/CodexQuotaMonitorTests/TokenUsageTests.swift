import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

final class TokenUsageTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var referenceDate: Date {
        calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 30,
            hour: 15,
            minute: 30
        ))!
    }

    func testProviderDeduplicatesCumulativeTokenCountsAndPreservesSplit() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try writeRollout(
            in: home,
            date: referenceDate,
            name: "rollout-today.jsonl",
            lines: [
                #"{"timestamp":"2026-08-30T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":4}}}}"#,
                #"{"timestamp":"2026-08-30T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":25,"output_tokens":7}}}}"#,
                #"{"timestamp":"2026-08-30T10:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"output_tokens":6}}}}"#,
            ]
        )
        try writeRollout(
            in: home,
            date: date(offset: -1),
            name: "rollout-yesterday.jsonl",
            lines: [
                #"{"type":"token_count","usage":{"input_tokens":3,"output_tokens":2}}"#,
            ]
        )

        let reference = referenceDate
        let provider = LocalTokenUsageProvider(calendar: calendar, now: { reference })
        let snapshot = await provider.snapshot(home: home)

        XCTAssertEqual(snapshot.availability, .available)
        XCTAssertEqual(snapshot.dailyPoints.count, 84)
        XCTAssertEqual(snapshot.today.inputTokens, 25)
        XCTAssertEqual(snapshot.today.outputTokens, 7)
        XCTAssertEqual(snapshot.today.totalTokens, 32)
        XCTAssertEqual(snapshot.totalSessions, 2)
        XCTAssertEqual(snapshot.averageTokensPerSession, 18.5, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.last7Days.inputTokens, 28)
        XCTAssertEqual(snapshot.last7Days.outputTokens, 9)
    }

    /// 자정·감소·중복 이벤트의 증가분 날짜 배분 및 세션 중복 방지
    func testProviderBucketsCumulativeDeltasAcrossMidnight() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeRollout(in: home, date: date(offset: -1), name: "midnight.jsonl", lines: [
            #"{"timestamp":"2026-08-29T23:58:00Z","type":"session_meta"}"#,
            #"{"timestamp":"2026-08-29T23:59:00Z","type":"token_count","usage":{"input_tokens":10,"output_tokens":4}}"#,
            #"{"timestamp":"2026-08-30T00:01:00Z","type":"token_count","usage":{"input_tokens":25,"output_tokens":7}}"#,
            #"{"timestamp":"2026-08-30T00:02:00Z","type":"token_count","usage":{"input_tokens":20,"output_tokens":6}}"#,
            #"{"timestamp":"2026-08-30T00:03:00Z","type":"token_count","usage":{"input_tokens":25,"output_tokens":7}}"#,
        ])
        let reference = referenceDate
        let snapshot = await LocalTokenUsageProvider(calendar: calendar, now: { reference }).snapshot(home: home)
        XCTAssertEqual(snapshot.today, TokenUsageTotals(inputTokens: 15, outputTokens: 3))
        XCTAssertEqual(snapshot.dailyPoints.dropLast().last?.totalTokens, 14)
        XCTAssertEqual(snapshot.last7Days.totalTokens, 32)
        XCTAssertEqual(snapshot.totalSessions, 1)
        XCTAssertEqual(snapshot.dailyPoints.last?.sessionCount, 1)
        XCTAssertEqual(snapshot.dailyPoints.dropLast().last?.sessionCount, 0)
    }

    /// 84일보다 오래된 디렉터리의 재개 세션에서 최근 증가분만 집계
    func testProviderIncludesResumedOldRollout() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeRollout(in: home, date: date(offset: -100), name: "resumed.jsonl", lines: [
            #"{"timestamp":"2026-05-22T10:00:00Z","type":"token_count","usage":{"input_tokens":100,"output_tokens":20}}"#,
            #"{"timestamp":"2026-08-30T10:00:00Z","type":"token_count","usage":{"input_tokens":125,"output_tokens":25}}"#,
        ])
        let reference = referenceDate
        let snapshot = await LocalTokenUsageProvider(calendar: calendar, now: { reference }).snapshot(home: home)
        XCTAssertEqual(snapshot.today.totalTokens, 30)
        XCTAssertEqual(snapshot.last30Days.totalTokens, 30)
        XCTAssertEqual(snapshot.totalSessions, 1)
    }

    /// 이전 날짜 귀속 알고리즘의 payload 복원 차단
    func testPayloadRejectsLegacyAggregationWithoutVersion() throws {
        let payload = try TokenUsageSnapshotPayload(snapshot: usageSnapshot(inputTokens: 3, outputTokens: 1)).encode()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        object.removeValue(forKey: "aggregationVersion")
        XCTAssertThrowsError(try TokenUsageSnapshotPayload.decode(JSONSerialization.data(withJSONObject: object)))
    }

    func testAggregatorZeroFills84DaysAndUsesInclusiveRangeBoundaries() {
        let aggregator = TokenUsageAggregator(calendar: calendar)
        let sessions = [
            TokenUsageSessionUsage(date: referenceDate, inputTokens: 10, outputTokens: 1),
            TokenUsageSessionUsage(date: date(offset: -6), inputTokens: 20, outputTokens: 2),
            TokenUsageSessionUsage(date: date(offset: -7), inputTokens: 30, outputTokens: 3),
            TokenUsageSessionUsage(date: date(offset: -29), inputTokens: 40, outputTokens: 4),
            TokenUsageSessionUsage(date: date(offset: -30), inputTokens: 50, outputTokens: 5),
            TokenUsageSessionUsage(date: date(offset: -84), inputTokens: 60, outputTokens: 6),
            TokenUsageSessionUsage(date: date(offset: 1), inputTokens: 70, outputTokens: 7),
        ]

        let snapshot = aggregator.aggregate(sessions: sessions, generatedAt: referenceDate)
        let today = calendar.startOfDay(for: referenceDate)
        let first = calendar.date(byAdding: .day, value: -83, to: today)!

        XCTAssertEqual(snapshot.dailyPoints.count, 84)
        XCTAssertEqual(snapshot.dailyPoints.first?.date, first)
        XCTAssertEqual(snapshot.dailyPoints.last?.date, today)
        XCTAssertEqual(snapshot.today.totalTokens, 11)
        XCTAssertEqual(snapshot.last7Days.totalTokens, 33)
        XCTAssertEqual(snapshot.last30Days.totalTokens, 110)
        // The fixed grid is 84 inclusive days (-83...0), so -30 is still
        // included in all-session totals even though it is outside last30.
        XCTAssertEqual(snapshot.totalSessions, 5)
        XCTAssertEqual(snapshot.averageTokensPerSession, 33, accuracy: 0.000_001)

        let nonZero = snapshot.dailyPoints.filter { $0.totalTokens > 0 }
        XCTAssertEqual(nonZero.count, 5)
        XCTAssertEqual(nonZero.map(\.sessionCount), [1, 1, 1, 1, 1])
    }

    func testMalformedAndContentBearingLinesDoNotBecomeUsage() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try writeRollout(
            in: home,
            date: referenceDate,
            name: "content-only.jsonl",
            lines: [
                #"{"timestamp":"2026-08-30T11:00:00Z","type":"message","message":{"usage":{"input_tokens":999,"output_tokens":999},"content":"do not retain"}}"#,
                "not json and intentionally malformed",
            ]
        )
        try writeRollout(
            in: home,
            date: referenceDate,
            name: "valid-token-shape.jsonl",
            lines: [
                #"{"timestamp":"2026-08-30T12:00:00Z","type":"event_msg","payload":{"type":"message","info":{"total_token_usage":{"input_tokens":1000,"output_tokens":1000}},"content":"ignore"}}"#,
            ]
        )

        let reference = referenceDate
        let provider = LocalTokenUsageProvider(calendar: calendar, now: { reference })
        let snapshot = await provider.snapshot(home: home)

        XCTAssertEqual(snapshot.today, .zero)
        XCTAssertEqual(snapshot.totalSessions, 0)
        XCTAssertEqual(snapshot.averageTokensPerSession, 0)
    }

    func testNegativeAndOverflowCountersAreClampedSafely() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try writeRollout(
            in: home,
            date: referenceDate,
            name: "overflow.jsonl",
            lines: [
                #"{"timestamp":"2026-08-30T13:00:00Z","type":"token_count","usage":{"input_tokens":-12,"output_tokens":999999999999999999999999999999}}"#,
            ]
        )

        let reference = referenceDate
        let provider = LocalTokenUsageProvider(calendar: calendar, now: { reference })
        let snapshot = await provider.snapshot(home: home)

        XCTAssertEqual(snapshot.today.inputTokens, 0)
        XCTAssertEqual(snapshot.today.outputTokens, Int64.max)
        XCTAssertEqual(snapshot.today.totalTokens, Int64.max)
        XCTAssertEqual(snapshot.totalSessions, 1)
        XCTAssertEqual(TokenUsageTotals(inputTokens: -1, outputTokens: -2), .zero)
    }

    func testMissingSessionsDirectoryIsAvailableEmptyWithZeroFill() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenUsageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let reference = referenceDate
        let provider = LocalTokenUsageProvider(calendar: calendar, now: { reference })
        let snapshot = await provider.snapshot(home: home)

        XCTAssertEqual(snapshot.availability, .available)
        XCTAssertEqual(snapshot.dailyPoints.count, 84)
        XCTAssertTrue(snapshot.dailyPoints.allSatisfy { $0 == TokenUsageDailyPoint(date: $0.date) })
        XCTAssertEqual(snapshot.totalSessions, 0)
        XCTAssertEqual(snapshot.averageTokensPerSession, 0)
    }

    func testSnapshotCacheMissHitAndExplicitRefreshReplacement() async {
        let first = TokenUsageAggregator(calendar: calendar).aggregate(
            sessions: [
                TokenUsageSessionUsage(date: referenceDate, inputTokens: 4, outputTokens: 1)
            ],
            generatedAt: referenceDate
        )
        let replacement = TokenUsageAggregator(calendar: calendar).aggregate(
            sessions: [
                TokenUsageSessionUsage(date: referenceDate, inputTokens: 40, outputTokens: 10)
            ],
            generatedAt: referenceDate
        )
        let cache = TokenUsageSnapshotCache(
            provider: FixedTokenUsageProvider(snapshot: replacement)
        )

        let cacheMiss = await cache.cachedSnapshot(for: "C1")
        XCTAssertNil(cacheMiss)
        await cache.replace(first, for: "C1")
        let cacheHit = await cache.cachedSnapshot(for: "C1")
        XCTAssertEqual(cacheHit, first)

        cache.invalidateAll()
        let invalidated = await cache.cachedSnapshot(for: "C1")
        XCTAssertNil(invalidated)

        let refreshed = await cache.refresh(
            accountID: "C1",
            home: URL(string: "codex-test://home")!
        )
        XCTAssertEqual(refreshed, replacement)
        let replaced = await cache.cachedSnapshot(for: "C1")
        XCTAssertEqual(replaced, replacement)
    }

    /// 앱 재시작 후 계정 홈에 맞는 저장 스냅샷 복원
    func testSnapshotCacheRestoresAggregateAfterRestart() async throws {
        let databaseDirectory = try makePersistenceDirectory()
        defer { try? FileManager.default.removeItem(at: databaseDirectory) }
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let clock = MutableTokenUsageTestClock(referenceDate)
        let snapshot = usageSnapshot(inputTokens: 31, outputTokens: 12)
        let databaseURL = databaseDirectory.appendingPathComponent("token-usage.sqlite")
        let firstCache = TokenUsageSnapshotCache(
            provider: FixedTokenUsageProvider(snapshot: snapshot),
            databaseURL: databaseURL,
            accountHomes: ["C1": home],
            now: { clock.now() }
        )

        let updated = await firstCache.update(accountID: "C1", home: home)
        XCTAssertEqual(updated, snapshot)

        let restartProvider = MutableTokenUsageProvider(
            snapshot: usageSnapshot(inputTokens: 0, outputTokens: 0, availability: .unavailable)
        )
        let restartedCache = TokenUsageSnapshotCache(
            provider: restartProvider,
            databaseURL: databaseURL,
            accountHomes: ["C1": home],
            now: { clock.now() }
        )
        let restored = await restartedCache.cachedSnapshot(for: "C1")
        let providerCalls = await restartProvider.callCount()

        XCTAssertEqual(restored, snapshot)
        XCTAssertEqual(providerCalls, 0)
    }

    /// 만료 경계에서 메모리와 SQLite 행 제거
    func testSnapshotCacheDeletesAtExactExpiry() async throws {
        let databaseDirectory = try makePersistenceDirectory()
        defer { try? FileManager.default.removeItem(at: databaseDirectory) }
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let clock = MutableTokenUsageTestClock(referenceDate)
        let databaseURL = databaseDirectory.appendingPathComponent("token-usage.sqlite")
        let snapshot = usageSnapshot(inputTokens: 7, outputTokens: 3)
        let cache = TokenUsageSnapshotCache(
            provider: FixedTokenUsageProvider(snapshot: snapshot),
            databaseURL: databaseURL,
            accountHomes: ["C1": home],
            now: { clock.now() }
        )
        _ = await cache.update(accountID: "C1", home: home)

        clock.set(referenceDate.addingTimeInterval(TokenUsageSnapshotCache.snapshotLifetime))
        let expired = await cache.cachedSnapshot(for: "C1")
        clock.set(referenceDate.addingTimeInterval(TokenUsageSnapshotCache.snapshotLifetime - 1))
        let restoredAfterExpiry = await TokenUsageSnapshotCache(
            databaseURL: databaseURL,
            accountHomes: ["C1": home],
            now: { clock.now() }
        ).cachedSnapshot(for: "C1")

        XCTAssertNil(expired)
        XCTAssertNil(restoredAfterExpiry)
    }

    /// 새 성공 업데이트의 완료 시각 기준 14일 만료 갱신
    func testSuccessfulUpdateRenewsSnapshotLifetime() async throws {
        let databaseDirectory = try makePersistenceDirectory()
        defer { try? FileManager.default.removeItem(at: databaseDirectory) }
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let clock = MutableTokenUsageTestClock(referenceDate)
        let original = usageSnapshot(inputTokens: 10, outputTokens: 2)
        let renewed = usageSnapshot(inputTokens: 90, outputTokens: 15)
        let provider = MutableTokenUsageProvider(snapshot: original)
        let cache = TokenUsageSnapshotCache(
            provider: provider,
            databaseURL: databaseDirectory.appendingPathComponent("token-usage.sqlite"),
            accountHomes: ["C1": home],
            now: { clock.now() }
        )
        _ = await cache.update(accountID: "C1", home: home)

        clock.set(referenceDate.addingTimeInterval(13 * 24 * 60 * 60))
        await provider.set(renewed)
        _ = await cache.update(accountID: "C1", home: home)
        clock.set(referenceDate.addingTimeInterval(14 * 24 * 60 * 60 + 1))
        let stillValid = await cache.cachedSnapshot(for: "C1")

        XCTAssertEqual(stillValid, renewed)
    }

    /// unavailable 갱신의 기존 데이터 보존과 TTL 불연장
    func testUnavailableRefreshPreservesPriorSnapshotAndExpiry() async throws {
        let databaseDirectory = try makePersistenceDirectory()
        defer { try? FileManager.default.removeItem(at: databaseDirectory) }
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let clock = MutableTokenUsageTestClock(referenceDate)
        let valid = usageSnapshot(inputTokens: 22, outputTokens: 8)
        let unavailable = usageSnapshot(inputTokens: 0, outputTokens: 0, availability: .unavailable)
        let provider = MutableTokenUsageProvider(snapshot: valid)
        let cache = TokenUsageSnapshotCache(
            provider: provider,
            databaseURL: databaseDirectory.appendingPathComponent("token-usage.sqlite"),
            accountHomes: ["C1": home],
            now: { clock.now() }
        )
        _ = await cache.update(accountID: "C1", home: home)

        clock.set(referenceDate.addingTimeInterval(12 * 24 * 60 * 60))
        await provider.set(unavailable)
        let failedRefresh = await cache.update(accountID: "C1", home: home)
        let preserved = await cache.cachedSnapshot(for: "C1")
        clock.set(referenceDate.addingTimeInterval(TokenUsageSnapshotCache.snapshotLifetime))
        let atOriginalExpiry = await cache.cachedSnapshot(for: "C1")

        XCTAssertEqual(failedRefresh, unavailable)
        XCTAssertEqual(preserved, valid)
        XCTAssertNil(atOriginalExpiry)
    }

    /// 나중에 시작한 갱신의 완료 순서와 무관한 승리 보장
    func testLaterStartedRefreshWinsOutOfOrderCompletion() async throws {
        let databaseDirectory = try makePersistenceDirectory()
        defer { try? FileManager.default.removeItem(at: databaseDirectory) }
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let first = usageSnapshot(inputTokens: 18, outputTokens: 4)
        let later = usageSnapshot(inputTokens: 81, outputTokens: 29)
        let reference = referenceDate
        let provider = DelayedTokenUsageProvider()
        let databaseURL = databaseDirectory.appendingPathComponent("token-usage.sqlite")
        let cache = TokenUsageSnapshotCache(
            provider: provider,
            databaseURL: databaseURL,
            accountHomes: ["C1": home],
            now: { reference }
        )

        let firstTask = Task { await cache.update(accountID: "C1", home: home) }
        await provider.waitForRequestCount(1)
        let laterTask = Task { await cache.update(accountID: "C1", home: home) }
        await provider.waitForRequestCount(2)
        await provider.complete(request: 2, with: later)
        let laterResult = await laterTask.value
        await provider.complete(request: 1, with: first)
        let firstResult = await firstTask.value
        let cached = await cache.cachedSnapshot(for: "C1")
        let restored = await TokenUsageSnapshotCache(
            databaseURL: databaseURL,
            accountHomes: ["C1": home],
            now: { reference }
        ).cachedSnapshot(for: "C1")

        XCTAssertEqual(laterResult, later)
        XCTAssertEqual(firstResult, later)
        XCTAssertEqual(cached, later)
        XCTAssertEqual(restored, later)
    }

    /// SQLite 저장 실패 시 기존 스냅샷과 만료 시각 보존
    func testPersistenceFailurePreservesPriorSnapshotAndReportsUnavailable() async throws {
        let databaseDirectory = try makePersistenceDirectory()
        defer { try? FileManager.default.removeItem(at: databaseDirectory) }
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let clock = MutableTokenUsageTestClock(referenceDate)
        let databaseURL = databaseDirectory.appendingPathComponent("token-usage.sqlite")
        let valid = usageSnapshot(inputTokens: 27, outputTokens: 9)
        let replacement = usageSnapshot(inputTokens: 99, outputTokens: 33)
        let provider = MutableTokenUsageProvider(snapshot: valid)
        let cache = TokenUsageSnapshotCache(
            provider: provider,
            databaseURL: databaseURL,
            accountHomes: ["C1": home],
            now: { clock.now() }
        )
        _ = await cache.update(accountID: "C1", home: home)
        try FileManager.default.removeItem(at: databaseURL)
        try FileManager.default.createDirectory(at: databaseURL, withIntermediateDirectories: false)

        clock.set(referenceDate.addingTimeInterval(5 * 24 * 60 * 60))
        await provider.set(replacement)
        let failedUpdate = await cache.update(accountID: "C1", home: home)
        let preserved = await cache.cachedSnapshot(for: "C1")
        clock.set(referenceDate.addingTimeInterval(TokenUsageSnapshotCache.snapshotLifetime))
        let atOriginalExpiry = await cache.cachedSnapshot(for: "C1")

        XCTAssertEqual(failedUpdate.availability, .unavailable)
        XCTAssertEqual(failedUpdate.error, .storageUnavailable)
        XCTAssertEqual(preserved, valid)
        XCTAssertNil(atOriginalExpiry)
    }

    /// 홈 재구성 시 이전 경로의 메모리·디스크 스냅샷 제거
    func testAccountHomeReconfigurationInvalidatesPriorPath() async throws {
        let databaseDirectory = try makePersistenceDirectory()
        defer { try? FileManager.default.removeItem(at: databaseDirectory) }
        let oldHome = try makeHome()
        defer { try? FileManager.default.removeItem(at: oldHome) }
        let newHome = try makeHome()
        defer { try? FileManager.default.removeItem(at: newHome) }
        let databaseURL = databaseDirectory.appendingPathComponent("token-usage.sqlite")
        let snapshot = usageSnapshot(inputTokens: 14, outputTokens: 6)
        let reference = referenceDate
        let cache = TokenUsageSnapshotCache(
            provider: FixedTokenUsageProvider(snapshot: snapshot),
            databaseURL: databaseURL,
            accountHomes: ["C1": oldHome],
            now: { reference }
        )
        _ = await cache.update(accountID: "C1", home: oldHome)

        await cache.configureAccountHomes(["C1": newHome])
        let currentHomeValue = await cache.cachedSnapshot(for: "C1")
        let restartedWithOldPath = await TokenUsageSnapshotCache(
            databaseURL: databaseURL,
            accountHomes: ["C1": oldHome],
            now: { reference }
        ).cachedSnapshot(for: "C1")

        XCTAssertNil(currentHomeValue)
        XCTAssertNil(restartedWithOldPath)
    }

    /// 한 계정 경로 변경 시 다른 계정의 메모리·SQLite 기록 보존 검증
    func testAccountHomeChangePreservesOtherAccountsAcrossRestart() async throws {
        let directory = try makePersistenceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("token-usage.sqlite")
        let oldHome = directory.appendingPathComponent("old")
        let newHome = directory.appendingPathComponent("new")
        let otherHome = directory.appendingPathComponent("other")
        let snapshot = usageSnapshot(inputTokens: 14, outputTokens: 6)
        let reference = referenceDate
        let cache = TokenUsageSnapshotCache(
            provider: FixedTokenUsageProvider(snapshot: snapshot),
            databaseURL: databaseURL,
            accountHomes: ["C1": oldHome, "C2": otherHome],
            now: { reference }
        )
        _ = await cache.update(accountID: "C1", home: oldHome)
        _ = await cache.update(accountID: "C2", home: otherHome)

        cache.invalidate(accountID: "C1")
        await cache.configureAccountHomes(["C1": newHome, "C2": otherHome])
        let changedAccount = await cache.cachedSnapshot(for: "C1")
        let preservedAccount = await cache.cachedSnapshot(for: "C2")
        let restoredAccount = await TokenUsageSnapshotCache(
            databaseURL: databaseURL,
            accountHomes: ["C1": newHome, "C2": otherHome],
            now: { reference }
        ).cachedSnapshot(for: "C2")

        XCTAssertNil(changedAccount)
        XCTAssertEqual(preservedAccount, snapshot)
        XCTAssertEqual(restoredAccount, snapshot)
    }

    /// 단일 토큰 요약 스냅샷 생성
    private func usageSnapshot(
        inputTokens: Int64,
        outputTokens: Int64,
        availability: TokenUsageAvailability = .available
    ) -> TokenUsageSnapshot {
        let totals = TokenUsageTotals(inputTokens: inputTokens, outputTokens: outputTokens)
        return TokenUsageSnapshot(
            generatedAt: referenceDate,
            dailyPoints: [TokenUsageDailyPoint(
                date: referenceDate,
                totals: totals,
                sessionCount: totals.totalTokens == 0 ? 0 : 1
            )],
            today: totals,
            last7Days: totals,
            last30Days: totals,
            totalSessions: totals.totalTokens == 0 ? 0 : 1,
            averageTokensPerSession: totals.totalTokens == 0 ? 0 : Double(totals.totalTokens),
            availability: availability,
            error: availability == .unavailable ? .sessionsDirectoryUnavailable : nil
        )
    }

    /// 테스트 전용 SQLite 디렉터리 생성
    private func makePersistenceDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenUsagePersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenUsageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        return home
    }

    private func writeRollout(
        in home: URL,
        date: Date,
        name: String,
        lines: [String]
    ) throws {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        let directory = sessions
            .appendingPathComponent(String(format: "%04d", components.year ?? 0), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.month ?? 0), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.day ?? 0), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Data(lines.joined(separator: "\n").utf8)
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private func date(offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: referenceDate)!
    }
}

private struct FixedTokenUsageProvider: TokenUsageProvider, Sendable {
    let snapshot: TokenUsageSnapshot

    func snapshot(home: URL) async -> TokenUsageSnapshot {
        _ = home
        return snapshot
    }
}

/// 테스트 시각을 동시성 안전하게 조정하는 시계
private final class MutableTokenUsageTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    /// 초기 기준 시각 설정
    init(_ value: Date) {
        self.value = value
    }

    /// 현재 테스트 시각 반환
    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// 테스트 시각 교체
    func set(_ value: Date) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }
}

/// 호출 시 변경 가능한 스냅샷 제공자
private actor MutableTokenUsageProvider: TokenUsageProvider {
    private var value: TokenUsageSnapshot
    private var requests = 0

    /// 반환할 초기 스냅샷 설정
    init(snapshot: TokenUsageSnapshot) {
        self.value = snapshot
    }

    /// 반환 스냅샷 변경
    func set(_ snapshot: TokenUsageSnapshot) {
        value = snapshot
    }

    /// 테스트용 provider 호출 횟수 조회
    func callCount() -> Int {
        requests
    }

    /// 현재 테스트 스냅샷 반환
    func snapshot(home: URL) async -> TokenUsageSnapshot {
        _ = home
        requests += 1
        return value
    }
}

/// 요청별 완료 순서를 제어하는 테스트 제공자
private actor DelayedTokenUsageProvider: TokenUsageProvider {
    private var requestCountValue = 0
    private var pending: [Int: CheckedContinuation<TokenUsageSnapshot, Never>] = [:]
    private var requestWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// 지정 횟수의 provider 요청 시작 대기
    func waitForRequestCount(_ target: Int) async {
        guard requestCountValue < target else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((target, continuation))
        }
    }

    /// 지정 요청의 결과 완료
    func complete(request: Int, with snapshot: TokenUsageSnapshot) {
        pending.removeValue(forKey: request)?.resume(returning: snapshot)
    }

    /// 결과 완료 전까지 provider 요청 보류
    func snapshot(home: URL) async -> TokenUsageSnapshot {
        _ = home
        requestCountValue += 1
        let readyWaiters = requestWaiters.filter { $0.target <= requestCountValue }
        requestWaiters.removeAll { $0.target <= requestCountValue }
        readyWaiters.forEach { $0.continuation.resume() }
        return await withCheckedContinuation { continuation in
            pending[requestCountValue] = continuation
        }
    }
}
