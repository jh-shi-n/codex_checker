@preconcurrency import AppKit

extension CodexQuotaMonitorAppDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        installWakeObserver()
        lifecycleCoordinator.launch()
        Task { await sessionActivityMonitor.start() }
        if let status = lifecycleCoordinator.launchAtLoginStatus {
            effectiveLaunchAtLoginStatus = status
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = notification
        sessionActivityDelivery.stop()
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
                await self?.lifecycleCoordinator.wake()
            }
        }
    }
}
