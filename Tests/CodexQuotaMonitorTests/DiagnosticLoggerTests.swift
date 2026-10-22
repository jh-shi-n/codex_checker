// 목적: 진단 JSONL 보관·검증·실패 격리 테스트
// 이용처: CodexQuotaMonitorTests XCTest 대상
// 사용방법: 보관 정책 또는 저장소 동작 변경 시 관련 테스트 실행
// 실행 예: swift test --filter DiagnosticLoggerTests

import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// - 목적: 진단 로그 보관·검증·실패 격리 확인
final class DiagnosticLoggerTests: XCTestCase {
    /// - 목적: 7일 보존 경계의 등호 포함 및 이전 기록 제거 확인
    func testRetentionKeepsExactBoundaryAndRemovesOlderRecords() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = LockedClock(base)
        XCTAssertEqual(DiagnosticLogger.defaultMaximumBytes, 10_000_000)
        XCTAssertEqual(DiagnosticLogger.defaultMaximumAge, 604_800)
        let logger = DiagnosticLogger(directory: directory, now: { clock.read() }, osLogEnabled: false, timerEnabled: false)

        clock.set(base.addingTimeInterval(-604_801))
        logger.record(.probeRequested, operationID: UUID(), fields: [.reason: .identifier("older")])
        clock.set(base.addingTimeInterval(-604_800))
        logger.record(.probeStarted, operationID: UUID(), fields: [.reason: .identifier("boundary")])
        logger.flush()

        clock.set(base)
        logger.maintain()
        logger.flush()

