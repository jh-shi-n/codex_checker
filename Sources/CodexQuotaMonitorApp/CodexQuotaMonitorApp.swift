// 목적: 계정 표시 설정과 한도·토큰 집계·활동 서비스의 앱 통합
// 이용처: macOS 메뉴 막대 및 노치 모니터
// 사용방법: 앱 실행 후 설정에서 표시 계정과 순서 선택
// 실행 예시: swift run CodexQuotaMonitor
@preconcurrency import AppKit
import Combine
import SwiftUI

import CodexQuotaMonitorKit

@main
struct CodexQuotaMonitorApp: App {
    @NSApplicationDelegateAdaptor(CodexQuotaMonitorAppDelegate.self)
    private var appDelegate: CodexQuotaMonitorAppDelegate

    var body: some Scene {
        // SwiftUI owns one settings scene window. Both the app-menu Settings
        // command and notch-ring callbacks route to this same populated view.
        Settings {
            appDelegate.makeSettingsView()
        }
        .defaultSize(SettingsView.defaultWindowSize)
    }
}

@MainActor
final class CodexQuotaMonitorAppDelegate: NSObject, NSApplicationDelegate {
    let preferences: PreferencesStore
    let accountStore: AccountStore
    let quotaResetNotifications: QuotaResetNotificationService
    let refreshService: RefreshService
    let launchAtLoginService: LaunchAtLoginService
    let sessionActivityProvider: AppServerSessionActivityProvider
    /// One local-only token reader is shared by all dashboard instances.
    let tokenUsageProvider: LocalTokenUsageProvider
    /// 명시적 업데이트 집계의 메모리·SQLite 보관 및 14일 만료 관리
    let tokenUsageCache: TokenUsageSnapshotCache
    /// The probe service owns process lifetime and the per-account running gate.
    let usageWindowProbeService: UsageWindowProbeService
    let sessionActivityToastQueue: SessionActivityToastQueue
    let sessionActivityMonitor: SessionActivityMonitor
    let notchLayoutManager: NotchLayoutManager
    let lifecycleCoordinator: AppLifecycleCoordinator

    var effectiveLaunchAtLoginStatus: LaunchAtLoginStatus
    let sessionActivityDelivery: SessionActivityToastDeliveryGate
    var fallbackSettingsWindow: NSWindow?
    var statesCancellable: AnyCancellable?
    var activityToastCancellable: AnyCancellable?
    var wakeObserver: NSObjectProtocol?
    var hiddenAccountsStatusItem: NSStatusItem?
    var tokenCleanupTask: Task<Void, Never>?

