// 목적: 파일별 숫자 체크포인트를 이용한 재시작 가능한 로컬 전체 집계
// 이용처: 명시적 토큰 업데이트와 장기간 기록의 분할 수집
// 사용방법: 앱 전용 cacheDirectory 지정 후 snapshot 호출; 원문 저장 제외
import CryptoKit
import Darwin
import Foundation

/// 완전한 탐색 결과만 반환하는 파일별 증분 수집기
public actor IncrementalTokenUsageProvider: TokenUsageRangeProvider {
    private struct Stamp: Codable, Equatable {
        let inode: UInt64
        let device: UInt64
        let size: UInt64
        let modified: Date
        let changed: Date
    }
    private struct Cursor: Codable {
        var stamp: Stamp
        var offset: UInt64 = 0
        var discarding = false
        var fingerprint: String?
        var accumulator = TokenRolloutAccumulator()
        /// EOF 미완성 행은 화면용 복사본에만 적용; 다음 추가 기록에서 재처리
        var provisional: TokenRolloutAccumulator?
    }
    private struct Checkpoint: Codable {
        var version = 1
        var context: String
        var referenceDay: Date?
        var files: [String: Cursor] = [:]
    }
    private let cacheDirectory: URL?
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let bytesPerPass: Int
    private let filesPerPass: Int
    private let maxLineBytes: Int
    private var homes: [String: Checkpoint] = [:]
    private var inFlight: Set<String> = []
    private var generation = 0
    public private(set) var lastReadBytes: Int = 0

    /// 한 패스당 읽기량·파일 수 제한; 전체 기록의 합계 제한과 분리
    public init(cacheDirectory: URL? = nil, calendar: Calendar = .autoupdatingCurrent,
                now: @escaping @Sendable () -> Date = { Date() },
                bytesPerPass: Int = 4 * 1024 * 1024, filesPerPass: Int = 512,
                maxLineBytes: Int = LocalTokenUsageProvider.defaultMaximumLineBytes) {
        self.cacheDirectory = cacheDirectory
        self.calendar = calendar
        self.now = now
        self.bytesPerPass = max(1, bytesPerPass)
        self.filesPerPass = max(1, filesPerPass)
        self.maxLineBytes = max(1, maxLineBytes)
    }

    /// 기본 보관 범위의 전체 로컬 집계
    public func snapshot(home: URL) async -> TokenUsageSnapshot {
        await snapshot(home: home, historyDayCount: TokenUsageSnapshot.historyDayCount)
    }

    /// 완료 전에는 정상 스냅샷 미공개; 취소·오류 시 숫자 체크포인트만 유지
    public func snapshot(home: URL, historyDayCount: Int) async -> TokenUsageSnapshot {
        let generatedAt = now()
        let cutoff = calendar.date(byAdding: .day, value: -(max(1, historyDayCount) - 1),
                                   to: calendar.startOfDay(for: generatedAt)) ?? generatedAt
        let aggregator = TokenUsageAggregator(calendar: calendar, dayCount: historyDayCount)
        guard home.isFileURL else { return aggregator.emptySnapshot(generatedAt: generatedAt, availability: .unavailable, error: .invalidHome) }
        let home = home.standardizedFileURL.resolvingSymlinksInPath()
        let key = home.path
        guard inFlight.insert(key).inserted else {
            return aggregator.emptySnapshot(generatedAt: generatedAt, availability: .unavailable, error: .superseded)
        }
        defer { inFlight.remove(key) }
        lastReadBytes = 0
        let startedGeneration = generation
        // 계정 홈 자체 교체·달력·시간대·보관 범위 변경 시 이전 날짜 배분 재사용 제외
        let identity = (try? stamp(home)).map { "\($0.device)|\($0.inode)" } ?? "missing"
        let context = "v1|\(identity)|\(calendar.identifier)|\(calendar.timeZone.identifier)|\(historyDayCount)|\(maxLineBytes)"
        var checkpoint = load(key: key, context: context)
        let today = calendar.startOfDay(for: generatedAt)
        if let previousDay = checkpoint.referenceDay, previousDay > today { checkpoint = Checkpoint(context: context) }
        checkpoint.referenceDay = today
        let parser = LocalTokenUsageProvider(calendar: calendar, now: now, historyDayCount: historyDayCount)
        var points: [TokenUsageDailyPoint] = []
        do {
            let root = home.appendingPathComponent("sessions", isDirectory: true).resolvingSymlinksInPath()
            let candidates = try files(in: root, parser: parser, referenceDate: generatedAt, dayCount: historyDayCount)
            let paths = Set(candidates.map(\.path))
            checkpoint.files = checkpoint.files.filter { paths.contains($0.key) }
            var remaining = bytesPerPass
            for (index, file) in candidates.enumerated() {
                try Task.checkCancellation()
                guard generation == startedGeneration else { throw CancellationError() }
                let before = try stamp(file)
                var cursor = checkpoint.files[file.path] ?? Cursor(stamp: before)
                let old = cursor.stamp
                let previousOffset = cursor.offset
                if old.inode != before.inode || old.device != before.device || before.size < old.size
                    || (before.size == old.size && (before.modified != old.modified || before.changed != old.changed)) {
                    cursor = Cursor(stamp: before)
                }
                if cursor.offset > before.size {
                    cursor = Cursor(stamp: before)
                } else if before.size > old.size, cursor.offset > 0 {
                    let currentFingerprint = try fingerprint(file, boundary: cursor.offset)
                    if cursor.fingerprint != currentFingerprint { cursor = Cursor(stamp: before) }
                }
                cursor.provisional = nil
                let handle = try FileHandle(forReadingFrom: file)
                do {
                    try handle.seek(toOffset: cursor.offset)
                    var readOffset = cursor.offset
                    var line = Data()
                    let directoryDate = parser.dateFromSessionsDirectory(for: file, sessionsURL: root)
                    while readOffset < before.size {
                        try Task.checkCancellation()
                        let count = min(64 * 1024, Int(min(UInt64(remaining), before.size - readOffset)))
                        guard let data = try handle.read(upToCount: count), !data.isEmpty else { throw CocoaError(.fileReadUnknown) }
                        lastReadBytes += data.count
                        remaining -= data.count
                        var start = data.startIndex
                        while start < data.endIndex {
                            let end = data[start...].firstIndex(of: 10) ?? data.endIndex
                            let fragment = data[start..<end]
                            if !cursor.discarding {
                                if line.count + fragment.count > maxLineBytes { line.removeAll(keepingCapacity: false); cursor.discarding = true }
                                else { line.append(contentsOf: fragment) }
                            }
                            readOffset += UInt64(fragment.count)
                            if end < data.endIndex {
                                readOffset += 1
                                if !cursor.discarding { parser.accumulate(Array(line), state: &cursor.accumulator, directoryDate: directoryDate) }
                                line.removeAll(keepingCapacity: true)
                                cursor.discarding = false
                                cursor.offset = readOffset
                                start = end + 1
                            } else {
                                if cursor.discarding { cursor.offset = readOffset }
                                start = end
                            }
                        }
                        if remaining == 0 {
                            cursor.accumulator.byDay = cursor.accumulator.byDay.filter { $0.key >= cutoff }
                            cursor.fingerprint = try fingerprint(file, boundary: cursor.offset)
                            checkpoint.files[file.path] = cursor
                            save(checkpoint, key: key)
                            await Task.yield()
                            guard generation == startedGeneration else { throw CancellationError() }
                            remaining = bytesPerPass
                        }
                    }
                    if !line.isEmpty, !cursor.discarding {
                        var provisional = cursor.accumulator
                        parser.accumulate(Array(line), state: &provisional, directoryDate: directoryDate)
                        cursor.provisional = provisional
                    }
                    try handle.close()
                } catch { try? handle.close(); throw error }
                // 읽기 도중 교체·덮어쓰기·축소 결과의 정상 집계 공개 제외
                let after = try stamp(file)
                guard before.inode == after.inode, before.device == after.device,
                      after.size >= before.size,
                      after.size != before.size || (after.modified == before.modified && after.changed == before.changed)
                else { checkpoint.files[file.path] = nil; throw CocoaError(.fileReadUnknown) }
                cursor.accumulator.byDay = cursor.accumulator.byDay.filter { $0.key >= cutoff }
                if var provisional = cursor.provisional {
                    provisional.byDay = provisional.byDay.filter { $0.key >= cutoff }
                    cursor.provisional = provisional
                }
                if cursor.fingerprint == nil || before != old || cursor.offset != previousOffset {
                    cursor.fingerprint = try fingerprint(file, boundary: cursor.offset)
                }
                cursor.stamp = before
                checkpoint.files[file.path] = cursor
                points.append(contentsOf: (cursor.provisional ?? cursor.accumulator).points)
                if (index + 1) % filesPerPass == 0 {
                    save(checkpoint, key: key)
                    await Task.yield()
                }
            }
            try Task.checkCancellation()
            guard generation == startedGeneration else { throw CancellationError() }
            save(checkpoint, key: key)
            return aggregator.aggregate(dailyPoints: points, generatedAt: generatedAt)
        } catch {
            if generation == startedGeneration { save(checkpoint, key: key) }
            return aggregator.emptySnapshot(generatedAt: generatedAt, availability: .unavailable,
                error: error is CancellationError ? .cancelled : .rolloutReadFailed)
        }
    }

    /// 보관 정책 변경 시 이전 날짜 체크포인트와 실행 중 결과 폐기
    public func invalidateAll() {
        generation += 1
        homes.removeAll()
        if let cacheDirectory { try? FileManager.default.removeItem(at: cacheDirectory) }
    }

    /// 심볼릭 링크 외부 경로를 제외한 전체 후보 수집; 파일 수 총량 제한 제외
    private func files(in root: URL, parser: LocalTokenUsageProvider, referenceDate: Date, dayCount: Int) throws -> [URL] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return [] }
        let resolvedRoot = root.resolvingSymlinksInPath()
        guard resolvedRoot.path == root.path, manager.isReadableFile(atPath: root.path) else { throw CocoaError(.fileReadNoPermission) }
        var failed = false
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles], errorHandler: { _, _ in failed = true; return false }) else { throw CocoaError(.fileReadUnknown) }
        var result: [URL] = []
        let today = calendar.startOfDay(for: referenceDate)
        let firstDay = calendar.date(byAdding: .day, value: -(max(1, dayCount) - 1), to: today) ?? today
        let latestDay = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { continue }
            if let directoryDate = parser.dateFromSessionsDirectory(for: url, sessionsURL: root) {
                guard directoryDate <= latestDay else { continue }
                if directoryDate < firstDay, try stamp(url).modified < firstDay { continue }
            }
            result.append(url)
        }
        if failed { throw CocoaError(.fileReadUnknown) }
        return result.sorted { $0.path < $1.path }
    }

    /// 파일 교체·크기·동일 크기 수정 감지를 위한 메타데이터
    private func stamp(_ url: URL) throws -> Stamp {
        var value = stat()
        guard Darwin.lstat(url.path, &value) == 0 else { throw CocoaError(.fileReadUnknown) }
        return Stamp(inode: UInt64(value.st_ino), device: UInt64(UInt32(bitPattern: value.st_dev)), size: UInt64(max(0, value.st_size)),
                     modified: Date(timeIntervalSince1970: Double(value.st_mtimespec.tv_sec) + Double(value.st_mtimespec.tv_nsec) / 1e9),
                     changed: Date(timeIntervalSince1970: Double(value.st_ctimespec.tv_sec) + Double(value.st_ctimespec.tv_nsec) / 1e9))
    }

    /// 추가 쓰기와 크기가 늘어난 덮어쓰기를 구분하는 시작·읽기 경계 지문
    private func fingerprint(_ url: URL, boundary: UInt64) throws -> String {
        guard boundary > 0 else { return "empty" }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let count = Int(min(1024, boundary))
        var data = Data(String(boundary).utf8)
        for offset in [UInt64(0), boundary - UInt64(count)] {
            try handle.seek(toOffset: offset)
            guard let part = try handle.read(upToCount: count), part.count == count else { throw CocoaError(.fileReadUnknown) }
            data.append(part)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 홈 경로의 해시를 파일명으로 사용한 숫자 전용 저장 위치
    private func cacheURL(_ key: String) -> URL? {
        cacheDirectory?.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".json")
    }

    /// 손상·버전·문맥 불일치 시 원본 재집계로 복구
    private func load(key: String, context: String) -> Checkpoint {
        if let cached = homes[key], cached.context == context { return cached }
        if let url = cacheURL(key), let data = try? Data(contentsOf: url),
           let cached = try? JSONDecoder().decode(Checkpoint.self, from: data), cached.version == 1, cached.context == context {
            return cached
        }
        return Checkpoint(context: context)
    }

    /// 실패 시에도 원본·정상 스냅샷을 변경하지 않는 원자적 체크포인트 저장
    private func save(_ checkpoint: Checkpoint, key: String) {
        if homes.count >= 4, homes[key] == nil, let first = homes.keys.first { homes[first] = nil }
        homes[key] = checkpoint
        guard let url = cacheURL(key) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        // EOF 원문 보관 제외; provisional 역시 숫자 상태만 포함
        if let data = try? JSONEncoder().encode(checkpoint) { try? data.write(to: url, options: [.atomic]) }
    }
}
