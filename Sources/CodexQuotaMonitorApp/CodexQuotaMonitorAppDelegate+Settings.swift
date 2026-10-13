// 목적: 설정 화면 바인딩과 앱 위임자 설정 변경 처리
@preconcurrency import AppKit
import SwiftUI

import CodexQuotaMonitorKit

extension CodexQuotaMonitorAppDelegate {
    func openSettings() {
        effectiveLaunchAtLoginStatus = lifecycleCoordinator.readLaunchAtLoginStatus()
        // Accessory apps can report `showSettingsWindow:` as handled without
        // actually presenting SwiftUI's Settings scene. Ring clicks therefore
        // use the concrete AppKit host directly and reuse it on later clicks.
        if fallbackSettingsWindow == nil {
            createFallbackSettingsWindow()
        } else {
            fallbackSettingsWindow?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createFallbackSettingsWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Quota Monitor Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 420)
        window.contentViewController = NSHostingController(rootView: makeSettingsView())
        window.center()
        fallbackSettingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    /// 목적: 설정 화면과 앱 위임자 저장·렌더 콜백 연결
    func makeSettingsView() -> SettingsView {
        SettingsView(
            refreshIntervalMinutes: Binding(
                get: { [weak self] in self?.preferences.refreshIntervalMinutes ?? 5 },
                set: { [weak self] value in self?.applyRefreshInterval(value) }
            ),
            accountPaths: Binding(
                get: { [weak self] in self?.preferences.accountPaths ?? [] },
                set: { [weak self] values in self?.applyAccountPaths(values) }
            ),
            launchAtLogin: Binding(
                get: { [weak self] in self?.effectiveLaunchAtLoginStatus == .enabled },
                set: { [weak self] enabled in self?.applyLaunchAtLogin(enabled) }
            ),
            showAccountLabels: Binding(
                get: { [weak self] in self?.preferences.showAccountLabels ?? false },
                set: { [weak self] enabled in self?.applyShowAccountLabels(enabled) }
            ),
            activityNotificationDurationSeconds: Binding(
                get: { [weak self] in
                    self?.preferences.activityNotificationDurationSeconds
                        ?? PreferencesStore.defaultActivityNotificationDurationSeconds
                },
                set: { [weak self] seconds in
                    self?.applyActivityNotificationDuration(seconds)
                }
            ),
            enabledAccountIDs: Binding(
                get: { [weak self] in
                    self?.preferences.enabledAccountIDs ?? PreferencesStore.defaultEnabledAccountIDs
                },
                set: { [weak self] ids in self?.applyEnabledAccountIDs(ids) }
            ),
            accountDisplayOrder: Binding(
                get: { [weak self] in
                    self?.preferences.accountDisplayOrder ?? PreferencesStore.defaultAccountDisplayOrder
                },
                set: { [weak self] ids in self?.applyAccountDisplayOrder(ids) }
            )
        )
    }

    private func applyRefreshInterval(_ minutes: Int) {
        let preferences = self.preferences
        lifecycleCoordinator.applyRefreshInterval(minutes: minutes) { value in
            preferences.updateRefreshInterval(minutes: value)
            return preferences.refreshIntervalMinutes
        }
    }

    private func applyAccountPaths(_ paths: [String]) {
        preferences.updateAccountPaths(paths)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.lifecycleCoordinator.reconfigure(paths: self.preferences.accountPaths)
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        switch launchAtLoginService.setEnabled(enabled) {
        case let .success(status):
            effectiveLaunchAtLoginStatus = status
            let effective = enabled ? status == .enabled : status == .disabled
            if effective {
                preferences.updateLaunchAtLogin(enabled)
            } else {
                presentLaunchAtLoginStatus(status, requestedEnabled: enabled)
            }
        case let .failure(error):
            effectiveLaunchAtLoginStatus = launchAtLoginService.status
            presentLaunchAtLoginFailure(error)
        }
    }

    private func applyShowAccountLabels(_ enabled: Bool) {
        preferences.updateShowAccountLabels(enabled)
        render(states: accountStore.states)
    }

    /// 목적: 활성 계정 설정 저장 후 현재 상태 재렌더
    private func applyEnabledAccountIDs(_ ids: [String]) {
        preferences.updateEnabledAccountIDs(ids)
        render(states: accountStore.states)
    }

    /// 목적: 계정 표시 순서 저장 후 현재 상태 재렌더
    private func applyAccountDisplayOrder(_ ids: [String]) {
        preferences.updateAccountDisplayOrder(ids)
        render(states: accountStore.states)
    }

    private func applyActivityNotificationDuration(_ seconds: Int) {
        preferences.updateActivityNotificationDuration(seconds: seconds)
        sessionActivityToastQueue.updateDuration(
            seconds: preferences.activityNotificationDurationSeconds
        )
    }

    private func presentLaunchAtLoginStatus(_ status: LaunchAtLoginStatus, requestedEnabled: Bool) {
        let message: String
        switch status {
        case .requiresApproval:
            presentLaunchAtLoginApproval()
            return
        case .notFound:
            message = "The packaged app was not found by macOS ServiceManagement."
        case .disabled:
            message = requestedEnabled
                ? "Launch at login remains disabled."
                : "Launch at login is disabled."
        case .enabled:
            message = "Launch at login is enabled."
        }
        presentLaunchAtLoginFailureMessage(message)
    }

    private func presentLaunchAtLoginApproval() {
        let alert = NSAlert()
        alert.messageText = "Approve launch at login"
        alert.informativeText = "macOS registered this app, but approval is required in System Settings > Login Items."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Login Items")
        alert.addButton(withTitle: "Cancel")

        if let settingsWindow = settingsHostWindow {
            alert.beginSheetModal(for: settingsWindow) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.launchAtLoginService.openSystemSettingsLoginItems()
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            launchAtLoginService.openSystemSettingsLoginItems()
        }
    }

    private func presentLaunchAtLoginFailure(_ error: LaunchAtLoginError) {
        presentLaunchAtLoginFailureMessage(error.localizedDescription)
    }

    private func presentLaunchAtLoginFailureMessage(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Launch at login was not changed"
        alert.informativeText = message
        alert.alertStyle = .warning
        if let settingsWindow = settingsHostWindow {
            alert.beginSheetModal(for: settingsWindow)
        } else {
            alert.runModal()
        }
    }

    private var settingsHostWindow: NSWindow? {
        if let fallbackSettingsWindow, fallbackSettingsWindow.isVisible {
            return fallbackSettingsWindow
        }
        if let keyWindow = NSApp.keyWindow, keyWindow.isVisible {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow, mainWindow.isVisible {
            return mainWindow
        }
        return nil
    }
}
