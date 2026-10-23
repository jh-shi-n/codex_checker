// 목적: 앱 사본 간 실행 잠금의 배타성·해제·파일 오류 구분 검증
// 이용처: 중복 앱 실행 방지 회귀 테스트
// 사용방법: swift test --filter AppInstanceLockTests
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 실제 파일 잠금과 별도 프로세스 경합 검증
final class AppInstanceLockTests: XCTestCase {
    /// 동시 보유 차단과 명시적 해제 후 다른 사본의 획득 검증
    func testDuplicateAcquisitionAndRelease() throws {
        try withLockFile { url in
            let first = AppInstanceLock(fileURL: url)
            let second = AppInstanceLock(fileURL: url)
            XCTAssertTrue(try first.acquire())
            XCTAssertTrue(try first.acquire())
            XCTAssertFalse(try second.acquire())
            first.release()
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertTrue(try second.acquire())
        }
    }

    /// 소유 객체 종료 시 커널 잠금 해제와 다음 실행 허용 검증
    func testOwnerDeinitializationReleasesLock() throws {
        try withLockFile { url in
            var owner: AppInstanceLock? = AppInstanceLock(fileURL: url)
            XCTAssertTrue(try XCTUnwrap(owner).acquire())
            owner = nil
            XCTAssertTrue(try AppInstanceLock(fileURL: url).acquire())
        }
    }

    /// 별도 프로세스가 같은 파일의 잠금을 획득하지 못하는지 검증
    func testAnotherProcessIsBlockedUntilRelease() throws {
        try withLockFile { url in
            let owner = AppInstanceLock(fileURL: url)
            XCTAssertTrue(try owner.acquire())
            XCTAssertEqual(try probeProcess(url), 42)
            owner.release()
            XCTAssertEqual(try probeProcess(url), 0)
        }
    }

    /// 접근 불가 파일의 실행 실패와 중복 실행 오인 방지 검증
    func testInvalidLockPathThrows() throws {
        try withLockFile { url in
            try Data().write(to: url)
            XCTAssertThrowsError(try AppInstanceLock(fileURL: url.appendingPathComponent("child")).acquire())
        }
    }

    /// 셸 없는 자식 프로세스의 실제 파일 잠금 결과 반환
    private func probeProcess(_ url: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
        import fcntl, sys
        with open(sys.argv[1], 'a') as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                sys.exit(42)
        """, url.path]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// 실제 사용자 잠금과 분리된 임시 경로 제공
    private func withLockFile(_ operation: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try operation(root.appendingPathComponent("instance.lock"))
    }
}