        let reasons = try jsonLines(in: directory).compactMap { ($0["fields"] as? [String: Any])?["reason"] as? [String: Any] }
            .compactMap { $0["value"] as? String }
        XCTAssertEqual(reasons, ["boundary"])
    }

    /// - 목적: 용량 상한 적용과 최신 행 보존 확인
    func testCapacityEvictsOldestRowsAndPreservesNewest() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = LockedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let logger = DiagnosticLogger(directory: directory, now: { clock.read() }, maxBytes: 900, maxAge: 10_000, osLogEnabled: false, timerEnabled: false)

        for index in 0..<30 {
            logger.record(.probeFinished, operationID: UUID(), fields: [.reason: .identifier("record-\(index)")])
            clock.set(clock.read().addingTimeInterval(1))
        }
        logger.flush()

        let files = try managedFiles(in: directory)
        let totalBytes = try files.reduce(0) { partial, url in
            partial + (try Data(contentsOf: url)).count
        }
        let reasons = try jsonLines(in: directory).compactMap { ($0["fields"] as? [String: Any])?["reason"] as? [String: Any] }
            .compactMap { $0["value"] as? String }
        XCTAssertLessThanOrEqual(totalBytes, 900)
        XCTAssertFalse(reasons.contains("record-0"))
        XCTAssertTrue(reasons.contains("record-29"))
        XCTAssertLessThan(reasons.count, 30)
        for file in files {
            XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 256 * 1024)
        }
    }

    /// - 목적: 다중 조각 총량 제한과 가장 최신 행 보존 확인
    func testCapacityEvictsOldestSegmentAndKeepsNewestSegment() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let oldFile = directory.appendingPathComponent("diagnostic-1800000000000-old.jsonl")
        let newFile = directory.appendingPathComponent("diagnostic-1800001000000-new.jsonl")
        try writeSeedSegment(to: oldFile, start: base, count: 900, prefix: "old")
        try writeSeedSegment(to: newFile, start: base.addingTimeInterval(1_000), count: 900, prefix: "new")
        let logger = DiagnosticLogger(directory: directory, maxBytes: 250_000, maxAge: 10_000, osLogEnabled: false, timerEnabled: false)

        logger.flush()

        let files = try managedFiles(in: directory)
        let totalBytes = try files.reduce(0) { $0 + (try Data(contentsOf: $1)).count }
        let reasons = try jsonLines(in: directory).compactMap { ($0["fields"] as? [String: Any])?["reason"] as? [String: Any] }
            .compactMap { $0["value"] as? String }
        XCTAssertLessThanOrEqual(totalBytes, 250_000)
        XCTAssertFalse(reasons.contains(where: { $0.hasPrefix("old-") }))
        XCTAssertTrue(reasons.contains("newest"))
        XCTAssertTrue(try files.allSatisfy { (try Data(contentsOf: $0)).count <= 256 * 1024 })
    }

    /// - 목적: 재시작 시 만료·잘못된·미완성 행 정리 확인
    func testRestartRemovesExpiredMalformedAndTruncatedRows() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = LockedClock(base)
        let firstLogger = DiagnosticLogger(directory: directory, now: { clock.read() }, maxAge: 100, osLogEnabled: false, timerEnabled: false)
        firstLogger.record(.probeRequested, fields: [.reason: .identifier("expired")])
        clock.set(base.addingTimeInterval(200))
        firstLogger.record(.probeFinished, fields: [.reason: .identifier("recent")])
        firstLogger.flush()

        let activeFile = try XCTUnwrap(try managedFiles(in: directory).first)
        let handle = try FileHandle(forWritingTo: activeFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{broken-json}\n{\"timestamp\":\"truncated".utf8))
        try handle.close()

        let restarted = DiagnosticLogger(directory: directory, now: { clock.read() }, maxAge: 100, osLogEnabled: false, timerEnabled: false)
        restarted.flush()

        let reasons = try jsonLines(in: directory).compactMap { ($0["fields"] as? [String: Any])?["reason"] as? [String: Any] }
            .compactMap { $0["value"] as? String }
        XCTAssertEqual(reasons, ["recent"])
        XCTAssertTrue(try managedFiles(in: directory).allSatisfy { (try Data(contentsOf: $0).last) == 0x0A })
    }

    /// - 목적: 동시 호출의 행 완전성·누락 방지 확인
    func testConcurrentWritesRemainCompleteAndUnique() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = DiagnosticLogger(directory: directory, osLogEnabled: false, timerEnabled: false)
        let group = DispatchGroup()
        let writers = DispatchQueue(label: "DiagnosticLoggerTests.writers", attributes: .concurrent)
        let count = 240

        for index in 0..<count {
            group.enter()
            writers.async {
                logger.record(.processFinished, operationID: UUID(), fields: [.generation: .integer(index)])
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        logger.flush()

        let rows = try jsonLines(in: directory)
        let generations = rows.compactMap { ($0["fields"] as? [String: Any])?["generation"] as? [String: Any] }
            .compactMap { $0["value"] as? Int }
        XCTAssertEqual(rows.count, count)
        XCTAssertEqual(Set(generations).count, count)
    }

    /// - 목적: 제어 식별자 검증과 민감 문자열 제외 확인
    func testValidationAndPrivacyExcludeUncontrolledStrings() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = DiagnosticLogger(directory: directory, osLogEnabled: false, timerEnabled: false)

        logger.record(
            .quotaResultApplied,
            operationID: nil,
            accountID: "user@example.com",
            fields: [
                .model: .identifier("gpt-5.6"),
                .reason: .identifier("/Users/private/account"),
                .failure: .identifier("authentication failed: token secret"),
                .requestID: .identifier(String(repeating: "x", count: 81)),
                .generation: .integer(4),
                .applied: .boolean(true),
                .primaryResetBefore: .timestamp(Date(timeIntervalSince1970: .infinity))
            ]
        )
        logger.flush()

        let data = try Data(contentsOf: XCTUnwrap(try managedFiles(in: directory).first))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let row = try XCTUnwrap(try jsonLines(in: directory).first)
        let fields = try XCTUnwrap(row["fields"] as? [String: Any])
        XCTAssertFalse(text.contains("user@example.com"))
        XCTAssertFalse(text.contains("/Users/private/account"))
        XCTAssertFalse(text.contains("authentication failed"))
        XCTAssertFalse(text.contains(String(repeating: "x", count: 81)))
        XCTAssertNil(row["accountID"])
        XCTAssertNil(row["operationID"])
        XCTAssertNotNil(fields["model"])
        XCTAssertNotNil(fields["generation"])
        XCTAssertNotNil(fields["applied"])
        XCTAssertNil(fields["reason"])
        XCTAssertNil(fields["failure"])
        XCTAssertNil(fields["requestID"])
        XCTAssertNil(fields["primaryResetBefore"])
        XCTAssertEqual(row["level"] as? String, DiagnosticLevel.notice.rawValue)
    }

    /// - 목적: 같은 디렉터리를 쓰는 두 인스턴스의 기록 충돌 방지 확인
    func testMultipleInstancesSerializeWritesThroughProcessLock() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = DiagnosticLogger(directory: directory, osLogEnabled: false, timerEnabled: false)
        let second = DiagnosticLogger(directory: directory, osLogEnabled: false, timerEnabled: false)
        let group = DispatchGroup()
        let writers = DispatchQueue(label: "DiagnosticLoggerTests.process-lock", attributes: .concurrent)
        let perLogger = 50

        for index in 0..<perLogger {
            group.enter()
            writers.async {
                first.record(.probeFinished, fields: [.reason: .identifier("first-\(index)")])
                group.leave()
            }
            group.enter()
            writers.async {
                second.record(.probeFinished, fields: [.reason: .identifier("second-\(index)")])
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        first.flush()
        second.flush()

        let reasons = try jsonLines(in: directory).compactMap { ($0["fields"] as? [String: Any])?["reason"] as? [String: Any] }
            .compactMap { $0["value"] as? String }
        XCTAssertEqual(reasons.count, perLogger * 2)
        XCTAssertEqual(Set(reasons).count, perLogger * 2)
    }

    /// - 목적: 심볼릭 링크 대상 파일의 외부 변경 방지 확인
    func testSymlinkSegmentIsIgnoredWithoutChangingItsTarget() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let external = directory.deletingLastPathComponent().appendingPathComponent("diagnostic-external-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: external) }
        let original = Data("external-data".utf8)
        XCTAssertTrue(FileManager.default.createFile(atPath: external.path, contents: original))
        let symlink = directory.appendingPathComponent("diagnostic-1800000000000-link.jsonl")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: external)
        let logger = DiagnosticLogger(directory: directory, osLogEnabled: false, timerEnabled: false)

        logger.record(.appStarted)
        logger.flush()

        XCTAssertEqual(try Data(contentsOf: external), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlink.path))
    }

    /// - 목적: 고아 원자 교체 임시 파일만 정리하고 외부 파일 보존 확인
    func testMaintenanceRemovesOnlyOwnedOrphanTemporaryFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let orphan = directory.appendingPathComponent(".diagnostic-tmp-\(UUID().uuidString.lowercased())")
        let malformed = directory.appendingPathComponent(".diagnostic-tmp-not-a-uuid")
        let unrelated = directory.appendingPathComponent("unrelated.txt")
        let symlink = directory.appendingPathComponent(".diagnostic-tmp-\(UUID().uuidString.lowercased())")
        let external = directory.deletingLastPathComponent().appendingPathComponent("diagnostic-temp-target-\(UUID().uuidString)")
        XCTAssertTrue(FileManager.default.createFile(atPath: orphan.path, contents: Data("orphan".utf8)))
        XCTAssertTrue(FileManager.default.createFile(atPath: malformed.path, contents: Data("foreign".utf8)))
        let unrelatedContents = Data("preserve".utf8)
        XCTAssertTrue(FileManager.default.createFile(atPath: unrelated.path, contents: unrelatedContents))
        XCTAssertTrue(FileManager.default.createFile(atPath: external.path, contents: Data("target".utf8)))
        defer { try? FileManager.default.removeItem(at: external) }
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: external)
        let logger = DiagnosticLogger(directory: directory, osLogEnabled: false, timerEnabled: false)

        logger.maintain()
        logger.flush()

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformed.path))
        XCTAssertEqual(try Data(contentsOf: unrelated), unrelatedContents)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path), external.path)
    }

    /// - 목적: 디렉터리·로그 파일의 전용 권한 확인
    func testStoragePermissionsAreRestricted() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = DiagnosticLogger(directory: directory, osLogEnabled: false, timerEnabled: false)
        logger.record(.appStarted)
        logger.flush()

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let directoryMode = try XCTUnwrap(directoryAttributes[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(directoryMode & 0o777, 0o700)
        for file in try managedFiles(in: directory) {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let fileMode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
            XCTAssertEqual(fileMode & 0o777, 0o600)
        }
    }

    /// - 목적: 저장 경로 오류의 호출자 전파 방지와 대상 파일 보존 확인
    func testWriteFailureDoesNotChangeApplicationCallOrUnrelatedFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("not-a-directory")
        let original = Data("preserve".utf8)
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: original))
        let logger = DiagnosticLogger(directory: file, osLogEnabled: false, timerEnabled: false)

        logger.record(.probeFinished, fields: [.reason: .identifier("still-returned")])
        logger.maintain()
        logger.flush()

        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    /// - 목적: 저장 테스트용 전용 임시 디렉터리 생성
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostic-logger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// - 목적: 디렉터리의 JSONL 조각 경로 목록 반환
    private func managedFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("diagnostic-") && $0.pathExtension == "jsonl" }
    }

    /// - 목적: 검증 가능한 JSONL 행으로 테스트 조각 생성
    private func writeSeedSegment(to url: URL, start: Date, count: Int, prefix: String) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let sessionID = UUID().uuidString.lowercased()
        var data = Data()
        for index in 0..<count {
            let reason = prefix == "new" && index == count - 1 ? "newest" : "\(prefix)-\(index)"
            let row: [String: Any] = [
                "timestamp": formatter.string(from: start.addingTimeInterval(TimeInterval(index))),
                "sessionID": sessionID,
                "event": DiagnosticEvent.probeFinished.rawValue,
                "level": DiagnosticLevel.notice.rawValue,
                "fields": ["reason": ["type": "identifier", "value": reason]]
            ]
            data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            data.append(0x0A)
        }
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: data))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// - 목적: 조각별 완전 JSON 행 디코딩
    private func jsonLines(in directory: URL) throws -> [[String: Any]] {
        try managedFiles(in: directory).flatMap { file in
            let data = try Data(contentsOf: file)
            return data.split(separator: 0x0A).compactMap { row in
                (try? JSONSerialization.jsonObject(with: Data(row))) as? [String: Any]
            }
        }
    }
}

/// - 목적: 비동기 로거 테스트용 동기화 시계
private final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    /// - 목적: 기준 시각 초기화
    init(_ date: Date) {
        self.date = date
    }

    /// - 목적: 잠금 아래 현재 시각 반환
    func read() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    /// - 목적: 잠금 아래 기준 시각 변경
    func set(_ date: Date) {
        lock.lock()
        self.date = date
        lock.unlock()
    }
}
