// 목적: 허용된 진단 이벤트의 로컬 JSONL 기록과 보관 관리
// 이용처: CodexQuotaMonitorKit 및 저장소 테스트
// 사용방법: DiagnosticLogger.shared.record(...) 호출 후 종료 시 flush() 호출
// 실행 예: DiagnosticLogger.shared.record(.appStarted); DiagnosticLogger.shared.flush()

import CoreFoundation
import Darwin
import Foundation
import OSLog

/// - 목적: 진단 이벤트 기록·정리·동기화
/// - 보관: 사용자 로그 폴더의 7일·10MB 제한 JSONL 저장
public final class DiagnosticLogger: @unchecked Sendable {
    /// - 목적: 앱 운영용 로거, XCTest에서는 임시 저장소·비활성 운영 기능 사용
    public static let shared = makeShared()
    /// - 목적: 관리 대상 JSONL의 기본 총 바이트 상한
    public static let defaultMaximumBytes = 10_000_000
    /// - 목적: 진단 기록의 기본 보존 기간(초)
    public static let defaultMaximumAge: TimeInterval = 604_800

    private static let maximumSegmentBytes = 256 * 1024
    private static let directoryMode: mode_t = 0o700
    private static let fileMode: mode_t = 0o600
    private static let lockFileName = ".diagnostic.lock"
    private static let timerInterval: TimeInterval = 60

    private let directory: URL
    private let now: @Sendable () -> Date
    private let maxBytes: Int
    private let maxAge: TimeInterval
    private let sessionID = UUID().uuidString.lowercased()
    private let storageQueue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let osLogEnabled: Bool
    private let osLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CodexQuotaMonitor", category: "DiagnosticLogger")
    private var segmentCache: [String: CachedSegment] = [:]
    private var timer: DispatchSourceTimer?

    /// - 목적: 테스트 프로세스의 실사용 로그 저장·OSLog·타이머 격리
    private static func makeShared() -> DiagnosticLogger {
        let arguments = ProcessInfo.processInfo.arguments
        let testArgument = arguments.contains {
            $0.hasSuffix(".xctest") || $0.hasSuffix(".xctest/") || $0.contains(".xctest/Contents/")
        }
        let testEnvironment = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"]?.isEmpty == false
        guard testArgument || testEnvironment else { return DiagnosticLogger() }
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexQuotaMonitor-tests-\(getpid())", isDirectory: true)
        return DiagnosticLogger(directory: testDirectory, osLogEnabled: false, timerEnabled: false)
    }

