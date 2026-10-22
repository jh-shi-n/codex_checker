// 목적: 등록 경로가 없는 사용자의 초기 연결 창과 저장 동작 연결
@preconcurrency import AppKit
import SwiftUI
import CodexQuotaMonitorKit

extension CodexQuotaMonitorAppDelegate: NSWindowDelegate {
    /// 최초 계정 등록 완료 전의 실행에서만 연결 가이드 표시
    func openAccountSetupIfNeeded() {
        guard installationHistory.requiresAccountSetup, !preferences.hasRegisteredAccounts else { return }
        if let accountSetupWindow {
            accountSetupWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = AccountSetupModel()
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: AccountSetupView.windowSize),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Codex Quota Monitor 시작하기"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: AccountSetupView(
            model: model,
            onComplete: { [weak self] path in self?.registerInitialAccount(path: path) },
            onLater: { [weak self] in self?.accountSetupWindow?.close() }
        ))
        accountSetupModel = model
        accountSetupWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 확인된 한 계정 경로 저장과 해당 슬롯 표시 활성화
    private func registerInitialAccount(path: String) {
        guard installationHistory.requiresAccountSetup, !preferences.hasRegisteredAccounts,
              let index = preferences.accountPaths.firstIndex(of: "") else { return }
        var paths = preferences.accountPaths
        paths[index] = path
        var enabled = preferences.enabledAccountIDs
        let id = "C\(index + 1)"
        if !enabled.contains(id) { enabled.append(id) }
        preferences.updateEnabledAccountIDs(enabled)
        applyAccountPaths(paths)
    }

    /// 가이드 닫기 시 진행 중 조회와 미저장 초안 폐기
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === accountSetupWindow else { return }
        accountSetupModel?.cancelCheck()
        accountSetupModel = nil
        accountSetupWindow = nil
    }
}
