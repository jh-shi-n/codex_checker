// 목적: 비동기 작업의 진단 로그 문맥 전달
// 이용처: 메뉴 요청·Ping·할당량 갱신의 작업 ID 연결
// 사용방법: $operationID.withValue로 문맥 생성 후 record 호출
// 실행 예시: DiagnosticLogContext.record(.probeStarted, accountID: "C3")
import Foundation

/// 작업 전환 후에도 유지되는 요청 식별자와 테스트용 로그 대상
public enum DiagnosticLogContext {
    @TaskLocal public static var operationID: UUID?
    @TaskLocal public static var logger: DiagnosticLogger?

    /// 원문 데이터를 받지 않는 공통 로그 전달; Task.detached·DispatchQueue 진입 전 문맥 캡처 필요
    public static func record(
        _ event: DiagnosticEvent,
        level: DiagnosticLevel = .notice,
        accountID: String? = nil,
        fields: [DiagnosticField: DiagnosticValue] = [:]
    ) {
        (logger ?? .shared).record(
            event, level: level, operationID: operationID, accountID: accountID, fields: fields
        )
    }

    /// 벽시계 조정의 영향을 받지 않는 경과 시간의 밀리초 변환
    public static func elapsedMS(since uptime: TimeInterval) -> DiagnosticValue {
        .integer(Int(max(0, ProcessInfo.processInfo.systemUptime - uptime) * 1_000))
    }

    /// 두 한도의 시각 존재 여부와 전후 값을 원본 계정 정보 없이 추출
    public static func resetFields(before: AccountState? = nil, after: AccountState? = nil) -> [DiagnosticField: DiagnosticValue] {
        var fields: [DiagnosticField: DiagnosticValue] = [:]
        if let date = before?.primaryResetAt { fields[.primaryResetBefore] = .timestamp(date) }
        if let date = before?.secondaryResetAt { fields[.secondaryResetBefore] = .timestamp(date) }
        if let date = after?.primaryResetAt { fields[.primaryResetAfter] = .timestamp(date) }
        if let date = after?.secondaryResetAt { fields[.secondaryResetAfter] = .timestamp(date) }
        return fields
    }
}