    /// - 목적: 저장 경로·시계·보관 한도·운영 기능 주입
    /// - 매개변수: directory — 기본 로그 디렉터리, now — 주입 시계, maxBytes/maxAge — 보관 상한
    /// - 매개변수: osLogEnabled/timerEnabled — OSLog·주기 정리 전환
    public init(
        directory: URL? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        maxBytes: Int = DiagnosticLogger.defaultMaximumBytes,
        maxAge: TimeInterval = DiagnosticLogger.defaultMaximumAge,
        osLogEnabled: Bool = true,
        timerEnabled: Bool = true
    ) {
        self.directory = (directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CodexQuotaMonitor", isDirectory: true)).standardizedFileURL
        self.now = now
        self.maxBytes = min(Self.defaultMaximumBytes, max(1, maxBytes))
        self.maxAge = maxAge.isFinite
            ? min(Self.defaultMaximumAge, max(0, maxAge))
            : Self.defaultMaximumAge
        self.osLogEnabled = osLogEnabled
        storageQueue = DispatchQueue(label: "CodexQuotaMonitor.DiagnosticLogger.storage", qos: .utility)
        storageQueue.setSpecific(key: queueKey, value: 1)

        storageQueue.async { [weak self] in
            self?.maintainStorage()
        }
        if timerEnabled {
            let source = DispatchSource.makeTimerSource(queue: storageQueue)
            source.schedule(deadline: .now() + Self.timerInterval, repeating: Self.timerInterval, leeway: .seconds(10))
            source.setEventHandler { [weak self] in
                self?.maintainStorage()
            }
            source.resume()
            timer = source
        }
    }

    /// - 목적: 제한된 진단 이벤트의 비동기 기록과 OSLog 병행
    /// - 매개변수: event — 고정 이벤트, level — 기록 수준, operationID — 제어된 작업 식별자
    /// - 매개변수: accountID — C1–C4 슬롯, fields — 허용된 진단 필드
    public func record(
        _ event: DiagnosticEvent,
        level: DiagnosticLevel = .notice,
        operationID: UUID? = nil,
        accountID: String? = nil,
        fields: [DiagnosticField: DiagnosticValue] = [:]
    ) {
        let timestamp = now()
        guard Self.validTimestamp(timestamp) else { return }
        let safeOperationID = operationID?.uuidString.lowercased()
        let safeAccountID = accountID.flatMap { Self.validAccountID($0) ? $0 : nil }
        let safeFields = Self.sanitizedFields(fields)
        let line = Self.encodeLine(
            timestamp: timestamp,
            sessionID: sessionID,
            event: event,
            level: level,
            operationID: safeOperationID,
            accountID: safeAccountID,
            fields: safeFields
        )

        storageQueue.async { [weak self] in
            guard let self else { return }
            self.mirrorToOSLog(event: event, level: level, line: line)
            guard let line else {
                self.reportStorageFailure()
                return
            }
            self.withStorageLock { directoryFD in
                var segments = self.maintainLocked(directoryFD: directoryFD, at: self.now())
                segments = self.enforceCapacity(segments: segments, directoryFD: directoryFD)
                guard timestamp >= self.now().addingTimeInterval(-self.maxAge) else { return }
                guard let appended = self.append(line, timestamp: timestamp, segments: segments, directoryFD: directoryFD) else {
                    self.reportStorageFailure()
                    return
                }
                segments = appended
                _ = self.enforceCapacity(segments: segments, directoryFD: directoryFD)
            }
        }
    }

    /// - 목적: 비동기 보관 정책 정리 요청
    public func maintain() {
        storageQueue.async { [weak self] in
            self?.maintainStorage()
        }
    }

    /// - 목적: 대기 중인 기록·정리 작업의 동기 배출
    public func flush() {
        guard DispatchQueue.getSpecific(key: queueKey) == nil else { return }
        storageQueue.sync {}
    }

    /// - 목적: 로거 해제 시 주기 타이머 종료
    deinit {
        timer?.cancel()
    }

    /// - 목적: 저장소 잠금 아래 만료·손상·용량 정책 적용
    private func maintainStorage() {
        withStorageLock { directoryFD in
            let date = now()
            let segments = maintainLocked(directoryFD: directoryFD, at: date)
            _ = enforceCapacity(segments: segments, directoryFD: directoryFD)
        }
    }

    /// - 목적: 저장 디렉터리 검증 및 프로세스 간 배타 잠금
    /// - 반환: 안전한 디렉터리 파일 디스크립터를 전달한 작업 결과
    private func withStorageLock(_ body: (Int32) -> Void) {
        guard let directoryFD = openDirectory() else {
            reportStorageFailure()
            return
        }
        defer { _ = close(directoryFD) }

        let lockFD = openat(directoryFD, Self.lockFileName, O_RDWR | O_CREAT | O_NOFOLLOW, Self.fileMode)
        guard lockFD >= 0 else {
            reportStorageFailure()
            return
        }
        defer { _ = close(lockFD) }

        var lockInfo = stat()
        guard fstat(lockFD, &lockInfo) == 0,
              Self.isOwnedRegularFile(lockInfo),
              fchmod(lockFD, Self.fileMode) == 0,
              flock(lockFD, LOCK_EX) == 0 else {
            reportStorageFailure()
            return
        }
        defer { _ = flock(lockFD, LOCK_UN) }
        body(directoryFD)
    }

    /// - 목적: 디렉터리 생성·소유권·형식·권한 검증
    /// - 반환: 심볼릭 링크가 아닌 전용 디렉터리 파일 디스크립터
    private func openDirectory() -> Int32? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            var existing = stat()
            guard lstat(directory.path, &existing) == 0 else { return nil }
        }

        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0,
              (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
              directoryInfo.st_uid == geteuid() else { return nil }

        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else { return nil }
        var openedInfo = stat()
        guard fstat(directoryFD, &openedInfo) == 0,
              (openedInfo.st_mode & S_IFMT) == S_IFDIR,
              openedInfo.st_uid == geteuid(),
              fchmod(directoryFD, Self.directoryMode) == 0 else {
            _ = close(directoryFD)
            return nil
        }
        return directoryFD
    }

