// 목적: 화면 수명과 독립적인 서버 사용량 조회·마지막 정상값 보존
// 이용처: 계정 상세의 서버 집계와 조회 상태
// 사용방법: 앱에서 loader 연결 후 계정 세대별 refresh 호출
import Combine
import Foundation

/// 슬롯·설정 세대·로그인 표시 계정별 단일 진행 요청과 메모리 캐시
@MainActor
public final class AccountTokenUsageStore: ObservableObject {
    public static let shared = AccountTokenUsageStore()
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
            case let .success(snapshot): snapshots[key] = snapshot; failures.remove(key)
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
    }

    /// 설정 변경·종료 시 이전 요청 취소와 늦은 응답 배제
    public func invalidateAll() {
        for operation in operations.values { operation.task.cancel() }
        operations.removeAll(); snapshots.removeAll(); failures.removeAll(); attemptedAt.removeAll()
    }
}
