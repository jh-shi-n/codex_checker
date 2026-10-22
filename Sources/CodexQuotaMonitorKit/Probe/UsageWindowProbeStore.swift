// 목적: 상세 화면 수명과 독립적인 계정별 초기화 갱신 관리
// 이용처: 계정 상세의 실행 상태와 결과 복원
// 사용방법: start 호출 후 isRunning·presentation 조회
import Combine
import Foundation

/// 계정 전환과 팝오버 닫기 이후에도 갱신 작업과 결과 유지
@MainActor
public final class UsageWindowProbeStore: ObservableObject {
    public static let shared = UsageWindowProbeStore()

    /// 경로 변경 전후의 동일 슬롯 작업과 결과 분리
    private struct Key: Hashable {
        let id: String
        let generation: Int

        /// 계정 슬롯과 설정 세대로 식별자 생성
        init(_ account: AccountState) {
            id = account.id
            generation = account.configurationGeneration
        }
    }

    @Published private var running: Set<Key> = []
    @Published private var results: [Key: UsageWindowProbePresentationResult] = [:]
    private var tasks: [Key: Operation] = [:]

    /// 취소 후 재시작된 동일 계정 작업의 완료 처리 격리
    private struct Operation {
        let id: UUID
        let task: Task<Void, Never>
    }

    /// 현재 계정 설정에 속한 실행 상태 반환
    func isRunning(for account: AccountState) -> Bool {
        running.contains(Key(account))
    }

    /// 현재 계정 설정에 속한 마지막 실행 결과 반환
    func presentation(for account: AccountState) -> UsageWindowProbePresentationResult? {
        results[Key(account)]
    }

    /// 중복 실행 방지 및 화면 취소와 독립적인 Ping·한도 재조회 실행
    @discardableResult
    func start(for account: AccountState, runner: @escaping UsageWindowProbeRunner) -> Task<Void, Never>? {
        let key = Key(account)
        guard AccountDashboardActionState.canRunProbe(account: account, isRunning: running.contains(key)) else {
            return nil
        }
        running.insert(key)
        let operationID = UUID()
        let task = Task { @MainActor in
            defer {
                if tasks[key]?.id == operationID {
                    tasks[key] = nil
                    running.remove(key)
                }
            }
            let presentation = await runner(account)
            guard !Task.isCancelled else { return }
            if presentation.result.accountID == account.id, presentation.isCurrentAccount {
                results[key] = presentation
            }
        }
        tasks[key] = Operation(id: operationID, task: task)
        return task
    }

    /// 앱 종료 시 진행 중 Ping·한도 조회 취소 및 늦은 응답 반영 방지
    public func cancelAll() {
        for operation in tasks.values { operation.task.cancel() }
        tasks.removeAll()
        running.removeAll()
    }
}
