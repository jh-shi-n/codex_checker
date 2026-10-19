// 목적: 할당량 조기 리셋의 macOS 시각 알림 전달
// 이용처: 앱 시작 시 권한 요청 및 계정 갱신 이벤트 처리
// 사용방법: start 호출 후 notify에 조기 리셋 이벤트 전달
import Foundation
import OSLog
import UserNotifications
import CodexQuotaMonitorKit

/// 앱 번들의 알림 권한과 전면 실행 중 배너 표시 관리
@MainActor
final class QuotaResetNotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter?
    private let logger = Logger(subsystem: "com.example.codexquotamonitor", category: "QuotaResetNotification")
    private var authorizationTask: Task<Bool, Never>?

    /// 번들이 없는 swift run 실행에서는 시스템 알림 센터 접근 제외
    override init() {
        center = Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil
        super.init()
    }

    /// 최초 앱 실행 시 시각 알림 권한 요청 및 전면 알림 대리자 연결
    func start() {
        guard let center, authorizationTask == nil else { return }
        center.delegate = self
        authorizationTask = Task { [logger] in
            do {
                return try await center.requestAuthorization(options: [.alert])
            } catch {
                logger.error("알림 권한 요청 실패: \(error.localizedDescription, privacy: .private)")
                return false
            }
        }
    }

    /// 계정별 동시 초기화를 하나의 무음 배너로 전달
    func notify(_ reset: EarlyQuotaReset) {
        guard let center else { return }
        Task { [authorizationTask, logger] in
            _ = await authorizationTask?.value
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
            else { return }
            let content = UNMutableNotificationContent()
            content.title = "할당량 조기 리셋"
            let windows = reset.windows.map(\.title).joined(separator: ", ")
            content.body = "\(reset.accountID)의 \(windows)가 예정 시각보다 일찍 초기화되었습니다."
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            do {
                try await center.add(request)
            } catch {
                logger.error("할당량 리셋 알림 전달 실패: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// 앱이 전면에 있는 동안에도 배너와 알림 센터에 표시
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
