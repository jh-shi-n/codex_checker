// 목적: DB 잠금 중 계정 무효화의 UI 응답성과 이전 캐시 격리 검증
// 이용처: 계정 경로 변경 시 메인 스레드 정지 회귀 테스트
// 사용방법: swift test --filter TokenCacheInvalidationTests
import Foundation
import SQLite3
import XCTest
@testable import CodexQuotaMonitorKit

/// 사용자 저장소와 분리된 캐시 잠금 경합 검증
final class TokenCacheInvalidationTests: XCTestCase {
    /// 외부 쓰기 잠금 중에도 메인 스레드의 무효화 즉시 반환 검증
    @MainActor
    func testInvalidationReturnsWithoutWaitingForDatabaseWriter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache.sqlite")
        let now = Date()
        let store = SQLiteTokenUsageSnapshotStore(databaseURL: url)
        XCTAssertTrue(store.save(payload: Data("fixture".utf8), accountID: "C1", homeIdentity: "/old",
                                 updatedAt: now, expiresAt: now.addingTimeInterval(60)))
        let locked = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var database: OpaquePointer?
            guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
                locked.signal()
                finished.signal()
                return
            }
            defer { sqlite3_close(database); finished.signal() }
            let result = sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil)
            XCTAssertEqual(result, SQLITE_OK)
            locked.signal()
            guard result == SQLITE_OK else { return }
            _ = release.wait(timeout: .now() + 0.6)
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
        }
        XCTAssertEqual(locked.wait(timeout: .now() + 2), .success)
        let cache = TokenUsageSnapshotCache(databaseURL: url)
        let started = ContinuousClock.now
        cache.invalidate(accountID: "C1")
        let duration = started.duration(to: .now)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertLessThan(duration, .milliseconds(200))
        await cache.purgeExpired()
        XCTAssertNil(store.load(accountID: "C1", homeIdentity: "/old", referenceDate: now))
    }
}