    /// 설정과 계정 서비스 초기화 및 표시·갱신 콜백 연결
    override init() {
        let preferences = PreferencesStore()
        let accountStore = AccountStore(
            configs: Self.configs(for: preferences.accountPaths),
            preferencesStore: preferences
        )
        let refreshService = RefreshService(
            intervalMinutes: preferences.refreshIntervalMinutes,
            refresh: { [weak accountStore] in
                await accountStore?.refreshAll()
            }
        )
        let launchAtLoginService = LaunchAtLoginService()
        let sessionActivityProvider = AppServerSessionActivityProvider(
            fallback: SQLiteSessionActivityProvider(),
            capability: .installedProtocol
        )
        let tokenUsageProvider = LocalTokenUsageProvider()
        let tokenUsageCache = TokenUsageSnapshotCache(
            provider: tokenUsageProvider,
            databaseURL: TokenUsageSnapshotCache.defaultDatabaseURL,
            accountHomes: Self.tokenHomes(for: accountStore.configs)
        )
        let usageWindowProbeService = UsageWindowProbeService()
        let sessionActivityToastQueue = SessionActivityToastQueue(
            durationSeconds: preferences.activityNotificationDurationSeconds
        )
        let sessionActivityDelivery = SessionActivityToastDeliveryGate(
            queue: sessionActivityToastQueue
        )
        let quotaResetNotifications = QuotaResetNotificationService { fallback in
            let visible = preferences.visibleAccounts(accountStore.states)
            guard let index = visible.firstIndex(where: { $0.id == fallback.accountID }) else { return }
            let windows = fallback.windowTitles.joined(separator: " · ")
            sessionActivityDelivery.deliver(SessionActivityTransition(
                accountID: fallback.accountID,
                side: index < 2 ? .left : .right,
                sessionID: fallback.id,
                agentLabel: "할당량 리셋 알림",
                taskName: "\(windows) 조기 초기화",
                status: .completed
            ))
        }
        let sessionActivityMonitor = SessionActivityMonitor(
            accounts: accountStore.configs,
            provider: sessionActivityProvider,
            onTransition: { transition in
                guard let index = preferences.accountDisplayOrder
                    .filter({ preferences.enabledAccountIDs.contains($0) })
                    .firstIndex(of: transition.accountID)
                else { return }
                sessionActivityDelivery.deliver(SessionActivityTransition(
                    accountID: transition.accountID,
                    side: index < 2 ? .left : .right,
                    sessionID: transition.sessionID,
                    agentLabel: transition.agentLabel,
                    taskName: transition.taskName,
                    status: transition.status
                ))
            }
        )
        let notchLayoutManager = NotchLayoutManager()

        self.preferences = preferences
        self.accountStore = accountStore
        self.quotaResetNotifications = quotaResetNotifications
        self.refreshService = refreshService
        self.launchAtLoginService = launchAtLoginService
        self.sessionActivityProvider = sessionActivityProvider
        self.tokenUsageProvider = tokenUsageProvider
        self.tokenUsageCache = tokenUsageCache
        self.usageWindowProbeService = usageWindowProbeService
        self.sessionActivityToastQueue = sessionActivityToastQueue
        self.sessionActivityMonitor = sessionActivityMonitor
        self.notchLayoutManager = notchLayoutManager
        self.sessionActivityDelivery = sessionActivityDelivery
        self.effectiveLaunchAtLoginStatus = launchAtLoginService.status

        self.lifecycleCoordinator = AppLifecycleCoordinator(
            actions: AppLifecycleActions(
                activateAccessory: {
                    NSApp.setActivationPolicy(.accessory)
                },
                renderLoading: {
                    let visible = preferences.visibleAccounts(accountStore.states)
                    notchLayoutManager.update(
                        leftAccounts: QuotaClusterView.splitVisibleAccounts(visible, side: .left),
                        rightAccounts: QuotaClusterView.splitVisibleAccounts(visible, side: .right),
                        showAccountLabels: preferences.showAccountLabels
                    )
                },
                startObservers: {
                    notchLayoutManager.startObservingScreenChanges()
                },
                showPanels: {
                    notchLayoutManager.show()
                },
                startRefresh: {
                    refreshService.start()
                },
                stopRefresh: {
                    refreshService.stop()
                },
                hidePanels: {
                    notchLayoutManager.hide()
                },
                stopObservers: {
                    notchLayoutManager.stopObservingScreenChanges()
                },
                relayout: {
                    _ = notchLayoutManager.screenDidChange()
                },
                refreshNow: {
                    await refreshService.refreshNow()
                },
                restartRefresh: { minutes in
                    refreshService.restart(intervalMinutes: minutes)
                },
                reconfigurePaths: { paths in
                    let generation = sessionActivityDelivery.pause()
                    // 경로가 달라진 슬롯만 동기 무효화하여 다른 계정의 기록 보존
                    let previousHomes = Self.tokenHomes(for: accountStore.configs)
                    let nextHomes = Self.tokenHomes(for: Self.configs(for: paths))
                    for accountID in Set(previousHomes.keys).union(nextHomes.keys) {
                        if previousHomes[accountID] != nextHomes[accountID] {
                            tokenUsageCache.invalidate(accountID: accountID)
                        }
                    }
                    accountStore.reconfigure(pathStrings: paths)
                    Task { @MainActor in
                        await tokenUsageCache.configureAccountHomes(Self.tokenHomes(for: accountStore.configs))
                        await sessionActivityMonitor.reconfigure(
                            accounts: accountStore.configs
                        )
                        sessionActivityDelivery.resume(generation: generation)
                    }
                },
                readLaunchAtLoginStatus: {
                    launchAtLoginService.status
                }
            )
        )
        super.init()

        accountStore.onEarlyQuotaReset = { [weak self] reset in
            self?.quotaResetNotifications.notify(reset)
        }

        activityToastCancellable = sessionActivityToastQueue.$currentLeft
            .combineLatest(sessionActivityToastQueue.$currentRight)
            .sink { [weak self] left, right in
                self?.notchLayoutManager.updateActivityToasts(left: left, right: right)
            }

        let loadSessionActivity: SessionActivityLoader = { [weak self] account in
            guard let self else {
                return .unavailable(accountID: account.id)
            }
            return await self.loadSessionActivity(account)
        }
        notchLayoutManager.leftPanel.setSessionActivityLoader(loadSessionActivity)
        notchLayoutManager.rightPanel.setSessionActivityLoader(loadSessionActivity)

        let loadCachedTokenUsage: TokenUsageSnapshotLookup = { [weak self] accountID in
            guard let self else {
                return nil
            }
            return await self.cachedTokenUsage(accountID: accountID)
        }
        let refreshTokenUsage: TokenUsageSnapshotRefresh = { [weak self] account in
            guard let self else {
                return AccountDashboardDefaults.unavailableTokenUsageSnapshot()
            }
            return await self.refreshTokenUsage(account)
        }
        let runUsageWindowProbe: UsageWindowProbeRunner = { [weak self] account in
            guard let self else {
                return AccountDashboardDefaults.unavailableProbe(
                    accountID: account.id,
                    category: .processFailure
                )
            }
            return await self.runUsageWindowProbe(account)
        }
        notchLayoutManager.setDashboardCallbacks(
            loadCachedTokenUsage: loadCachedTokenUsage,
            refreshTokenUsage: refreshTokenUsage,
            runUsageWindowProbe: runUsageWindowProbe,
        )

        notchLayoutManager.leftPanel.onRefresh = { [weak self] account in
            self?.refreshAccount(account.id)
        }
        notchLayoutManager.rightPanel.onRefresh = { [weak self] account in
            self?.refreshAccount(account.id)
        }
        notchLayoutManager.leftPanel.onSettings = { [weak self] in
            self?.openSettings()
        }
        notchLayoutManager.rightPanel.onSettings = { [weak self] in
            self?.openSettings()
        }

        statesCancellable = accountStore.$states.sink { [weak self] states in
            self?.render(states: states)
        }
    }

