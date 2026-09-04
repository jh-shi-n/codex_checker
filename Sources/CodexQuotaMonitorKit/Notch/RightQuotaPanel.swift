import AppKit
import SwiftUI

/// Right notch cluster. Account order is C3 (notch-nearest) then C4 (outer).
@MainActor
public final class RightQuotaPanel: NotchQuotaPanel {
    public private(set) var accounts: [AccountState]
    public private(set) var menuBarHeight: CGFloat
    public private(set) var diameterOverride: CGFloat?
    public private(set) var showAccountLabels: Bool
    /// Stable model observed by the single hosting root for this panel.
    public let activityPresentation: NotchActivityPresentationModel
    public var activityToast: SessionActivityToast? {
        activityPresentation.displayedToast
    }
    public var activityToastWidth: CGFloat? {
        activityPresentation.displayedWidth
    }
    public var onRefresh: (AccountState) -> Void
    public var onSettings: () -> Void
    public var loadSessionActivity: SessionActivityLoader
    public var loadCachedTokenUsage: TokenUsageSnapshotLookup
    public var refreshTokenUsage: TokenUsageSnapshotRefresh
    public var runUsageWindowProbe: UsageWindowProbeRunner
    public var onClose: () -> Void

    public init(
        accounts: [AccountState] = [],
        menuBarHeight: CGFloat = 24,
        diameterOverride: CGFloat? = nil,
        showAccountLabels: Bool = false,
        onRefresh: @escaping (AccountState) -> Void = { _ in },
        onSettings: @escaping () -> Void = {},
        loadSessionActivity: @escaping SessionActivityLoader = { account in
            .unavailable(accountID: account.id)
        },
        loadCachedTokenUsage: @escaping TokenUsageSnapshotLookup = AccountDashboardDefaults.emptyTokenUsageLookup,
        refreshTokenUsage: @escaping TokenUsageSnapshotRefresh = AccountDashboardDefaults.unavailableTokenUsageRefresh,
        runUsageWindowProbe: @escaping UsageWindowProbeRunner = { account in
            AccountDashboardDefaults.unavailableProbe(accountID: account.id)
        },
        onClose: @escaping () -> Void = {},
        activityToast: SessionActivityToast? = nil,
        activityToastWidth: CGFloat? = nil,
        activityPresentation: NotchActivityPresentationModel? = nil
    ) {
        self.accounts = accounts
        self.menuBarHeight = menuBarHeight
        self.diameterOverride = diameterOverride
        self.showAccountLabels = showAccountLabels
        self.activityPresentation = activityPresentation ?? NotchActivityPresentationModel(
            toast: activityToast,
            width: activityToastWidth
        )
        self.onRefresh = onRefresh
        self.onSettings = onSettings
        self.loadSessionActivity = loadSessionActivity
        self.loadCachedTokenUsage = loadCachedTokenUsage
        self.refreshTokenUsage = refreshTokenUsage
        self.runUsageWindowProbe = runUsageWindowProbe
        self.onClose = onClose
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        update(
            accounts: accounts,
            menuBarHeight: menuBarHeight,
            diameterOverride: diameterOverride,
            showAccountLabels: showAccountLabels,
            onRefresh: onRefresh,
            onSettings: onSettings,
            loadSessionActivity: loadSessionActivity,
            loadCachedTokenUsage: loadCachedTokenUsage,
            refreshTokenUsage: refreshTokenUsage,
            runUsageWindowProbe: runUsageWindowProbe,
            onClose: onClose
        )
    }

    public func update(
        accounts: [AccountState],
        menuBarHeight: CGFloat? = nil,
        diameterOverride: CGFloat? = nil,
        showAccountLabels: Bool? = nil,
        onRefresh: ((AccountState) -> Void)? = nil,
        onSettings: (() -> Void)? = nil,
        loadSessionActivity: SessionActivityLoader? = nil,
        loadCachedTokenUsage: TokenUsageSnapshotLookup? = nil,
        refreshTokenUsage: TokenUsageSnapshotRefresh? = nil,
        runUsageWindowProbe: UsageWindowProbeRunner? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.accounts = accounts
        if let menuBarHeight { self.menuBarHeight = menuBarHeight }
        self.diameterOverride = diameterOverride
        if let showAccountLabels { self.showAccountLabels = showAccountLabels }
        if let onRefresh { self.onRefresh = onRefresh }
        if let onSettings { self.onSettings = onSettings }
        if let loadSessionActivity { self.loadSessionActivity = loadSessionActivity }
        if let loadCachedTokenUsage { self.loadCachedTokenUsage = loadCachedTokenUsage }
        if let refreshTokenUsage { self.refreshTokenUsage = refreshTokenUsage }
        if let runUsageWindowProbe { self.runUsageWindowProbe = runUsageWindowProbe }
        if let onClose { self.onClose = onClose }
        installCluster()
    }

    /// Host seam for the queue's current right-lane value. The manager supplies
    /// the clamped width during relayout; callers that do not have geometry
    /// can omit it and use the pure text estimate.
    public func setActivityToast(
        _ toast: SessionActivityToast?,
        width: CGFloat? = nil
    ) {
        activityPresentation.setToast(toast, width: width)
    }

    /// Updates only the current displayed width after pure notch geometry
    /// clamps it to an auxiliary area. This never restarts a toast lifecycle.
    public func setActivityToastWidth(_ width: CGFloat?) {
        activityPresentation.setDisplayedWidth(width)
    }

    /// Rebuilds the SwiftUI root with the host-provided popover activity
    /// loader without changing panel geometry or quota callbacks.
    public func setSessionActivityLoader(_ loader: @escaping SessionActivityLoader) {
        loadSessionActivity = loader
        installCluster()
    }

    /// Installs the account dashboard contracts once. Subsequent quota/state
    /// renders retain these closures because `update` only replaces values
    /// supplied by its optional arguments.
    public func setDashboardCallbacks(
        loadCachedTokenUsage: @escaping TokenUsageSnapshotLookup,
        refreshTokenUsage: @escaping TokenUsageSnapshotRefresh,
        runUsageWindowProbe: @escaping UsageWindowProbeRunner,
        onClose: @escaping () -> Void = {}
    ) {
        self.loadCachedTokenUsage = loadCachedTokenUsage
        self.refreshTokenUsage = refreshTokenUsage
        self.runUsageWindowProbe = runUsageWindowProbe
        self.onClose = onClose
        installCluster()
    }

    private func installCluster() {
        let root = QuotaClusterView(
            accounts: accounts,
            side: .right,
            menuBarHeight: menuBarHeight,
            diameterOverride: diameterOverride,
            showAccountLabels: showAccountLabels,
            onRefresh: onRefresh,
            onSettings: onSettings,
            loadSessionActivity: loadSessionActivity,
            loadCachedTokenUsage: loadCachedTokenUsage,
            refreshTokenUsage: refreshTokenUsage,
            runUsageWindowProbe: runUsageWindowProbe,
            onClose: onClose,
            activityPresentation: activityPresentation
        )
        if let activityHostingView {
            activityHostingView.rootView = root
            return
        }

        let hostingView = NSHostingView(rootView: root)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        activityHostingView = hostingView
        contentView = hostingView
    }

    private var activityHostingView: NSHostingView<QuotaClusterView>?
}
