// 목적: 파일 체크포인트의 재시작·추가·교체·분할 읽기 및 원본 집계 동등성 검증
// 이용처: 로컬 토큰 수집기 회귀·성능 검증
// 사용방법: swift test --filter IncrementalTokenUsageTests
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

@MainActor
final class IncrementalTokenUsageTests: XCTestCase {
    private let reference = Date(timeIntervalSince1970: 1_792_700_000)
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        return result
    }

    /// 완전·미완성 행 추가, 앱 재시작, 파일 삭제의 원본 집계 동등성 검증
    func testAppendPartialLineRestartAndDeletion() async throws {
        let home = try directory()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("sessions/rollout.jsonl")
        let cache = home.appendingPathComponent("checkpoints")
        try Data().write(to: home.appendingPathComponent("sessions/empty.jsonl"))
        try Data((line(10) + "\n" + line(20)).utf8).write(to: file)
        let reference = reference
        let provider = IncrementalTokenUsageProvider(cacheDirectory: cache, calendar: calendar, now: { reference }, bytesPerPass: 17)
        await assertMatches(provider, home: home)
        let firstBytes = await provider.lastReadBytes
        XCTAssertEqual(firstBytes, try Data(contentsOf: file).count)
        // 완성된 행만 저장하여 EOF 행 재처리의 이중 합산 방지
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + line(30) + "\n").utf8))
        try handle.close()
        await assertMatches(provider, home: home)
        let restarted = IncrementalTokenUsageProvider(cacheDirectory: cache, calendar: calendar, now: { reference })
        await assertMatches(restarted, home: home)
        let readBytes = await restarted.lastReadBytes
        XCTAssertEqual(readBytes, 0)
        try FileManager.default.removeItem(at: file)
        let empty = await restarted.snapshot(home: home)
        XCTAssertEqual(empty.totalSessions, 0)
        XCTAssertEqual(empty.last30Days.totalTokens, 0)
    }

    /// 축소·동일 크기 수정·원자적 교체 시 이전 누적값 폐기 검증
    func testTruncationSameSizeRewriteAndReplacement() async throws {
        let home = try directory()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("sessions/rollout.jsonl")
        let reference = reference
        let provider = IncrementalTokenUsageProvider(calendar: calendar, now: { reference })
        for (tokens, atomic) in [(100, false), (10, false), (20, false), (50000, false), (5, true)] {
            try Data((line(tokens) + "\n").utf8).write(to: file, options: atomic ? .atomic : [])
            await assertMatches(provider, home: home)
        }
    }

    /// 512개를 넘는 전체 파일의 분할 수집 및 초과 행 폐기 검증
    func testMoreThan512FilesAndOversizedLine() async throws {
        let home = try directory()
        defer { try? FileManager.default.removeItem(at: home) }
        for index in 0..<520 {
            try Data((String(repeating: "x", count: 300) + "\n" + line(10) + "\n").utf8)
                .write(to: home.appendingPathComponent("sessions/\(index).jsonl"))
        }
        let reference = reference
        let provider = IncrementalTokenUsageProvider(calendar: calendar, now: { reference }, bytesPerPass: 29,
                                                     filesPerPass: 9, maxLineBytes: 256)
        let result = await provider.snapshot(home: home)
        XCTAssertEqual(result.availability, .available)
        XCTAssertEqual(result.totalSessions, 520)
        XCTAssertEqual(result.last30Days.totalTokens, 5200)
        await assertMatches(provider, home: home)
    }

    /// キャ시 손상 시 재수집 및 취소 결과의 정상 집계 오인 방지 검증
    func testCorruptCheckpointAndCancellation() async throws {
        let home = try directory()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("checkpoints")
        try Data().write(to: home.appendingPathComponent("sessions/empty.jsonl"))
        try Data((line(10) + "\n").utf8).write(to: home.appendingPathComponent("sessions/a.jsonl"))
        let reference = reference
        let provider = IncrementalTokenUsageProvider(cacheDirectory: cache, calendar: calendar, now: { reference })
        await assertMatches(provider, home: home)
        for file in try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil) {
            try Data("broken".utf8).write(to: file)
        }
        let restarted = IncrementalTokenUsageProvider(cacheDirectory: cache, calendar: calendar, now: { reference })
        await assertMatches(restarted, home: home)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await restarted.snapshot(home: home)
        }
        let result = await cancelled.value
        XCTAssertEqual(result.error, .cancelled)
        await assertMatches(restarted, home: home)
    }

    /// 날짜 경계·캐시 증가분·시간대 변경 시 체크포인트 날짜 재배분 검증
    func testCalendarChangeAndMidnightCounters() async throws {
        let home = try directory()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("checkpoints")
        let text = [
            #"{"timestamp":"2026-10-22T23:59:00Z","type":"token_count","usage":{"input_tokens":10,"output_tokens":3,"cached_input_tokens":5}}"#,
            #"{"timestamp":"2026-10-23T00:01:00Z","type":"token_count","usage":{"input_tokens":30,"output_tokens":8,"cached_input_tokens":12}}"#,
        ].joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: home.appendingPathComponent("sessions/a.jsonl"))
        let reference = reference
        for offset in [0, 9, -12] {
            var local = calendar
            local.timeZone = TimeZone(secondsFromGMT: offset * 3600)!
            let provider = IncrementalTokenUsageProvider(cacheDirectory: cache, calendar: local, now: { reference }, bytesPerPass: 50)
            let original = await LocalTokenUsageProvider(calendar: local, now: { reference }).snapshot(home: home)
            let result = await provider.snapshot(home: home)
            XCTAssertEqual(result, original)
        }
    }

    /// 분할 수집 도중 취소 후 디스크 체크포인트에서 재시작 검증
    func testInterruptedScanResumesAndPolicyInvalidationDropsCheckpoints() async throws {
        let home = try directory()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("sessions/a.jsonl")
        try Data(((1...2000).map { line($0) }.joined(separator: "\n") + "\n").utf8).write(to: file)
        let reference = reference
        let cache = home.appendingPathComponent("checkpoints")
        let provider = IncrementalTokenUsageProvider(cacheDirectory: cache, calendar: calendar, now: { reference }, bytesPerPass: 1024)
        let task = Task { await provider.snapshot(home: home) }
        while await provider.lastReadBytes == 0 { await Task.yield() }
        task.cancel()
        let interrupted = await task.value
        XCTAssertEqual(interrupted.error, .cancelled)
        let restarted = IncrementalTokenUsageProvider(cacheDirectory: cache, calendar: calendar, now: { reference })
        await assertMatches(restarted, home: home)
        let readBytes = await restarted.lastReadBytes
        XCTAssertLessThan(readBytes, try Data(contentsOf: file).count)
        await restarted.invalidateAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        await assertMatches(restarted, home: home)
        let reread = await restarted.lastReadBytes
        XCTAssertEqual(reread, try Data(contentsOf: file).count)
    }

    /// 실제 로그 원문 대신 합성 로그로 기존 전체 읽기 대비 반복 갱신 중앙값 측정
    func testRepeatedRefreshPerformance() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_USAGE_BENCHMARK"] == "1" else {
            throw XCTSkip("CODEX_USAGE_BENCHMARK=1 설정 시 성능 측정")
        }
        let home = try directory()
        defer { try? FileManager.default.removeItem(at: home) }
        for index in 0..<80 {
            let content = (1...100).map { line($0 * 100) }.joined(separator: "\n") + "\n"
            try Data(content.utf8).write(to: home.appendingPathComponent("sessions/\(index).jsonl"))
        }
        let reference = reference
        let original = LocalTokenUsageProvider(calendar: calendar, now: { reference })
        let incremental = IncrementalTokenUsageProvider(cacheDirectory: home.appendingPathComponent("checkpoints"),
                                                        calendar: calendar, now: { reference })
        await assertMatches(incremental, home: home)
        var baseline: [Double] = [], changed: [Double] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            let old = await original.snapshot(home: home)
            let oldElapsed = start.duration(to: .now)
            baseline.append(Double(oldElapsed.components.attoseconds) / 1e18 + Double(oldElapsed.components.seconds))
            let next = ContinuousClock.now
            let new = await incremental.snapshot(home: home)
            let elapsed = next.duration(to: .now)
            changed.append(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            XCTAssertEqual(old, new)
        }
        let before = baseline.sorted()[2], after = changed.sorted()[2]
        print("TOKEN_USAGE_BENCHMARK baseline_ms=\(before * 1000) incremental_ms=\(after * 1000) improvement_pct=\((1 - after / before) * 100)")
        XCTAssertLessThan(after, before * 0.9)
        let readBytes = await incremental.lastReadBytes
        XCTAssertEqual(readBytes, 0)
    }

    /// 원본 제공자의 일별 증가분·세션·기간 요약과 비교
    private func assertMatches(_ provider: IncrementalTokenUsageProvider, home: URL,
                               file: StaticString = #filePath, line: UInt = #line) async {
        let reference = reference
        let original = await LocalTokenUsageProvider(calendar: calendar, now: { reference }, maxFileCount: 1000).snapshot(home: home)
        let result = await provider.snapshot(home: home)
        XCTAssertEqual(result, original, file: file, line: line)
    }

    /// 누적 토큰 이벤트 생성; 모델 호출·인증 파일 접근 제외
    private func line(_ tokens: Int) -> String {
        "{\"timestamp\":1792700000,\"type\":\"token_count\",\"usage\":{\"input_tokens\":\(tokens),\"output_tokens\":0}}"
    }

    /// 독립 임시 홈과 세션 디렉터리 생성
    private func directory() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("usage-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        return home
    }
}
