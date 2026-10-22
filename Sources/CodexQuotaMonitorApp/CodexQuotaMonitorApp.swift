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
    /// 할당량 조회에 동반하여 갱신하는 네 계정 공용 서비스 상태
    let serviceStatus: OpenAIServiceStatusStore
    let quotaResetNotifications: QuotaResetNotificationService
    /// 안정 관측된 한도의 시각 도달 조회와 사전·도달 시스템 알림 연결
    lazy var quotaResetScheduler = QuotaResetScheduler(
        refresh: { [weak self] id in
            guard let self else { return nil }
            await self.accountStore.refresh(accountID: id, forceFresh: true)
            return self.accountStore.state(for: id)
        },
        notify: { [weak self] alert in
            guard let self else { return }
            await self.quotaResetNotifications.delivery.notifyScheduled(
                alert, displayName: self.preferences.displayName(for: alert.accountID)
            )
        }
    )
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
    var accountSetupWindow: NSWindow?
    var accountSetupModel: AccountSetupModel?
    var statesCancellable: AnyCancellable?
    var activityToastCancellable: AnyCancellable?
    var wakeObserver: NSObjectProtocol?
    var hiddenAccountsStatusItem: NSStatusItem?
    var emptyAccountsPopover: NSPopover?
    var tokenCleanupTask: Task<Void, Never>?

    /// 설정과 계정 서비스 초기화 및 표시·갱신 콜백 연결
    override init() {
        let preferences = PreferencesStore(configurationFile: AppConfigurationFile(fileURL: AppConfigurationFile.defaultFileURL))
        let serviceStatus = OpenAIServiceStatusStore()
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
        let notchLayoutManager = NotchLayoutManager(serviceStatus: serviceStatus)

        self.preferences = preferences
        self.accountStore = accountStore
        self.serviceStatus = serviceStatus
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

        accountStore.onQuotaRefreshStarted = { [weak serviceStatus] in
            serviceStatus?.refresh()
        }

        accountStore.onEarlyQuotaReset = { [weak self] reset in
            guard let self else { return }
            self.quotaResetNotifications.notify(reset, displayName: self.preferences.displayName(for: reset.accountID))
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
            self?.quotaResetScheduler.reconcile(
                states: states, reminderMinutes: preferences.resetReminderMinutes
            )
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
            accountDisplayNames: preferences.accountDisplayNames,
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
        let generation = accountStore.state(for: account.id)?.configurationGeneration
        let before = accountStore.state(for: account.id) ?? account
        let result = await usageWindowProbeService.probe(config)
        let isCurrent = generation == accountStore.state(for: account.id)?.configurationGeneration
            && accountStore.configs.first(where: { $0.id == account.id }) == config
        guard result.isSuccess,
              isCurrent
        else {
            if !isCurrent {
                DiagnosticLogContext.record(.probeResultDiscarded, accountID: account.id,
                                            fields: [.reason: .identifier("configuration_changed")])
            }
            return UsageWindowProbePresentationResult(
                result: result,
                primaryResetBefore: before.primaryResetAt,
                secondaryResetBefore: before.secondaryResetAt,
                quotaRefreshSucceeded: result.isSuccess ? false : nil,
                isCurrentAccount: isCurrent
            )
        }
        let refresh = await accountStore.refreshOutcome(accountID: account.id, forceFresh: true)
        let didRefresh = refresh.isSuccess
        let isStillCurrent = generation == accountStore.state(for: account.id)?.configurationGeneration
            && accountStore.configs.first(where: { $0.id == account.id }) == config
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

    /// 표시 계정이 없을 때 메뉴 막대의 앱 안내 아이콘 제공
    private func updateHiddenAccountsSettingsAccess(isHidden: Bool) {
        guard isHidden else {
            emptyAccountsPopover?.performClose(nil)
            emptyAccountsPopover = nil
            if let hiddenAccountsStatusItem {
                NSStatusBar.system.removeStatusItem(hiddenAccountsStatusItem)
                self.hiddenAccountsStatusItem = nil
            }
            return
        }
        if hiddenAccountsStatusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = AppBranding.menuBarIcon()
            item.button?.target = self
            item.button?.action = #selector(openEmptyAccountsInfo)
            item.button?.toolTip = "Codex Quota Checker"
            hiddenAccountsStatusItem = item
        }
        if let controller = emptyAccountsPopover?.contentViewController as? NSHostingController<EmptyAccountsView> {
            controller.rootView = makeEmptyAccountsView()
        }
    }

    /// 초기 등록 전 연결 가이드 또는 등록 완료 후 계정 상태 안내 표시
    @objc private func openEmptyAccountsInfo() {
        if preferences.requiresAccountSetup {
            openAccountSetupIfNeeded()
            return
        }
        guard let button = hiddenAccountsStatusItem?.button else { return }
        if emptyAccountsPopover?.isShown == true {
            emptyAccountsPopover?.performClose(nil)
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: makeEmptyAccountsView())
        popover.contentSize = EmptyAccountsView.contentSize
        emptyAccountsPopover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// 등록 상태별 설명과 설정 버튼의 공통 구성
    private func makeEmptyAccountsView() -> EmptyAccountsView {
        EmptyAccountsView(hasRegisteredAccounts: preferences.hasRegisteredAccounts) { [weak self] in
            self?.emptyAccountsPopover?.performClose(nil)
            self?.openSettings()
        }
    }

    private static func configs(for paths: [String]) -> [AccountConfig] {
        AccountConfig.accounts(for: paths)
    }
}
