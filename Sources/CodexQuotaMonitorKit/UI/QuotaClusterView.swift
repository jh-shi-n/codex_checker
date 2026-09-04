import Foundation
import SwiftUI

/// Pure content footprint used by both the SwiftUI cluster and notch panels.
public enum QuotaClusterMetrics {
    public static let containmentMargin: CGFloat = 0.25
    /// Black-only extension toward the physical camera/notch gap.
    public static let notchBridgeWidth: CGFloat = 8

    public static func footprint(
        itemCount: Int,
        diameter: CGFloat,
        spacing: CGFloat = QuotaDonutMetrics.accountSpacing
    ) -> CGSize {
        guard itemCount > 0 else { return .zero }
        let safeDiameter = diameter.isFinite ? max(0, diameter) : 0
        let safeSpacing = spacing.isFinite ? max(0, spacing) : 0
        return CGSize(
            width: safeDiameter * CGFloat(itemCount) + safeSpacing * CGFloat(max(0, itemCount - 1)),
            height: safeDiameter
        )
    }

    /// Extra content inset required for the rounded 3.5pt stroke and 1.07x
    /// hover scale to remain inside the black content bounds.
    public static func visualInset(
        forDiameter diameter: CGFloat,
        hoverScale: CGFloat = QuotaDonutMetrics.hoverScale
    ) -> CGFloat {
        let safeDiameter = diameter.isFinite ? max(0, diameter) : 0
        let safeScale = hoverScale.isFinite ? max(1, hoverScale) : 1
        return max(
            0,
            (safeDiameter * (safeScale - 1) + QuotaDonutMetrics.ringWidth * safeScale) / 2
        )
    }

    public static func visualFootprint(
        itemCount: Int,
        diameter: CGFloat,
        spacing: CGFloat = QuotaDonutMetrics.accountSpacing,
        hoverScale: CGFloat = QuotaDonutMetrics.hoverScale
    ) -> CGSize {
        let content = footprint(itemCount: itemCount, diameter: diameter, spacing: spacing)
        guard itemCount > 0 else { return .zero }
        let inset = visualInset(forDiameter: diameter, hoverScale: hoverScale)
        let safeMargin = containmentMargin
        return CGSize(
            width: content.width + (inset + safeMargin) * 2,
            height: content.height + (inset + safeMargin) * 2
        )
    }
}

public struct NotchClusterCornerRadii: Equatable, Sendable {
    public let topLeading: CGFloat
    public let bottomLeading: CGFloat
    public let bottomTrailing: CGFloat
    public let topTrailing: CGFloat

    public init(
        topLeading: CGFloat,
        bottomLeading: CGFloat,
        bottomTrailing: CGFloat,
        topTrailing: CGFloat
    ) {
        self.topLeading = topLeading
        self.bottomLeading = bottomLeading
        self.bottomTrailing = bottomTrailing
        self.topTrailing = topTrailing
    }

    public static func forSide(_ side: NotchSide, radius: CGFloat = 7) -> NotchClusterCornerRadii {
        let safeRadius = radius.isFinite ? max(0, radius) : 0
        switch side {
        case .left:
            return NotchClusterCornerRadii(
                topLeading: 0,
                bottomLeading: safeRadius,
                bottomTrailing: 0,
                topTrailing: 0
            )
        case .right:
            return NotchClusterCornerRadii(
                topLeading: 0,
                bottomLeading: 0,
                bottomTrailing: safeRadius,
                topTrailing: 0
            )
        }
    }
}

struct NotchClusterBackgroundShape: Shape {
    let cornerRadii: NotchClusterCornerRadii

    init(side: NotchSide, radius: CGFloat = 7) {
        self.cornerRadii = .forSide(side, radius: radius)
    }

    func path(in rect: CGRect) -> Path {
        let safeRect = rect.standardized
        let maximumRadius = min(safeRect.width, safeRect.height) / 2
        let topLeading = min(cornerRadii.topLeading, maximumRadius)
        let bottomLeading = min(cornerRadii.bottomLeading, maximumRadius)
        let bottomTrailing = min(cornerRadii.bottomTrailing, maximumRadius)
        let topTrailing = min(cornerRadii.topTrailing, maximumRadius)

        var path = Path()
        path.move(to: CGPoint(x: safeRect.minX + topLeading, y: safeRect.minY))
        path.addLine(to: CGPoint(x: safeRect.maxX - topTrailing, y: safeRect.minY))
        if topTrailing > 0 {
            path.addQuadCurve(
                to: CGPoint(x: safeRect.maxX, y: safeRect.minY + topTrailing),
                control: CGPoint(x: safeRect.maxX, y: safeRect.minY)
            )
        }
        path.addLine(to: CGPoint(x: safeRect.maxX, y: safeRect.maxY - bottomTrailing))
        if bottomTrailing > 0 {
            path.addQuadCurve(
                to: CGPoint(x: safeRect.maxX - bottomTrailing, y: safeRect.maxY),
                control: CGPoint(x: safeRect.maxX, y: safeRect.maxY)
            )
        }
        path.addLine(to: CGPoint(x: safeRect.minX + bottomLeading, y: safeRect.maxY))
        if bottomLeading > 0 {
            path.addQuadCurve(
                to: CGPoint(x: safeRect.minX, y: safeRect.maxY - bottomLeading),
                control: CGPoint(x: safeRect.minX, y: safeRect.maxY)
            )
        }
        path.addLine(to: CGPoint(x: safeRect.minX, y: safeRect.minY + topLeading))
        if topLeading > 0 {
            path.addQuadCurve(
                to: CGPoint(x: safeRect.minX + topLeading, y: safeRect.minY),
                control: CGPoint(x: safeRect.minX, y: safeRect.minY)
            )
        }
        path.closeSubpath()
        return path
    }
}

