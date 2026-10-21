// 목적: 공용 서비스 상태의 스마일·우울 SVG 아이콘 로드
// 이용처: 구독 뱃지 옆 상태 버튼
// 사용방법: 서비스 이상 여부에 따라 번들 SVG 선택
import AppKit

/// 앱 번들의 벡터 자산을 한 번 로드하여 재사용하는 아이콘 제공자
@MainActor
enum OpenAIServiceStatusIcon {
    private static let smile = load("service-status-smile")
    private static let sad = load("service-status-sad")

    /// 정상은 스마일, 서비스 이상은 우울 표정 반환
    static func image(hasIssues: Bool) -> NSImage? {
        hasIssues ? sad : smile
    }

    /// Swift 패키지 리소스 번들의 원본 SVG 로드
    private static func load(_ name: String) -> NSImage? {
        let installedBundle = Bundle.main.resourceURL?
            .appendingPathComponent("CodexQuotaMonitor_CodexQuotaMonitorKit.bundle")
        let bundle = installedBundle.flatMap { Bundle(url: $0) } ?? Bundle.module
        guard let url = bundle.url(forResource: name, withExtension: "svg") else { return nil }
        return NSImage(contentsOf: url)
    }
}
