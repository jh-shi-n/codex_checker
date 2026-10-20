import Foundation

/// 목적: 계정별 토큰 사용량 스냅샷 캐시
/// 이용처: 앱 대시보드의 마지막 성공 조회 결과
/// 사용방법: 계정 홈을 설정하고 명시적 업데이트 또는 캐시 조회 호출
public actor TokenUsageSnapshotCache {
    /// 성공 스냅샷 보존 기간(초)
    public static let snapshotLifetime: TimeInterval = 14 * 24 * 60 * 60

    /// 앱 전용 Application Support 저장소 경로
    public static var defaultDatabaseURL: URL {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return supportDirectory
            .appendingPathComponent("CodexQuotaMonitor", isDirectory: true)
            .appendingPathComponent("token-usage.sqlite", isDirectory: false)
            .standardizedFileURL
    }

    private let provider: any TokenUsageProvider
    private let invalidationState: InvalidationState
    private let persistence: SQLiteTokenUsageSnapshotStore?
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private var accountHomes: [String: URL]
    private var snapshots: [String: Entry] = [:]

    /// 메모리 캐시 행과 만료 정보
    private struct Entry: Sendable {
        let token: InvalidationState.Token
        let snapshot: TokenUsageSnapshot
        let updatedAt: Date
        let expiresAt: Date
        let homeIdentity: String?
    }

    /// 캐시 저장소와 현재 계정 홈 초기화
    public init(
        provider: any TokenUsageProvider = LocalTokenUsageProvider(),
        databaseURL: URL? = nil,
        accountHomes: [String: URL] = [:],
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.provider = provider
        self.invalidationState = InvalidationState()
        self.persistence = databaseURL.map { SQLiteTokenUsageSnapshotStore(databaseURL: $0) }
        self.now = now
        self.calendar = calendar
        self.accountHomes = Self.normalizedHomes(accountHomes)
    }

    /// 현재 계정의 유효한 스냅샷 조회와 저장소 복원
    public func cachedSnapshot(for accountID: String) -> TokenUsageSnapshot? {
        let referenceDate = now()
        purgeExpired(at: referenceDate)
        let token = invalidationState.current(for: accountID)
        let expectedIdentity = accountHomes[accountID].map(Self.homeIdentity)

        if let entry = snapshots[accountID],
           entry.token == token,
           entry.expiresAt > referenceDate,
           expectedIdentity == nil || entry.homeIdentity == expectedIdentity {
            return entry.snapshot.rebased(to: referenceDate, calendar: calendar)
        }
        snapshots.removeValue(forKey: accountID)

        guard let expectedIdentity,
              let record = invalidationState.optionalValueIfCurrent(token, accountID: accountID, {
                  persistence?.load(
                      accountID: accountID,
                      homeIdentity: expectedIdentity,
                      referenceDate: referenceDate
                  )
              }) ?? nil,
              let snapshot = try? TokenUsageSnapshotPayload.decode(record.payload) else {
            return nil
        }

        snapshots[accountID] = Entry(
            token: token,
            snapshot: snapshot,
            updatedAt: record.updatedAt,
            expiresAt: record.expiresAt,
            homeIdentity: expectedIdentity
        )
        return snapshot.rebased(to: referenceDate, calendar: calendar)
    }

    /// 호환용 스냅샷 조회 이름
    public func snapshot(for accountID: String) -> TokenUsageSnapshot? {
        cachedSnapshot(for: accountID)
    }

    /// 호출자가 보유한 스냅샷의 메모리 교체
    public func replace(_ snapshot: TokenUsageSnapshot, for accountID: String) {
        let completedAt = now()
        let token = invalidationState.beginRefresh(accountID: accountID)
        snapshots[accountID] = Entry(
            token: token,
            snapshot: snapshot,
            updatedAt: completedAt,
            expiresAt: completedAt.addingTimeInterval(Self.snapshotLifetime),
            homeIdentity: accountHomes[accountID].map(Self.homeIdentity)
        )
    }

    /// 명시적 조회 결과의 성공 교체와 영속 저장
    public func refresh(accountID: String, home: URL) async -> TokenUsageSnapshot {
        let homeIdentity = Self.homeIdentity(home)

        if let configuredHome = accountHomes[accountID],
           Self.homeIdentity(configuredHome) != homeIdentity {
            return await provider.snapshot(home: home)
        }

        if let entry = snapshots[accountID], entry.homeIdentity != homeIdentity {
            invalidationState.invalidate(accountID: accountID) {
                self.persistence?.remove(accountID: accountID)
            }
            snapshots.removeValue(forKey: accountID)
        }

        let requestDate = now()
        purgeExpired(at: requestDate)
        let token = invalidationState.beginRefresh(accountID: accountID)
        if let entry = snapshots[accountID],
           entry.homeIdentity == homeIdentity,
           entry.expiresAt > requestDate {
            snapshots[accountID] = Entry(
                token: token,
                snapshot: entry.snapshot,
                updatedAt: entry.updatedAt,
                expiresAt: entry.expiresAt,
                homeIdentity: entry.homeIdentity
            )
        }

        let snapshot = await provider.snapshot(home: home)
        guard invalidationState.current(for: accountID) == token else {
            return cachedSnapshot(for: accountID)
                ?? Self.supersededSnapshot(generatedAt: now())
        }
        guard snapshot.availability == .available else {
            return snapshot
        }

        let completedAt = now()
        let expiresAt = completedAt.addingTimeInterval(Self.snapshotLifetime)
        let payload: Data?
        if persistence != nil {
            payload = try? TokenUsageSnapshotPayload(snapshot: snapshot).encode()
        } else {
            payload = nil
        }
        guard let saved = invalidationState.valueIfCurrent(token, accountID: accountID, {
            guard let persistence = self.persistence else { return true }
            guard let payload else { return false }
            persistence.purgeExpired(beforeOrAt: completedAt)
            return persistence.save(
                payload: payload,
                accountID: accountID,
                homeIdentity: homeIdentity,
                updatedAt: completedAt,
                expiresAt: expiresAt
            )
        }) else {
            return cachedSnapshot(for: accountID)
                ?? Self.supersededSnapshot(generatedAt: now())
        }
        guard saved else {
            return Self.storageUnavailableSnapshot(from: snapshot, generatedAt: completedAt)
        }

        snapshots[accountID] = Entry(
            token: token,
            snapshot: snapshot,
            updatedAt: completedAt,
            expiresAt: expiresAt,
            homeIdentity: homeIdentity
        )
        return snapshot
    }

    /// 명시적 업데이트 호출 이름
    public func update(accountID: String, home: URL) async -> TokenUsageSnapshot {
        await refresh(accountID: accountID, home: home)
    }

    /// 계정 캐시와 영속 스냅샷 제거
    public func remove(accountID: String) {
        invalidationState.invalidate(accountID: accountID) {
            self.persistence?.remove(accountID: accountID)
        }
        snapshots.removeValue(forKey: accountID)
    }

    /// 계정 경로 변경 전에 진행 중 조회와 해당 계정의 영속 기록 무효화
    public nonisolated func invalidate(accountID: String) {
        invalidationState.invalidate(accountID: accountID) {
            persistence?.remove(accountID: accountID)
        }
        Task { await self.purgeExpired() }
    }

    /// 모든 메모리·영속 스냅샷 제거
    public func removeAll() {
        invalidateAll()
        snapshots.removeAll()
    }

    /// 모든 기존 조회를 무효화하고 오래된 영속 행 제거
    public nonisolated func invalidateAll() {
        let generation = invalidationState.invalidateAll {
            persistence?.removeAll()
        }
        Task { await self.removeEntries(olderThan: generation) }
    }

    /// 변경·제거된 계정의 캐시만 격리하고 다른 계정의 보관 기한 유지
    public func configureAccountHomes(_ homes: [String: URL]) {
        let normalized = Self.normalizedHomes(homes)
        guard Self.homeIdentities(accountHomes) != Self.homeIdentities(normalized) else {
            accountHomes = normalized
            return
        }
        let oldIdentities = Self.homeIdentities(accountHomes)
        let newIdentities = Self.homeIdentities(normalized)
        for accountID in Set(oldIdentities.keys).union(newIdentities.keys) {
            if oldIdentities[accountID] != newIdentities[accountID] {
                remove(accountID: accountID)
            }
        }
        accountHomes = normalized
    }

    /// 만료된 메모리·SQLite 스냅샷 정리
    public func purgeExpired() {
        purgeExpired(at: now())
    }

    /// 기준 시각까지 만료된 메모리·SQLite 행 제거
    private func purgeExpired(at referenceDate: Date) {
        snapshots = snapshots.filter { accountID, entry in
            entry.expiresAt > referenceDate
                && entry.token == invalidationState.current(for: accountID)
        }
        invalidationState.perform {
            persistence?.purgeExpired(beforeOrAt: referenceDate)
        }
    }

    /// 무효화 이전 세대의 메모리 행 제거
    private func removeEntries(olderThan generation: UInt64) {
        snapshots = snapshots.filter { _, entry in
            entry.token.generation >= generation
        }
    }

    /// 계정 홈 URL의 경로 정규화
    private static func normalizedHomes(_ homes: [String: URL]) -> [String: URL] {
        homes.mapValues { home in
            home.isFileURL
                ? home.resolvingSymlinksInPath().standardizedFileURL
                : home.standardizedFileURL
        }
    }

    /// 계정별 정규화 홈 식별자 생성
    private static func homeIdentities(_ homes: [String: URL]) -> [String: String] {
        homes.mapValues(homeIdentity)
    }

    /// 홈 경로의 안정적인 비교 키 생성
    private static func homeIdentity(_ home: URL) -> String {
        let normalized = home.isFileURL
            ? home.resolvingSymlinksInPath().standardizedFileURL
            : home.standardizedFileURL
        return normalized.isFileURL ? normalized.path : normalized.absoluteString
    }

    /// 영속 저장 실패를 조회 불가 결과로 표현
    private static func storageUnavailableSnapshot(
        from snapshot: TokenUsageSnapshot,
        generatedAt: Date
    ) -> TokenUsageSnapshot {
        TokenUsageSnapshot(
            generatedAt: generatedAt,
            dailyPoints: snapshot.dailyPoints.map { TokenUsageDailyPoint(date: $0.date) },
            today: .zero,
            last7Days: .zero,
            last30Days: .zero,
            totalSessions: 0,
            averageTokensPerSession: 0,
            availability: .unavailable,
            error: .storageUnavailable
        )
    }

    /// 최신 계정 요청으로 대체된 응답의 무효 결과
    private static func supersededSnapshot(generatedAt: Date) -> TokenUsageSnapshot {
        TokenUsageSnapshot(
            generatedAt: generatedAt,
            dailyPoints: [],
            availability: .unavailable,
            error: .superseded
        )
    }
}

