// 목적: 앱 시작·종료·절전 복귀 및 토큰 집계 만료 정리
// 이용처: 앱 위임자의 macOS 수명주기 콜백
// 사용방법: NSApplicationDelegate 이벤트를 통한 자동 호출
@preconcurrency import AppKit
import CodexQuotaMonitorKit

extension CodexQuotaMonitorAppDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        installWakeObserver()
        quotaResetNotifications.start()
        quotaResetScheduler.start()
        lifecycleCoordinator.launch()
        openAccountSetupIfNeeded()
        Task { await sessionActivityMonitor.start() }
        tokenCleanupTask = Task { [tokenUsageCache, preferences] in
            while !Task.isCancelled {
                await tokenUsageCache.purgeExpired()
                preferences.cleanupQuotaSnapshots()
                do { try await Task.sleep(for: .seconds(60)) }
                catch { return }
            }
        }
        if let status = lifecycleCoordinator.launchAtLoginStatus {
            effectiveLaunchAtLoginStatus = status
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = notification
        sessionActivityDelivery.stop()
        quotaResetScheduler.stop()
        UsageWindowProbeStore.shared.cancelAll()
        serviceStatus.cancel()
        emptyAccountsPopover?.performClose(nil)
        emptyAccountsPopover = nil
        tokenCleanupTask?.cancel()
        tokenCleanupTask = nil
        if let hiddenAccountsStatusItem {
            NSStatusBar.system.removeStatusItem(hiddenAccountsStatusItem)
            self.hiddenAccountsStatusItem = nil
        }
        activityToastCancellable?.cancel()
        activityToastCancellable = nil
        Task { await sessionActivityMonitor.stop() }
        lifecycleCoordinator.terminate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        statesCancellable?.cancel()
        statesCancellable = nil
        fallbackSettingsWindow?.close()
        fallbackSettingsWindow = nil
        accountSetupModel?.cancelCheck()
        accountSetupWindow?.close()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        _ = sender
        return false
    }

    private func installWakeObserver() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.tokenUsageCache.purgeExpired()
                self?.preferences.cleanupQuotaSnapshots()
                await self?.lifecycleCoordinator.wake()
                await self?.quotaResetScheduler.tick()
            }
        }
    }
}