    /// - 목적: 만료 행·잘못된 행 제거와 조각 크기 제한 적용
    private func maintainLocked(directoryFD: Int32, at date: Date) -> [Segment] {
        removeOrphanTemporaryFiles(directoryFD: directoryFD)
        let cutoff = date.addingTimeInterval(-maxAge)
        var normalized: [Segment] = []
        for segment in readSegments(directoryFD: directoryFD) {
            let retained = segment.rows.filter { $0.timestamp >= cutoff }
            let retainedBytes = retained.reduce(0) { $0 + $1.data.count + 1 }
            guard retainedBytes != segment.originalByteCount || segment.originalByteCount > Self.maximumSegmentBytes else {
                normalized.append(segment)
                continue
            }
            guard let rewritten = rewrite(segment: segment, rows: retained, directoryFD: directoryFD) else {
                reportStorageFailure()
                normalized.append(segment)
                continue
            }
            normalized.append(contentsOf: rewritten)
        }
        return normalized
    }

    /// - 목적: 중단된 원자 교체의 소유 임시 파일 정리
    private func removeOrphanTemporaryFiles(directoryFD: Int32) {
        let prefix = ".diagnostic-tmp-"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            guard name.hasPrefix(prefix), !name.contains("/"),
                  let info = fileInfo(name: name, directoryFD: directoryFD) else { continue }
            let identifier = String(name.dropFirst(prefix.count))
            guard identifier.count == 36,
                  UUID(uuidString: identifier)?.uuidString.lowercased() == identifier else { continue }

            var currentInfo = stat()
            guard fstatat(directoryFD, name, &currentInfo, AT_SYMLINK_NOFOLLOW) == 0,
                  Self.isOwnedRegularFile(currentInfo), Self.sameFile(info, currentInfo) else { continue }
            if unlinkat(directoryFD, name, 0) != 0 {
                reportStorageFailure()
            }
        }
    }

    /// - 목적: 관리 대상 JSONL 조각의 유효 행 로드
    /// - 반환: 소유·일반 파일에서 검증된 완전 행만 포함한 조각 목록
    private func readSegments(directoryFD: Int32) -> [Segment] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var validNames = Set<String>()
        let segments = names.compactMap { name -> Segment? in
            guard Self.isManagedFileName(name) else { return nil }
            guard let info = fileInfo(name: name, directoryFD: directoryFD) else {
                segmentCache.removeValue(forKey: name)
                return nil
            }
            guard info.st_size <= 10_000_000 else {
                _ = removeManagedFile(name, directoryFD: directoryFD)
                return nil
            }
            validNames.insert(name)
            if let cached = segmentCache[name], cached.matches(info) {
                return cached.segment
            }
            segmentCache.removeValue(forKey: name)
            let fileFD = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW)
            guard fileFD >= 0 else { return nil }
            defer { _ = close(fileFD) }
            var openedInfo = stat()
            guard fstat(fileFD, &openedInfo) == 0, Self.isOwnedRegularFile(openedInfo),
                  Self.sameFile(info, openedInfo), fchmod(fileFD, Self.fileMode) == 0,
                  fstat(fileFD, &openedInfo) == 0,
                  let data = Self.readAll(fileFD, maximumBytes: 10_000_000) else { return nil }
            let rows = Self.parseRows(data)
            let validRows = rows.compactMap { rawRow -> ParsedRow? in
                guard let parsed = Self.parseRow(rawRow) else { return nil }
                return ParsedRow(data: rawRow, timestamp: parsed)
            }
            let segment = Segment(
                name: name,
                rows: validRows,
                byteCount: Int(openedInfo.st_size),
                originalByteCount: Int(openedInfo.st_size),
                oldestTimestamp: validRows.map(\.timestamp).min() ?? .distantFuture,
                newestTimestamp: validRows.map(\.timestamp).max(),
                modificationTime: Self.modificationDate(openedInfo)
            )
            segmentCache[name] = CachedSegment(segment: segment, info: openedInfo)
            return segment
        }
        segmentCache = segmentCache.filter { validNames.contains($0.key) }
        return segments
    }

    /// - 목적: 만료·손상 제거 후 행 단위 조각 재작성
    /// - 반환: 원본 보존 또는 교체 성공 여부
    private func rewrite(segment: Segment, rows: [ParsedRow], directoryFD: Int32) -> [Segment]? {
        let chunks = Self.rowChunks(rows, maximumBytes: Self.maximumSegmentBytes)
        if chunks.count <= 1 {
            let data = chunks.first.map { Self.data(for: $0) } ?? Data()
            if data.isEmpty { return removeManagedFile(segment.name, directoryFD: directoryFD) ? [] : nil }
            guard atomicReplace(name: segment.name, data: data, directoryFD: directoryFD),
                  let info = fileInfo(name: segment.name, directoryFD: directoryFD) else { return nil }
            let segment = Self.makeSegment(name: segment.name, rows: chunks[0], byteCount: data.count, info: info)
            segmentCache[segment.name] = CachedSegment(segment: segment, info: info)
            return [segment]
        }

        var created: [String] = []
        var rewritten: [Segment] = []
        for chunk in chunks {
            guard let first = chunk.first,
                  let name = createSegment(chunk, timestamp: first.timestamp, directoryFD: directoryFD) else {
                created.forEach { _ = removeManagedFile($0, directoryFD: directoryFD) }
                return nil
            }
            created.append(name)
            guard let info = fileInfo(name: name, directoryFD: directoryFD) else {
                created.forEach { _ = removeManagedFile($0, directoryFD: directoryFD) }
                return nil
            }
            let segment = Self.makeSegment(name: name, rows: chunk, byteCount: Self.data(for: chunk).count, info: info)
            segmentCache[name] = CachedSegment(segment: segment, info: info)
            rewritten.append(segment)
        }
        guard removeManagedFile(segment.name, directoryFD: directoryFD) else {
            created.forEach { _ = removeManagedFile($0, directoryFD: directoryFD) }
            return nil
        }
        return rewritten
    }

    /// - 목적: 기록 시점 만료·손상 정리 후 새 행 추가
    /// - 반환: 조각 추가 성공 여부
    private func append(_ line: Data, timestamp: Date, segments: [Segment], directoryFD: Int32) -> [Segment]? {
        let ordered = segments.sorted {
            if $0.modificationTime == $1.modificationTime { return $0.name < $1.name }
            return $0.modificationTime < $1.modificationTime
        }
        let newestTimestamp = ordered.compactMap(\.newestTimestamp).max()
        if let active = ordered.last,
           let activeNewestTimestamp = active.newestTimestamp,
           activeNewestTimestamp == newestTimestamp,
           timestamp >= activeNewestTimestamp,
           active.originalByteCount + line.count + 1 <= Self.maximumSegmentBytes,
           append(line, to: active.name, directoryFD: directoryFD) {
            guard let info = fileInfo(name: active.name, directoryFD: directoryFD) else { return nil }
            let row = ParsedRow(data: line, timestamp: timestamp)
            let updated = Self.makeSegment(
                name: active.name,
                rows: active.rows + [row],
                byteCount: active.byteCount + line.count + 1,
                info: info
            )
            segmentCache[active.name] = CachedSegment(segment: updated, info: info)
            return Array(ordered.dropLast()) + [updated]
        }
        let row = ParsedRow(data: line, timestamp: timestamp)
        guard let name = createSegment([row], timestamp: timestamp, directoryFD: directoryFD),
              let info = fileInfo(name: name, directoryFD: directoryFD) else { return nil }
        let segment = Self.makeSegment(name: name, rows: [row], byteCount: line.count + 1, info: info)
        segmentCache[name] = CachedSegment(segment: segment, info: info)
        return ordered + [segment]
    }

    /// - 목적: 활성 조각에 완전 행 단위 추가
    /// - 반환: 파일 쓰기 성공 여부
    private func append(_ line: Data, to name: String, directoryFD: Int32) -> Bool {
        guard let before = fileInfo(name: name, directoryFD: directoryFD) else { return false }
        let fileFD = openat(directoryFD, name, O_WRONLY | O_APPEND | O_NOFOLLOW)
        guard fileFD >= 0 else { return false }
        defer { _ = close(fileFD) }
        var info = stat()
        guard fstat(fileFD, &info) == 0, Self.isOwnedRegularFile(info), info.st_ino == before.st_ino,
              fchmod(fileFD, Self.fileMode) == 0 else { return false }
        var bytes = line
        bytes.append(0x0A)
        return Self.writeAll(bytes, to: fileFD)
    }

    /// - 목적: 새 제한 크기 JSONL 조각 생성
    /// - 반환: 조각 파일명 또는 저장 실패
    private func createSegment(_ rows: [ParsedRow], timestamp: Date, directoryFD: Int32) -> String? {
        guard !rows.isEmpty else { return nil }
        let name = Self.segmentName(timestamp: timestamp)
        let fileFD = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, Self.fileMode)
        guard fileFD >= 0 else { return nil }
        var info = stat()
        let valid = fstat(fileFD, &info) == 0 && Self.isOwnedRegularFile(info) && fchmod(fileFD, Self.fileMode) == 0
        let succeeded = valid && Self.writeAll(Self.data(for: rows), to: fileFD)
        _ = close(fileFD)
        guard succeeded else {
            _ = unlinkat(directoryFD, name, 0)
            return nil
        }
        return name
    }

    /// - 목적: 임시 파일 작성 후 조각 원자 교체
    /// - 반환: 교체 성공 여부
    private func atomicReplace(name: String, data: Data, directoryFD: Int32) -> Bool {
        guard let original = fileInfo(name: name, directoryFD: directoryFD) else { return false }
        let temporaryName = ".diagnostic-tmp-\(UUID().uuidString.lowercased())"
        let temporaryFD = openat(directoryFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, Self.fileMode)
        guard temporaryFD >= 0 else { return false }
        var tempInfo = stat()
        let written = fstat(temporaryFD, &tempInfo) == 0 && Self.isOwnedRegularFile(tempInfo) &&
            fchmod(temporaryFD, Self.fileMode) == 0 && Self.writeAll(data, to: temporaryFD)
        _ = close(temporaryFD)
        guard written else {
            _ = unlinkat(directoryFD, temporaryName, 0)
            return false
        }

        guard let latest = fileInfo(name: name, directoryFD: directoryFD), latest.st_ino == original.st_ino,
              renameat(directoryFD, temporaryName, directoryFD, name) == 0 else {
            _ = unlinkat(directoryFD, temporaryName, 0)
            return false
        }
        return true
    }

    /// - 목적: 유효 조각의 전체 바이트 합을 설정 한도 이하로 축소
    private func enforceCapacity(segments input: [Segment], directoryFD: Int32) -> [Segment] {
        var segments = input.sorted {
            if $0.oldestTimestamp == $1.oldestTimestamp { return $0.name < $1.name }
            return $0.oldestTimestamp < $1.oldestTimestamp
        }
        var total = segments.reduce(0) { $0 + $1.byteCount }
        while total > maxBytes, segments.count > 1 {
            let oldest = segments.removeFirst()
            guard removeManagedFile(oldest.name, directoryFD: directoryFD) else {
                reportStorageFailure()
                return [oldest] + segments
            }
            total -= oldest.byteCount
        }
        guard total > maxBytes, let newest = segments.first else { return segments }

        var remaining: [ParsedRow] = []
        var retainedBytes = 0
        for row in newest.rows.reversed() {
            let rowBytes = row.data.count + 1
            guard retainedBytes + rowBytes <= maxBytes else { break }
            remaining.append(row)
            retainedBytes += rowBytes
        }
        remaining.reverse()
        guard let rewritten = rewrite(segment: newest, rows: remaining, directoryFD: directoryFD) else {
            reportStorageFailure()
            return segments
        }
        return Array(segments.dropLast()) + rewritten
    }

    /// - 목적: 소유한 관리 파일만 안전하게 제거
    /// - 반환: 제거 성공 또는 대상 부재 여부
    private func removeManagedFile(_ name: String, directoryFD: Int32) -> Bool {
        guard Self.isManagedFileName(name) else { return false }
        guard let info = fileInfo(name: name, directoryFD: directoryFD) else {
            segmentCache.removeValue(forKey: name)
            return true
        }
        let removed = unlinkat(directoryFD, name, 0) == 0 && info.st_uid == geteuid()
        if removed { segmentCache.removeValue(forKey: name) }
        return removed
    }

    /// - 목적: 파일 디스크립터 기준 파일 속성 확인
    /// - 반환: 일반·현재 사용자 소유의 링크되지 않은 파일 속성
    private func fileInfo(name: String, directoryFD: Int32) -> stat? {
        var info = stat()
        guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              Self.isOwnedRegularFile(info) else { return nil }
        return info
    }

    /// - 목적: 고정 이벤트와 허용 필드만 OSLog에 기록
    private func mirrorToOSLog(event: DiagnosticEvent, level: DiagnosticLevel, line: Data?) {
        guard osLogEnabled else { return }
        let safeRecord = line.flatMap { String(data: $0, encoding: .utf8) } ?? event.rawValue
        switch level {
        case .notice: osLogger.notice("diagnostic record: \(safeRecord, privacy: .public)")
        case .error: osLogger.error("diagnostic record: \(safeRecord, privacy: .public)")
        case .debug: osLogger.debug("diagnostic record: \(safeRecord, privacy: .public)")
        }
    }

    /// - 목적: 원문 오류 없이 고정 저장 실패 이벤트 출력
    private func reportStorageFailure() {
        guard osLogEnabled else { return }
        osLogger.error("diagnostic storage unavailable")
    }

    /// - 목적: 유효 식별자만 필드 맵에 반영
    private static func sanitizedFields(_ fields: [DiagnosticField: DiagnosticValue]) -> [DiagnosticField: DiagnosticValue] {
        fields.reduce(into: [:]) { result, item in
            switch item.value {
            case .integer, .boolean:
                result[item.key] = item.value
            case .timestamp(let date) where validTimestamp(date):
                result[item.key] = item.value
            case .identifier(let value) where validIdentifier(value):
                result[item.key] = item.value
            default:
                break
            }
        }
    }

    /// - 목적: 식별자 필드의 ASCII 허용 문자·길이 검증
    private static func validIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 80 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) ||
                (byte >= 97 && byte <= 122) || byte == 95 || byte == 46 || byte == 45
        }
    }

    /// - 목적: 계정 슬롯 식별자를 C1–C4로 제한
    private static func validAccountID(_ value: String) -> Bool {
        ["C1", "C2", "C3", "C4"].contains(value)
    }

    /// - 목적: ISO 8601 및 파일명 표현이 가능한 시각 범위 확인
    private static func validTimestamp(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && seconds >= -62_135_596_800 && seconds <= 253_402_300_799
    }

    /// - 목적: 진단 행을 정렬 키 JSONL 데이터로 인코딩
    private static func encodeLine(
        timestamp: Date,
        sessionID: String,
        event: DiagnosticEvent,
        level: DiagnosticLevel,
        operationID: String?,
        accountID: String?,
        fields: [DiagnosticField: DiagnosticValue]
    ) -> Data? {
        var object: [String: Any] = [
            "timestamp": format(timestamp),
            "sessionID": sessionID,
            "event": event.rawValue,
            "level": level.rawValue,
            "fields": fields.reduce(into: [String: Any]()) { result, pair in
                result[pair.key.rawValue] = encode(pair.value)
            }
        ]
        if let operationID { object["operationID"] = operationID }
        if let accountID { object["accountID"] = accountID }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// - 목적: 필드 값의 형식 정보를 포함한 JSON 표현 생성
    private static func encode(_ value: DiagnosticValue) -> [String: Any] {
        switch value {
        case .integer(let value): ["type": "integer", "value": value]
        case .boolean(let value): ["type": "boolean", "value": value]
        case .timestamp(let value): ["type": "timestamp", "value": format(value)]
        case .identifier(let value): ["type": "identifier", "value": value]
        }
    }

    /// - 목적: JSONL 한 행의 필수 구조·식별자·시간 검증
    /// - 반환: 파싱된 시각 또는 잘못된 행 표시
    private static func parseRow(_ data: Data) -> Date? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestamp = object["timestamp"] as? String,
              let date = parseDate(timestamp), validTimestamp(date),
              let sessionID = object["sessionID"] as? String, validIdentifier(sessionID),
              let event = object["event"] as? String, DiagnosticEvent(rawValue: event) != nil,
              let level = object["level"] as? String, DiagnosticLevel(rawValue: level) != nil,
              object["operationID"].map({ ($0 as? String).map(validIdentifier) ?? false }) ?? true,
              object["accountID"].map({ ($0 as? String).map(validAccountID) ?? false }) ?? true,
              let fields = object["fields"] as? [String: Any],
              fields.allSatisfy({ validField($0.key, value: $0.value) }) else { return nil }
        return date
    }

    /// - 목적: 저장 필드 이름과 명시된 값 형식 검증
    private static func validField(_ name: String, value: Any) -> Bool {
        guard DiagnosticField(rawValue: name) != nil,
              let typed = value as? [String: Any],
              let type = typed["type"] as? String,
              let rawValue = typed["value"] else { return false }
        switch type {
        case "integer":
            guard let number = rawValue as? NSNumber else { return false }
            return CFGetTypeID(number) != CFBooleanGetTypeID()
        case "boolean":
            guard let number = rawValue as? NSNumber else { return false }
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        case "timestamp":
            return (rawValue as? String).flatMap(parseDate) != nil
        case "identifier":
            return (rawValue as? String).map(validIdentifier) ?? false
        default:
            return false
        }
    }

    /// - 목적: 완전한 줄바꿈 행만 JSONL 후보로 분리
    private static func parseRows(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        var rows: [Data] = []
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: 0x0A) {
            if newline > start { rows.append(data.subdata(in: start..<newline)) }
            start = data.index(after: newline)
        }
        return rows
    }

    /// - 목적: 보관 행을 최대 조각 크기 이하의 연속 묶음으로 분할
    private static func rowChunks(_ rows: [ParsedRow], maximumBytes: Int) -> [[ParsedRow]] {
        var chunks: [[ParsedRow]] = []
        var current: [ParsedRow] = []
        var currentBytes = 0
        for row in rows {
            let size = row.data.count + 1
            if !current.isEmpty && currentBytes + size > maximumBytes {
                chunks.append(current)
                current = []
                currentBytes = 0
            }
            guard size <= maximumBytes else { continue }
            current.append(row)
            currentBytes += size
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// - 목적: JSONL 행 묶음의 줄바꿈 포함 데이터 생성
    private static func data(for rows: [ParsedRow]) -> Data {
        var data = Data()
        for row in rows {
            data.append(row.data)
            data.append(0x0A)
        }
        return data
    }

    /// - 목적: 파일명 정렬용 밀리초 시간과 무작위 식별자 생성
    private static func segmentName(timestamp: Date) -> String {
        let milliseconds = Int64(timestamp.timeIntervalSince1970 * 1_000)
        return String(format: "diagnostic-%013lld-%@.jsonl", milliseconds, UUID().uuidString.lowercased())
    }

    /// - 목적: 관리 파일명 패턴 확인
    private static func isManagedFileName(_ name: String) -> Bool {
        name.hasPrefix("diagnostic-") && name.hasSuffix(".jsonl") && !name.contains("/")
    }

    /// - 목적: 파일 속성의 일반 파일·현재 사용자 소유·단일 링크 확인
    private static func isOwnedRegularFile(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == geteuid() && info.st_nlink == 1
    }

    /// - 목적: UTC ISO 8601 시각 표현 생성
    private static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// - 목적: ISO 8601 시각을 보존 시각으로 변환
    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    /// - 목적: 잠금 파일에서 전체 데이터를 읽기
    private static func readAll(_ fileDescriptor: Int32, maximumBytes: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fileDescriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard data.count + count <= maximumBytes else { return nil }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    /// - 목적: 파일 속성을 보관 조각 모델로 변환
    private static func makeSegment(name: String, rows: [ParsedRow], byteCount: Int, info: stat) -> Segment {
        return Segment(
            name: name,
            rows: rows,
            byteCount: byteCount,
            originalByteCount: byteCount,
            oldestTimestamp: rows.map(\.timestamp).min() ?? .distantFuture,
            newestTimestamp: rows.map(\.timestamp).max(),
            modificationTime: modificationDate(info)
        )
    }

    /// - 목적: 파일 수정 시각을 Date로 변환
    private static func modificationDate(_ info: stat) -> Date {
        Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }

    /// - 목적: 파일명·크기·inode·수정 시각 일치 확인
    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size &&
            lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
            lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }

    /// - 목적: 전체 데이터를 파일 디스크립터에 기록
    private static func writeAll(_ data: Data, to fileDescriptor: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fileDescriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if count == 0 { return false }
                offset += count
            }
            return true
        }
    }

    /// - 목적: 검증된 JSONL 행과 기록 시각 보유
    private struct ParsedRow {
        let data: Data
        let timestamp: Date
    }

    /// - 목적: 조각 메타데이터와 파싱 결과 보유
    private struct Segment {
        let name: String
        let rows: [ParsedRow]
        let byteCount: Int
        let originalByteCount: Int
        let oldestTimestamp: Date
        let newestTimestamp: Date?
        let modificationTime: Date
    }

    /// - 목적: 변경되지 않은 조각의 파싱 결과 재사용
    private struct CachedSegment {
        let segment: Segment
        let inode: ino_t
        let size: off_t
        let mode: mode_t
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64

        /// - 목적: 현재 파일 메타데이터와 캐시 키 일치 확인
        func matches(_ info: stat) -> Bool {
            inode == info.st_ino && size == info.st_size && mode == (info.st_mode & 0o777) &&
                modifiedSeconds == Int64(info.st_mtimespec.tv_sec) &&
                modifiedNanoseconds == Int64(info.st_mtimespec.tv_nsec)
        }

        /// - 목적: 파일 속성에서 캐시 항목 생성
        init(segment: Segment, info: stat) {
            self.segment = segment
            inode = info.st_ino
            size = info.st_size
            mode = info.st_mode & 0o777
            modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        }
    }
}

