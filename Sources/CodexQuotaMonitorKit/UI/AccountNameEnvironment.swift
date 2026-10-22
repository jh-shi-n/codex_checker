// 목적: 내부 슬롯 식별자와 분리한 계정 표시 이름 전달
// 이용처: 노치 도넛·계정 상세·활동 알림의 화면 표시
// 사용방법: 최상위 화면에서 accountDisplayNames 환경값 주입
// 실행 예시: view.environment(\.accountDisplayNames, ["C1": "업무"])
import SwiftUI

/// 표시 전용 계정 이름의 기본 환경값
private struct AccountDisplayNamesKey: EnvironmentKey {
    static let defaultValue: [String: String] = [:]
}

extension EnvironmentValues {
    /// 캐시 키나 계정 식별자에 영향을 주지 않는 표시 이름 매핑
    public var accountDisplayNames: [String: String] {
        get { self[AccountDisplayNamesKey.self] }
        set { self[AccountDisplayNamesKey.self] = newValue }
    }
}