    /// 설정 순서의 표시 계정 배치 및 전체 숨김 시 설정 진입점 유지
    func render(states: [AccountState]) {
        let visible = preferences.visibleAccounts(states)
        sessionActivityToastQueue.configureDisplayedAccounts(visible.map(\.id))
        updateHiddenAccountsSettingsAccess(isHidden: visible.isEmpty)
        notchLayoutManager.update(
            leftAccounts: QuotaClusterView.splitVisibleAccounts(visible, side: .left),
            rightAccounts: QuotaClusterView.splitVisibleAccounts(visible, side: .right),
            showAccountLabels: preferences.showAccountLabels,
            onRefresh: { [weak self] account in
                self?.refreshAccount(account.id)
            },
            onSettings: { [weak self] in
                self?.openSettings()
            }
        )
    }

    private func refreshAccount(_ id: String) {
        Task { @MainActor [weak self] in
            await self?.accountStore.refresh(accountID: id)
        }
    }

    private func loadSessionActivity(_ account: AccountState) async -> SessionActivitySnapshot {
        guard let config = accountStore.configs.first(where: { $0.id == account.id }) else {
            return .unavailable(accountID: account.id)
        }
        guard config.isConfigured else {
            return .unavailable(accountID: account.id)
        }
        return await sessionActivityProvider.snapshot(
            accountID: account.id,
            home: config.home
        )
    }