private final class InvalidationState: @unchecked Sendable {
    /// 전체·계정 무효화 버전 조합
    struct Token: Equatable, Sendable {
        let generation: UInt64
        let accountRevision: UInt64
    }

    private let queue = DispatchQueue(label: "CodexQuotaMonitor.TokenUsageCacheInvalidation")
    private var generation: UInt64 = 0
    private var accountRevisions: [String: UInt64] = [:]

    /// 현재 전체·계정 무효화 버전 조회
    func current(for accountID: String) -> Token {
        queue.sync {
            Token(
                generation: generation,
                accountRevision: accountRevisions[accountID, default: 0]
            )
        }
    }

    /// 새 계정 갱신 요청의 이전 응답 무효화
    func beginRefresh(accountID: String) -> Token {
        queue.sync {
            accountRevisions[accountID, default: 0] &+= 1
            return Token(
                generation: generation,
                accountRevision: accountRevisions[accountID, default: 0]
            )
        }
    }

    /// 무효화가 없을 때 optional 저장소 결과 반환
    func optionalValueIfCurrent<T>(
        _ token: Token,
        accountID: String,
        _ body: () -> T?
    ) -> T? {
        queue.sync {
            guard generation == token.generation,
                  accountRevisions[accountID, default: 0] == token.accountRevision else {
                return nil
            }
            return body()
        }
    }

    /// 무효화가 없을 때 저장소 작업 실행
    func valueIfCurrent<T>(
        _ token: Token,
        accountID: String,
        _ body: () -> T
    ) -> T? {
        queue.sync {
            guard generation == token.generation,
                  accountRevisions[accountID, default: 0] == token.accountRevision else {
                return nil
            }
            return body()
        }
    }

    /// 저장소 정리와 동시 접근 직렬화
    func perform<T>(_ body: () -> T) -> T {
        queue.sync(execute: body)
    }

    /// 계정 단위 무효화와 해당 계정 저장소 정리
    func invalidate(accountID: String, _ body: () -> Void) {
        queue.sync {
            accountRevisions[accountID, default: 0] &+= 1
            body()
        }
    }

    /// 전체 무효화와 저장소 정리의 원자적 순서
    func invalidateAll(_ body: () -> Void) -> UInt64 {
        queue.sync {
            generation &+= 1
            accountRevisions.removeAll(keepingCapacity: true)
            body()
            return generation
        }
    }
}
