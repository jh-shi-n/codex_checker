// 목적: 최초 계정 폴더의 검증·연결 확인·등록 가능 상태 관리
// 이용처: 경로 미등록 상태의 초기 연결 가이드
// 사용방법: 경로 입력 후 checkConnection 호출, 성공 시 registrationPath로 등록값 취득
import Combine
import Foundation

public typealias AccountSetupChecker = @Sendable (AccountConfig) async -> AccountState

/// 실제 경로 저장과 분리된 단일 계정 연결 초안
@MainActor
public final class AccountSetupModel: ObservableObject {
    /// 입력 전·확인 중·성공·실패의 화면 상태
    public enum Phase: Equatable, Sendable {
        case idle, checking, connected, failed
    }

    @Published public var path: String = "" {
        didSet { if path != oldValue { cancelCheck() } }
    }
    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var message: String?
    @Published public private(set) var connectedAccount: AccountState?

    public var canCheck: Bool { !validator.normalizedPath(path).isEmpty && phase != .checking }
    public var canFinish: Bool { phase == .connected && verifiedPath == validator.normalizedPath(path) }
    private let validator: AccountPathValidator
    private let checker: AccountSetupChecker
    private var verifiedPath: String?
    private var revision = 0
    private var operation: Task<AccountState, Never>?

    /// 경로 검증 정책과 실제 또는 테스트용 한도 조회 연결
    public init(
        validator: AccountPathValidator = .live,
        checker: @escaping AccountSetupChecker = { await CodexQuotaService().state(for: $0) }
    ) {
        self.validator = validator
        self.checker = checker
    }

    /// 유효한 폴더에서 사용자 요청 시에만 조회; 변경·취소된 경로의 늦은 성공 제외
    public func checkConnection() async {
        cancelCheck()
        let normalized = validator.normalizedPath(path)
        let validation = validator.validate(normalized)
        guard validation == .valid else {
            phase = .failed
            message = validation.userMessage ?? "계정 폴더를 선택해 주세요."
            return
        }
        let current = revision
        phase = .checking
        let config = AccountConfig(id: "C1", home: URL(fileURLWithPath: normalized), position: .left)
        let checker = self.checker
        let task = Task { await checker(config) }
        operation = task
        let account = await task.value
        guard revision == current, normalized == validator.normalizedPath(path), !Task.isCancelled else { return }
        operation = nil
        guard account.status == .normal else {
            phase = .failed
            message = Self.failureMessage(for: account.status)
            return
        }
        verifiedPath = normalized
        connectedAccount = account
        message = account.email.map { "\($0) 계정의 연결을 확인했습니다." } ?? "계정 연결을 확인했습니다."
        phase = .connected
    }

    /// 등록 직전 폴더 존재 여부 재확인; 저장은 앱 호스트에서만 수행
    public func registrationPath() -> String? {
        guard canFinish, let verifiedPath else { return nil }
        let validation = validator.validate(verifiedPath)
        guard validation == .valid else {
            cancelCheck()
            phase = .failed
            message = validation.userMessage ?? "계정 폴더를 다시 선택해 주세요."
            return nil
        }
        return verifiedPath
    }

    /// 입력 변경·창 닫기 시 실행 취소와 성공 상태 폐기
    public func cancelCheck() {
        revision += 1
        operation?.cancel()
        operation = nil
        verifiedPath = nil
        connectedAccount = nil
        message = nil
        phase = .idle
    }

    /// 인증·설치·네트워크 실패의 사용자 안내 변환
    private static func failureMessage(for status: AccountStatus) -> String {
        switch status {
        case .loginRequired: return "선택한 폴더의 Codex 계정에 로그인한 뒤 다시 확인해 주세요."
        case .codexNotFound: return "Codex CLI를 찾지 못했습니다. 설치한 뒤 다시 확인해 주세요."
        case .timeout: return "연결 확인 시간이 초과되었습니다. 네트워크 상태를 확인하고 다시 시도해 주세요."
        default: return "할당량을 확인하지 못했습니다. 계정 폴더와 로그인 상태를 확인해 주세요."
        }
    }
}
