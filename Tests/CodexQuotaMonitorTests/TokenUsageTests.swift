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
