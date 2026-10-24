// 목적: 화면 수명과 독립적인 서버 사용량 조회·마지막 정상값 보존
// 이용처: 계정 상세의 서버 집계와 조회 상태
// 사용방법: 앱에서 loader 연결 후 계정 세대별 refresh 호출
import Combine
import Foundation

/// 슬롯·설정 세대·로그인 표시 계정별 단일 요청과 마지막 정상값 영속 캐시
@MainActor
public final class AccountTokenUsageStore: ObservableObject {
    public static let shared = AccountTokenUsageStore(databaseURL: TokenUsageSnapshotCache.defaultDatabaseURL)
    public typealias Loader = @MainActor (AccountState) async -> Result<AccountTokenUsage, CodexQuotaServiceError>
    public var loader: Loader = { _ in .failure(.notConfigured) }

    private struct Key: Hashable {
        let id: String
        let generation: Int
        let email: String?
        /// 계정 전환 전후 결과의 표시 범위 분리
        init(_ account: AccountState) {
            id = account.id; generation = account.configurationGeneration; email = account.email
        }
    }
    private struct Operation {
        let id: UUID
        let task: Task<Void, Never>
    }
    @Published private var snapshots: [Key: AccountTokenUsage] = [:]
    @Published private var failures: Set<Key> = []
    @Published private var operations: [Key: Operation] = [:]
    private var attemptedAt: [Key: Date] = [:]
    private let persistence: SQLiteAccountTokenUsageStore?
    private var homes: [String: String] = [:]
    private var loadedHomes: Set<String> = []
    private var persistedSnapshots: [String: AccountTokenUsage] = [:]
    @Published public private(set) var persistenceError: String?

    /// 운영용 SQLite 또는 영속 저장 없는 테스트용 저장소 초기화
    public init(databaseURL: URL? = nil) {
        persistence = databaseURL.map(SQLiteAccountTokenUsageStore.init)
    }

    /// 등록 경로의 마지막 정상값 복원; 서버 조회 없이 현재 계정 세대에 연결
    public func restore(accounts: [AccountState], homes configuredHomes: [String: URL], now: Date = Date()) {
        let nextHomes = configuredHomes.mapValues { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        for id in homes.keys where homes[id] != nextHomes[id] { invalidate(accountID: id) }
        let changed = homes != nextHomes
        homes = nextHomes
        do {
            var accessedDisk = changed
            var readFailed = false
            if changed { try persistence?.cleanup(homes: Set(homes.values), now: now) }
            for account in accounts where account.status != .notConfigured {
                guard let home = homes[account.id] else { continue }
                if !loadedHomes.contains(home) {
                    accessedDisk = true
                    do {
                        persistedSnapshots[home] = try persistence?.load(home: home, now: now)
                        loadedHomes.insert(home)
                    } catch {
                        readFailed = true
                        persistenceError = "마지막 토큰 사용량을 복원하지 못했습니다."
                        continue
                    }
                }
                guard snapshots[Key(account)] == nil, let snapshot = persistedSnapshots[home],
                      snapshot.fetchedAt.addingTimeInterval(SQLiteAccountTokenUsageStore.lifetime) > now,
                      account.email == nil || account.email == snapshot.accountEmail else { continue }
                snapshots[Key(account)] = snapshot
            }
            if accessedDisk && !readFailed { persistenceError = nil }
        } catch {
            persistenceError = "마지막 토큰 사용량을 복원하지 못했습니다."
        }
    }

    /// 현재 계정의 마지막 정상 서버 응답 조회
    public func snapshot(for account: AccountState) -> AccountTokenUsage? { snapshots[Key(account)] }
    /// 현재 계정의 조회 진행 여부
    public func isLoading(for account: AccountState) -> Bool { operations[Key(account)] != nil }
    /// 정상 캐시와 별도로 유지되는 마지막 조회 실패 여부
    public func hasFailed(for account: AccountState) -> Bool { failures.contains(Key(account)) }

    /// 자동 재진입은 5분 간격, 명시적 갱신은 즉시 실행
    @discardableResult
    public func refresh(for account: AccountState, force: Bool = false) -> Task<Void, Never>? {
        let key = Key(account)
        guard account.status != .notConfigured, operations[key] == nil else { return nil }
        if !force, let attempted = attemptedAt[key], Date().timeIntervalSince(attempted) < 300 { return nil }
        attemptedAt[key] = Date()
        let id = UUID()
        let task = Task { @MainActor in
            let result = await loader(account)
            guard !Task.isCancelled, operations[key]?.id == id else { return }
            switch result {
            case let .success(snapshot):
                snapshots[key] = snapshot
                failures.remove(key)
                if let home = homes[account.id] {
                    persistedSnapshots[home] = snapshot
                    do {
                        try persistence?.save(snapshot, home: home)
                        persistenceError = nil
                    } catch { persistenceError = "토큰 사용량을 저장하지 못했습니다. 재실행 시 마지막 조회 결과가 표시되지 않을 수 있습니다." }
                }
            case .failure: failures.insert(key)
            }
            operations[key] = nil
        }
        operations[key] = Operation(id: id, task: task)
        return task
    }

    /// 변경된 슬롯의 요청·캐시만 제거하여 다른 계정의 정상 결과 유지
    public func invalidate(accountID: String) {
        for (key, operation) in operations where key.id == accountID {
            operation.task.cancel()
            operations[key] = nil
        }
        snapshots = snapshots.filter { $0.key.id != accountID }
        failures = failures.filter { $0.id != accountID }
        attemptedAt = attemptedAt.filter { $0.key.id != accountID }
        if let home = homes[accountID] {
            persistedSnapshots[home] = nil
            loadedHomes.remove(home)
            do { try persistence?.remove(home: home) }
            catch { persistenceError = "변경된 계정의 토큰 사용량 캐시를 정리하지 못했습니다." }
        }
    }

    /// 종료 시 이전 요청·메모리만 정리하고 디스크의 정상 조회 결과 보존
    public func invalidateAll() {
        for operation in operations.values { operation.task.cancel() }
        operations.removeAll(); snapshots.removeAll(); failures.removeAll(); attemptedAt.removeAll()
        persistedSnapshots.removeAll(); loadedHomes.removeAll()
    }
}