    /// Resolves the stable account ID before reading local rollout metadata.
    /// Unconfigured/missing IDs receive a safe unavailable snapshot and never
    /// cause the compatibility `home` URL to be opened as a filesystem path.
    private func cachedTokenUsage(accountID: String) async -> TokenUsageSnapshot? {
        await tokenUsageCache.cachedSnapshot(for: accountID)
    }

    /// 현재 계정의 명시적 토큰 집계 및 설정 변경 중 이전 결과 배제
    private func refreshTokenUsage(_ account: AccountState) async -> TokenUsageSnapshot {
        guard let config = accountStore.configs.first(where: { $0.id == account.id }),
              config.isConfigured,
              let home = config.configuredHome
        else {
            return AccountDashboardDefaults.unavailableTokenUsageSnapshot()
        }
        let revision = accountStore.configurationRevision
        let snapshot = await tokenUsageCache.refresh(accountID: account.id, home: home)
        guard revision == accountStore.configurationRevision else {
            return AccountDashboardDefaults.unavailableTokenUsageSnapshot()
        }
        return snapshot
    }

    /// 선택 계정의 Ping 실행 후 새 한도 조회 및 Reset 변화 반환
    private func runUsageWindowProbe(
        _ account: AccountState
    ) async -> UsageWindowProbePresentationResult {
        guard let config = accountStore.configs.first(where: { $0.id == account.id }),
              config.isConfigured
        else {
            return AccountDashboardDefaults.unavailableProbe(
                accountID: account.id,
                category: .notConfigured
            )
        }

        // Ping 이전 조회 재사용을 막고 완료 이후 한도 조회 보장
        let revision = accountStore.configurationRevision
        let before = accountStore.state(for: account.id) ?? account
        let result = await usageWindowProbeService.probe(config)
        let isCurrent = revision == accountStore.configurationRevision
            && accountStore.configs.first(where: { $0.id == account.id }) == config
        guard result.isSuccess,
              isCurrent
        else {
            return UsageWindowProbePresentationResult(
                result: result,
                primaryResetBefore: before.primaryResetAt,
                secondaryResetBefore: before.secondaryResetAt,
                quotaRefreshSucceeded: result.isSuccess ? false : nil,
                isCurrentAccount: isCurrent
            )
        }
        let didRefresh = await accountStore.refresh(accountID: account.id, forceFresh: true)
        let isStillCurrent = revision == accountStore.configurationRevision
        let after = didRefresh && isStillCurrent ? accountStore.state(for: account.id) : nil
        return UsageWindowProbePresentationResult(
            result: result,
            primaryResetBefore: before.primaryResetAt,
            primaryResetAfter: after?.primaryResetAt,
            secondaryResetBefore: before.secondaryResetAt,
            secondaryResetAfter: after?.secondaryResetAt,
            quotaRefreshSucceeded: didRefresh && isStillCurrent,
            refreshedAccount: after,
            isCurrentAccount: isStillCurrent
        )
    }

    /// 설정된 계정의 토큰 집계 복원 범위 구성
    private static func tokenHomes(for configs: [AccountConfig]) -> [String: URL] {
        Dictionary(uniqueKeysWithValues: configs.compactMap { config in
            config.configuredHome.map { (config.id, $0) }
        })
    }

    /// 전체 계정 숨김 상태에서만 메뉴 막대의 설정 버튼 제공
    private func updateHiddenAccountsSettingsAccess(isHidden: Bool) {
        guard isHidden else {
            if let hiddenAccountsStatusItem {
                NSStatusBar.system.removeStatusItem(hiddenAccountsStatusItem)
                self.hiddenAccountsStatusItem = nil
            }
            return
        }
        guard hiddenAccountsStatusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "계정 표시 설정")
        item.button?.target = self
        item.button?.action = #selector(openHiddenAccountsSettings)
        item.button?.toolTip = "계정 표시 설정"
        hiddenAccountsStatusItem = item
    }

    /// 숨김 계정의 표시 복원을 위한 설정 창 열기
    @objc private func openHiddenAccountsSettings() {
        openSettings()
    }

    private static func configs(for paths: [String]) -> [AccountConfig] {
        AccountConfig.accounts(for: paths)
    }
}