/// A compact side of the notch layout. On both sides the first item is the
/// outer account and the second item is nearest the notch, matching C1 C2 | C3 C4.
public struct QuotaClusterView: View {
    public let accounts: [AccountState]
    public let side: NotchSide
    public let menuBarHeight: CGFloat
    public let diameterOverride: CGFloat?
    public let showAccountLabels: Bool
    public let onRefresh: (AccountState) -> Void
    public let onSettings: () -> Void
    public let loadSessionActivity: SessionActivityLoader
    public let loadCachedTokenUsage: TokenUsageSnapshotLookup
    public let refreshTokenUsage: TokenUsageSnapshotRefresh
    public let runUsageWindowProbe: UsageWindowProbeRunner
    public let onClose: () -> Void
    /// Stable main-actor state object supplied by the panel host. Queue
    /// lifetime and target selection remain outside this view.
    @ObservedObject public var activityPresentation: NotchActivityPresentationModel

    public var activityToast: SessionActivityToast? {
        activityPresentation.displayedToast
    }

    public var activityToastWidth: CGFloat? {
        activityPresentation.displayedWidth
    }

    public init(
        accounts: [AccountState],
        side: NotchSide,
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
        self.side = side
        self.menuBarHeight = menuBarHeight
        self.diameterOverride = diameterOverride
        self.showAccountLabels = showAccountLabels
        self.onRefresh = onRefresh
        self.onSettings = onSettings
        self.loadSessionActivity = loadSessionActivity
        self.loadCachedTokenUsage = loadCachedTokenUsage
        self.refreshTokenUsage = refreshTokenUsage
        self.runUsageWindowProbe = runUsageWindowProbe
        self.onClose = onClose
        let presentation = activityPresentation ?? NotchActivityPresentationModel(
            toast: activityToast,
            width: activityToastWidth
        )
        self._activityPresentation = ObservedObject(wrappedValue: presentation)
    }

    public var body: some View {
        let activityToast = activityPresentation.displayedToast
        let isExiting = activityPresentation.phase == .exiting
        HStack(spacing: 0) {
            if side == .left, let activityToast {
                NotchActivityToastView(
                    toast: activityToast,
                    side: side,
                    width: effectiveActivityToastWidth,
                    isExiting: isExiting
                )
                .id(activityToast.id)
            }

            if side == .right {
                Color.clear.frame(width: QuotaClusterMetrics.notchBridgeWidth)
            }

            HStack(spacing: QuotaDonutMetrics.accountSpacing) {
                ForEach(Self.orderedAccounts(accounts, for: side)) { account in
                    QuotaDonutView(
                        account: account,
                        menuBarHeight: menuBarHeight,
                        diameterOverride: diameterOverride,
                        showAccountLabels: showAccountLabels,
                        onRefresh: { onRefresh(account) },
                        onSettings: onSettings,
                        loadSessionActivity: loadSessionActivity,
                        loadCachedTokenUsage: loadCachedTokenUsage,
                        refreshTokenUsage: refreshTokenUsage,
                        runUsageWindowProbe: runUsageWindowProbe,
                        onClose: onClose
                    )
                }
            }
            .frame(width: contentWidth)
            .frame(maxHeight: .infinity, alignment: .center)

            if side == .left {
                Color.clear.frame(width: QuotaClusterMetrics.notchBridgeWidth)
            }

            if side == .right, let activityToast {
                NotchActivityToastView(
                    toast: activityToast,
                    side: side,
                    width: effectiveActivityToastWidth,
                    isExiting: isExiting
                )
                .id(activityToast.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(NotchClusterBackgroundShape(side: side).fill(Color.black))
        .clipped()
        .animation(
            .easeOut(
                duration: NotchActivityToastPresentation.animationDuration(
                    isPresented: activityToast != nil && !isExiting
                )
            ),
            value: activityToast?.id
        )
    }

    private var contentWidth: CGFloat {
        let requestedDiameter = diameterOverride ?? QuotaDonutMetrics.diameter(forMenuBarHeight: menuBarHeight)
        return QuotaClusterMetrics.visualFootprint(
            itemCount: accounts.count,
            diameter: requestedDiameter,
            spacing: QuotaDonutMetrics.accountSpacing
        ).width
    }

    private var effectiveActivityToastWidth: CGFloat {
        guard let activityToast else { return 0 }
        let requested = NotchActivityToastMetrics.requiredWidth(for: activityToast)
        guard let activityToastWidth else { return requested }
        guard activityToastWidth.isFinite else { return 0 }
        return min(requested, max(0, activityToastWidth))
    }

    /// Returns the stable visual order while preserving the caller's account
    /// values. Numeric suffixes make C1…C4 order correctly even if input is shuffled.
    public static func orderedAccounts(_ accounts: [AccountState], for side: NotchSide) -> [AccountState] {
        accounts.sorted { lhs, rhs in
            let leftOrdinal = ordinal(for: lhs.id)
            let rightOrdinal = ordinal(for: rhs.id)
            if leftOrdinal != rightOrdinal { return leftOrdinal < rightOrdinal }
            return lhs.id < rhs.id
        }
    }

    private static func ordinal(for id: String) -> Int {
        let suffix = id.drop { $0.isLetter }
        return Int(suffix) ?? Int.max
    }
}
