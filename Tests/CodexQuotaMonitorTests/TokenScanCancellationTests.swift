// 목적: 취소된 로컬 토큰 집계의 파일 읽기 중단 검증
// 이용처: 상세 창 닫기 및 계정 변경 이후 불필요한 집계 방지
// 사용방법: swift test --filter TokenScanCancellationTests
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 로컬 토큰 집계 취소와 읽기 상한 검증
final class TokenScanCancellationTests: XCTestCase {
    /// 조회 전 취소된 작업의 정상 집계 결과 반환 방지 검증
    func testCancelledTaskDoesNotProduceAvailableSnapshot() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await LocalTokenUsageProvider().snapshot(home: home)
        }
        let snapshot = await task.value
        XCTAssertEqual(snapshot.availability, .unavailable)
        XCTAssertEqual(snapshot.error, .cancelled)
    }

    /// 단일 파일 읽기 상한 초과 시 부분 집계의 정상 반환 차단 검증
    func testOversizedFileFailsWithoutPartialUsage() async throws {
        try await withRollouts(count: 1) { home, bytes in
            let snapshot = await LocalTokenUsageProvider(maxReadBytes: bytes - 1).snapshot(home: home)
            XCTAssertEqual(snapshot.error, .readLimitExceeded)
            XCTAssertEqual(snapshot.availability, .unavailable)
            XCTAssertEqual(snapshot.today, .zero)
        }
    }

    /// 파일별 크기가 작아도 전체 읽기 상한을 공유하는지 검증
    func testReadBudgetIsSharedAcrossFiles() async throws {
        try await withRollouts(count: 2) { home, bytes in
            let snapshot = await LocalTokenUsageProvider(maxReadBytes: bytes).snapshot(home: home)
            XCTAssertEqual(snapshot.error, .readLimitExceeded)
            XCTAssertEqual(snapshot.availability, .unavailable)
        }
    }

    /// 총 읽기량이 상한과 동일한 정상 입력의 허용 검증
    func testExactReadBudgetSucceeds() async throws {
        try await withRollouts(count: 2) { home, bytes in
            let snapshot = await LocalTokenUsageProvider(maxReadBytes: bytes * 2).snapshot(home: home)
            XCTAssertEqual(snapshot.availability, .available)
            XCTAssertNil(snapshot.error)
        }
    }

    /// 상한 초과·취소 실패가 마지막 성공 캐시를 덮어쓰지 않는지 검증
    func testReadLimitAndCancellationPreserveSuccessfulCache() async throws {
        try await withRollouts(count: 1) { home, bytes in
            let cache = TokenUsageSnapshotCache(provider: LocalTokenUsageProvider(maxReadBytes: bytes))
            let success = await cache.refresh(accountID: "C1", home: home)
            XCTAssertEqual(success.availability, .available)
            let file = home.appendingPathComponent("sessions/0.jsonl")
            let original = try Data(contentsOf: file)
            try (original + original).write(to: file)
            let failed = await cache.refresh(accountID: "C1", home: home)
            XCTAssertEqual(failed.error, .readLimitExceeded)
            let preserved = await cache.cachedSnapshot(for: "C1")
            XCTAssertEqual(preserved, success)
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await cache.refresh(accountID: "C1", home: home)
            }
            let cancellation = await cancelled.value
            XCTAssertEqual(cancellation.error, .cancelled)
            let afterCancellation = await cache.cachedSnapshot(for: "C1")
            XCTAssertEqual(afterCancellation, success)
        }
    }

    /// 실제 파일 수 상한 초과 시 정상 집계 반환 차단 검증
    func testFileLimitExceededRejectsSnapshot() async throws {
        try await withRollouts(count: 2) { home, _ in
            let snapshot = await LocalTokenUsageProvider(maxFileCount: 1).snapshot(home: home)
            XCTAssertEqual(snapshot.error, .fileLimitExceeded)
            XCTAssertEqual(snapshot.availability, .unavailable)
        }
    }

    /// 민감 정보 없는 동일 크기 JSONL 파일의 격리된 입력 제공
    private func withRollouts(
        count: Int,
        operation: (URL, Int) async throws -> Void
    ) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let line = Data((#"{"timestamp":"2026-10-23T00:00:00Z","type":"token_count","usage":{"input_tokens":2,"output_tokens":1}}"# + "\n").utf8)
        for index in 0..<count { try line.write(to: sessions.appendingPathComponent("\(index).jsonl")) }
        try await operation(home, line.count)
    }
}
