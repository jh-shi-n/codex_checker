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
    }
}

@MainActor
final class CodexQuotaMonitorAppDelegate: NSObject, NSApplicationDelegate {
    let preferences: PreferencesStore
    let accountStore: AccountStore
    let refreshService: RefreshService
    let launchAtLoginService: LaunchAtLoginService
    let sessionActivityProvider: AppServerSessionActivityProvider
    /// One local-only token reader is shared by all dashboard instances.
    let tokenUsageProvider: LocalTokenUsageProvider
    /// In-memory snapshots keep reopening a detail popover read-only until an
    /// explicit dashboard Update action requests a new local scan.
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

    override init() {
        let preferences = PreferencesStore()
        let accountStore = AccountStore(configs: Self.configs(for: preferences.accountPaths))
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
        let tokenUsageCache = TokenUsageSnapshotCache(provider: tokenUsageProvider)
        let usageWindowProbeService = UsageWindowProbeService()
        let sessionActivityToastQueue = SessionActivityToastQueue(
            durationSeconds: preferences.activityNotificationDurationSeconds
        )
        let sessionActivityDelivery = SessionActivityToastDeliveryGate(
            queue: sessionActivityToastQueue
        )
        let sessionActivityMonitor = SessionActivityMonitor(
            accounts: accountStore.configs,
            provider: sessionActivityProvider,
            onTransition: { transition in
                sessionActivityDelivery.deliver(transition)
            }
        )
        let notchLayoutManager = NotchLayoutManager()

        self.preferences = preferences
        self.accountStore = accountStore
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
                    notchLayoutManager.update(
                        leftAccounts: AccountStore.split(accountStore.states, side: .left),
                        rightAccounts: AccountStore.split(accountStore.states, side: .right),
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
                    // A path edit changes the meaning of every stable slot;
                    // synchronously mark cached usage stale before applying
                    // the new account configurations.
                    tokenUsageCache.invalidateAll()
                    accountStore.reconfigure(pathStrings: paths)
                    Task { @MainActor in
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

    func render(states: [AccountState]) {
        notchLayoutManager.update(
            leftAccounts: AccountStore.split(states, side: .left),
            rightAccounts: AccountStore.split(states, side: .right),
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

    private func refreshTokenUsage(_ account: AccountState) async -> TokenUsageSnapshot {
        guard let config = accountStore.configs.first(where: { $0.id == account.id }),
              config.isConfigured,
              let home = config.configuredHome
        else {
            return AccountDashboardDefaults.unavailableTokenUsageSnapshot()
        }
        return await tokenUsageCache.refresh(accountID: account.id, home: home)
    }

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

        // Capture the reset before the probe and refresh only this stable slot
        // after the process completes. The composite remains UI-safe and is
        // intentionally ephemeral; no raw probe result is persisted.
        let resetBefore = accountStore.state(for: account.id)?.primaryResetAt
            ?? account.primaryResetAt
        let result = await usageWindowProbeService.probe(config)
        await accountStore.refresh(accountID: account.id)
        let resetAfter = accountStore.state(for: account.id)?.primaryResetAt
        return UsageWindowProbePresentationResult(
            result: result,
            primaryResetBefore: resetBefore,
            primaryResetAfter: resetAfter
        )
    }

    private static func configs(for paths: [String]) -> [AccountConfig] {
        AccountConfig.accounts(for: paths)
    }
}
