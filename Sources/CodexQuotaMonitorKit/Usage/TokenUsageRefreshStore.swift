// 목적: 상세 화면 수명과 독립적인 계정별 토큰 새로고침 유지
// 이용처: 계정 상세의 진행 상태·완료 결과 복원 및 앱 종료 정리
// 사용방법: start 호출 후 isRunning·result 조회
import Combine
import Foundation

/// 계정 전환·팝오버 닫기 이후에도 로컬 집계와 캐시 저장 완료 보장
@MainActor
public final class TokenUsageRefreshStore: ObservableObject {
    public static let shared = TokenUsageRefreshStore()

    /// 같은 계정 슬롯의 경로 교체 전후 실행·결과 분리
    private struct Key: Hashable {
        let accountID: String
        let generation: Int

        /// 슬롯과 현재 설정 세대의 결합
        init(_ account: AccountState) {
            accountID = account.id
            generation = account.configurationGeneration
        }
    }

    /// 취소 후 재시작된 요청과 이전 응답의 완료 처리 분리
    private struct Operation {
        let id: UUID
        let task: Task<Void, Never>
    }

    @Published private var running: Set<Key> = []
    @Published private var results: [Key: TokenUsageSnapshot] = [:]
    private var operations: [Key: Operation] = [:]

    /// 현재 계정 설정의 집계·저장 진행 여부 조회
    func isRunning(for account: AccountState) -> Bool { running.contains(Key(account)) }

    /// 재진입 시 현재 설정 세대의 마지막 완료 결과 조회
    func result(for account: AccountState) -> TokenUsageSnapshot? { results[Key(account)] }

    /// 화면 대기 작업의 취소와 분리한 집계 실행 및 동일 계정 중복 요청 차단
    @discardableResult
    func start(for account: AccountState, runner: @escaping TokenUsageSnapshotRefresh) -> Task<Void, Never>? {
        let key = Key(account)
        guard !running.contains(key) else { return nil }
        let operationID = UUID()
        running.insert(key)
        let task = Task { @MainActor in
            let snapshot = await runner(account)
            guard !Task.isCancelled, operations[key]?.id == operationID else { return }
            results[key] = snapshot
            operations[key] = nil
            running.remove(key)
        }
        operations[key] = Operation(id: operationID, task: task)
        return task
    }

    /// 앱 종료 시 실행 취소 및 이미 취소된 요청의 늦은 결과 반영 차단
    public func cancelAll() {
        for operation in operations.values { operation.task.cancel() }
        operations.removeAll()
        running.removeAll()
    }
}