/// - 목적: 고정 진단 이벤트 목록
public enum DiagnosticEvent: String, CaseIterable, Sendable {
    case appStarted
    case appTerminating
    case appWoke
    case cliDetected
    case probeRequested
    case probeRejected
    case probeStarted
    case probeFinished
    case probeResultApplied
    case probeResultDiscarded
    case probeCancelled
    case catalogStarted
    case catalogFinished
    case processStarted
    case processFinished
    case quotaRefreshStarted
    case quotaRefreshFinished
    case quotaResultApplied
    case quotaResultDiscarded
    case accountReconfigured
}

/// - 목적: OSLog·파일 진단 수준
public enum DiagnosticLevel: String, Sendable {
    case notice
    case error
    case debug
}

/// - 목적: 저장을 허용한 진단 필드 목록
public enum DiagnosticField: String, CaseIterable, Sendable {
    case generation
    case durationMS
    case exitCode
    case failure
    case status
    case model
    case version
    case build
    case cliVersion
    case forceFresh
    case applied
    case primaryResetBefore
    case primaryResetAfter
    case secondaryResetBefore
    case secondaryResetAfter
    case inputTokens
    case outputTokens
    case requestID
    case reason
}

/// - 목적: 진단 JSONL에 저장할 값 형식
public enum DiagnosticValue: Sendable {
    case integer(Int)
    case boolean(Bool)
    case timestamp(Date)
    case identifier(String)
}
