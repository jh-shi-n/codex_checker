import Foundation

public struct AppLifecycleActions: Sendable {
    public let activateAccessory: @MainActor @Sendable () -> Void
    public let renderLoading: @MainActor @Sendable () -> Void
    public let startObservers: @MainActor @Sendable () -> Void
    public let showPanels: @MainActor @Sendable () -> Void
    public let startRefresh: @MainActor @Sendable () -> Void
    public let stopRefresh: @MainActor @Sendable () -> Void
    public let hidePanels: @MainActor @Sendable () -> Void
    public let stopObservers: @MainActor @Sendable () -> Void
    public let relayout: @MainActor @Sendable () -> Void
    public let refreshNow: @MainActor @Sendable () async -> Void
    public let restartRefresh: @MainActor @Sendable (Int) -> Void
    public let reconfigurePaths: @MainActor @Sendable ([String]) -> Void
    public let readLaunchAtLoginStatus: @MainActor @Sendable () -> LaunchAtLoginStatus

    public init(
        activateAccessory: @escaping @MainActor @Sendable () -> Void,
        renderLoading: @escaping @MainActor @Sendable () -> Void,
        startObservers: @escaping @MainActor @Sendable () -> Void,
        showPanels: @escaping @MainActor @Sendable () -> Void,
        startRefresh: @escaping @MainActor @Sendable () -> Void,
        stopRefresh: @escaping @MainActor @Sendable () -> Void,
        hidePanels: @escaping @MainActor @Sendable () -> Void,
        stopObservers: @escaping @MainActor @Sendable () -> Void,
        relayout: @escaping @MainActor @Sendable () -> Void,
        refreshNow: @escaping @MainActor @Sendable () async -> Void,
        restartRefresh: @escaping @MainActor @Sendable (Int) -> Void,
        reconfigurePaths: @escaping @MainActor @Sendable ([String]) -> Void,
        readLaunchAtLoginStatus: @escaping @MainActor @Sendable () -> LaunchAtLoginStatus
    ) {
        self.activateAccessory = activateAccessory
        self.renderLoading = renderLoading
        self.startObservers = startObservers
        self.showPanels = showPanels
        self.startRefresh = startRefresh
        self.stopRefresh = stopRefresh
        self.hidePanels = hidePanels
        self.stopObservers = stopObservers
        self.relayout = relayout
        self.refreshNow = refreshNow
        self.restartRefresh = restartRefresh
        self.reconfigurePaths = reconfigurePaths
        self.readLaunchAtLoginStatus = readLaunchAtLoginStatus
    }
}

/// Small AppKit-free lifecycle seam used by the executable host and focused
/// tests. It owns ordering and user-settings callbacks while injected actions
/// own actual panels, timers, observers, and windows.
@MainActor
public final class AppLifecycleCoordinator {
    public private(set) var isLaunched = false
    public private(set) var launchAtLoginStatus: LaunchAtLoginStatus?

    private let actions: AppLifecycleActions

    public init(actions: AppLifecycleActions) {
        self.actions = actions
    }

    public func launch() {
        guard !isLaunched else { return }
        actions.activateAccessory()
        actions.renderLoading()
        actions.startObservers()
        actions.showPanels()
        launchAtLoginStatus = actions.readLaunchAtLoginStatus()
        actions.startRefresh()
        isLaunched = true
    }

    public func readLaunchAtLoginStatus() -> LaunchAtLoginStatus {
        let status = actions.readLaunchAtLoginStatus()
        launchAtLoginStatus = status
        return status
    }

    public func wake() async {
        guard isLaunched else { return }
        actions.relayout()
        await actions.refreshNow()
    }

    public func restartRefresh(intervalMinutes: Int) {
        actions.restartRefresh(intervalMinutes)
    }

    /// Applies a persisted interval and then invokes the single host restart
    /// action with the effective canonical value. Keeping this ordering in
    /// the AppKit-free seam lets hosts test persistence and timer restart as
    /// one settings operation.
    public func applyRefreshInterval(
        minutes: Int,
        persist: @escaping @MainActor @Sendable (Int) -> Int
    ) {
        let effectiveMinutes = persist(minutes)
        actions.restartRefresh(effectiveMinutes)
    }

    public func reconfigure(paths: [String]) async {
        actions.reconfigurePaths(paths)
        await actions.refreshNow()
    }

    public func terminate() {
        guard isLaunched else { return }
        actions.stopRefresh()
        actions.hidePanels()
        actions.stopObservers()
        isLaunched = false
    }
}
