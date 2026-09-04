import Foundation
import SwiftUI

/// The visual state used by a quota donut. Account-specific error text remains
/// in `AccountState` and is shown by the detail view.
public enum QuotaDonutState: Equatable, Sendable {
    case value(Double)
    case fiveHourOnly(Double)
    case timedOut(Double)
    case transientError(Double)
    case notConfigured
    case loading
    case loginRequired
    case error

    public init(account: AccountState) {
        switch account.status {
        case .notConfigured:
            self = .notConfigured
        case .loading:
            self = .loading
        case .loginRequired:
            self = .loginRequired
        case .normal:
            if let remainingPercent = account.overallRemainingPercent {
                self = .value(QuotaColors.clampedPercent(remainingPercent))
            } else if let fiveHour = account.fiveHourRemainingPercent {
                self = .fiveHourOnly(QuotaColors.clampedPercent(fiveHour))
            } else {
                self = .error
            }
        case .timeout:
            if let remainingPercent = account.overallRemainingPercent {
                self = .timedOut(QuotaColors.clampedPercent(remainingPercent))
            } else if account.fiveHourRemainingPercent != nil {
                self = .timedOut(0)
            } else {
                self = .error
            }
        case .codexNotFound:
            self = .error
        case .error:
            if let remainingPercent = account.overallRemainingPercent {
                self = .transientError(QuotaColors.clampedPercent(remainingPercent))
            } else if account.fiveHourRemainingPercent != nil {
                self = .transientError(0)
            } else {
                self = .error
            }
        }
    }

    public var centerSymbol: String? {
        switch self {
        case .value, .fiveHourOnly, .timedOut, .transientError, .notConfigured, .loading:
            return nil
        case .loginRequired:
            return "!"
        case .error:
            return "×"
        }
    }

    public var percent: Double? {
        switch self {
        case let .value(value), let .timedOut(value), let .transientError(value):
            return QuotaColors.clampedPercent(value)
        case .fiveHourOnly, .notConfigured, .loading, .loginRequired, .error:
            return nil
        }
    }

    public var ringColor: QuotaRGB? {
        switch self {
        case let .value(value):
            return QuotaColors.color(for: value)
        case .fiveHourOnly:
            return nil
        case .timedOut, .transientError, .error:
            return QuotaColors.critical
        case .notConfigured, .loading, .loginRequired:
            return nil
        }
    }

    public var showsErrorRing: Bool {
        switch self {
        case .timedOut, .transientError, .error:
            return true
        case .value, .fiveHourOnly, .notConfigured, .loading, .loginRequired:
            return false
        }
    }

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

/// Pure display mapping: the center and ring intentionally consume different
/// quota windows so tests can guard against accidentally swapping them.
public struct QuotaDonutPresentation: Equatable, Sendable {
    public let centerPercent: Double?
    public let ringPercent: Double?
    public let ringColor: QuotaRGB?

    public init(account: AccountState) {
        switch account.status {
        case .normal, .timeout, .error:
            centerPercent = account.fiveHourRemainingPercent.map(QuotaColors.clampedPercent)
            ringPercent = account.overallRemainingPercent.map(QuotaColors.clampedPercent)
        case .notConfigured, .loading, .loginRequired, .codexNotFound:
            centerPercent = nil
            ringPercent = nil
        }

        if account.status == .timeout || account.status == .error {
            ringColor = QuotaColors.critical
        } else {
            ringColor = ringPercent.map { QuotaColors.color(for: $0) }
        }
    }
}

/// The minimal loading-animation seam shared by the renderer and pure tests.
public enum QuotaLoadingAnimationPhase: Equatable, Sendable {
    case idle
    case animating

    public init(isLoading: Bool) {
        self = isLoading ? .animating : .idle
    }
}

public enum QuotaLoadingAnimationAction: Equatable, Sendable {
    case none
    case start
    case stop
}

/// Tiny transition state machine for loading animation lifecycle. Repeated
/// loading snapshots do not restart the animation; leaving loading resets it.
public struct QuotaLoadingAnimationState: Equatable, Sendable {
    public private(set) var phase: QuotaLoadingAnimationPhase = .idle
    public private(set) var startCount = 0

    public init() {}

    @discardableResult
    public mutating func transition(isLoading: Bool) -> QuotaLoadingAnimationAction {
        switch (phase, isLoading) {
        case (.idle, true):
            phase = .animating
            startCount += 1
            return .start
        case (.animating, true):
            return .none
        case (.animating, false):
            phase = .idle
            return .stop
        case (.idle, false):
            return .none
        }
    }

    public mutating func reset() {
        phase = .idle
    }
}

public enum QuotaDonutMetrics {
    public static let ringWidth: CGFloat = 3.5
    public static let hoverScale: CGFloat = 1.07
    public static let minimumDiameter: CGFloat = 20
    public static let maximumDiameter: CGFloat = 22
    public static let accountSpacing: CGFloat = 8

    /// Keeps a menu-bar donut between the design's 20–22 pt bounds.
    public static func diameter(forMenuBarHeight menuBarHeight: CGFloat) -> CGFloat {
        guard menuBarHeight.isFinite else { return minimumDiameter }
        return min(maximumDiameter, max(minimumDiameter, menuBarHeight - 2))
    }

    /// Compact menu-bar content uses digits only so 100 remains legible inside
    /// a 20–22pt ring. Tooltip/detail presentation keeps the percent sign.
    public static func compactValueText(_ value: Double) -> String {
        String(format: "%.0f", QuotaColors.clampedPercent(value))
    }

    /// Explicit text colors for surfaces whose background is fixed outside
    /// the window's color-scheme environment, such as the black notch.
    public static func centerTextColor(for appearance: QuotaAppearance) -> QuotaRGB {
        appearance == .dark
            ? QuotaRGB(red: 0xFF, green: 0xFF, blue: 0xFF)
            : QuotaRGB(red: 0x00, green: 0x00, blue: 0x00)
    }
}

/// A compact, clickable quota donut intended for menu-bar/notch-adjacent use.
public struct QuotaDonutView: View {
    public let account: AccountState
    public let menuBarHeight: CGFloat
    public let diameterOverride: CGFloat?
    public let showAccountLabels: Bool
    public let onRefresh: () -> Void
    public let onSettings: () -> Void
    public let loadSessionActivity: SessionActivityLoader
    public let loadCachedTokenUsage: TokenUsageSnapshotLookup
    public let refreshTokenUsage: TokenUsageSnapshotRefresh
    public let runUsageWindowProbe: UsageWindowProbeRunner
    public let onClose: () -> Void

    @State private var isHovered = false
    @State private var isDetailPresented = false

    public init(
        account: AccountState,
        menuBarHeight: CGFloat = 24,
        diameterOverride: CGFloat? = nil,
        showAccountLabels: Bool = false,
        onRefresh: @escaping () -> Void = {},
        onSettings: @escaping () -> Void = {},
        loadSessionActivity: @escaping SessionActivityLoader = { account in
            .unavailable(accountID: account.id)
        },
        loadCachedTokenUsage: @escaping TokenUsageSnapshotLookup = AccountDashboardDefaults.emptyTokenUsageLookup,
        refreshTokenUsage: @escaping TokenUsageSnapshotRefresh = AccountDashboardDefaults.unavailableTokenUsageRefresh,
        runUsageWindowProbe: @escaping UsageWindowProbeRunner = { account in
            AccountDashboardDefaults.unavailableProbe(accountID: account.id)
        },
        onClose: @escaping () -> Void = {}
    ) {
        self.account = account
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
    }

    public var body: some View {
        Button {
            isDetailPresented = true
        } label: {
            QuotaRingGraphic(
                account: account,
                diameter: diameterOverride ?? QuotaDonutMetrics.diameter(forMenuBarHeight: menuBarHeight),
                showAccountLabel: showAccountLabels,
                fixedTextAppearance: .dark
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? QuotaDonutMetrics.hoverScale : 1)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
        .help(tooltip)
        .accessibilityLabel(tooltip)
        .overlay {
            TransientPopoverPresenter(isPresented: $isDetailPresented) {
                AccountDetailView(
                    account: account,
                    onRefresh: onRefresh,
                    onSettings: onSettings,
                    loadSessionActivity: loadSessionActivity,
                    loadCachedTokenUsage: loadCachedTokenUsage,
                    refreshTokenUsage: refreshTokenUsage,
                    runUsageWindowProbe: runUsageWindowProbe,
                    onClose: {
                        isDetailPresented = false
                        onClose()
                    }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        }
    }

    private var tooltip: String {
        let state = QuotaDonutState(account: account)
        let presentation = QuotaDonutPresentation(account: account)
        let fiveHour = presentation.centerPercent.map(Self.percentText) ?? "—"
        let overall = presentation.ringPercent.map(Self.percentText) ?? "—"
        let quotaText = "5h \(fiveHour) · Overall \(overall)"
        switch state {
        case .value, .fiveHourOnly:
            return "\(account.id) · \(quotaText)"
        case .timedOut:
            return "\(account.id) · \(quotaText) · Timed out"
        case .transientError:
            return "\(account.id) · \(quotaText) · Error"
        case .loading:
            return "\(account.id) · Loading"
        case .notConfigured:
            return "\(account.id) · Not configured"
        case .loginRequired:
            return "\(account.id) · Login required"
        case .error:
            return "\(account.id) · Error"
        }
    }

    static func percentText(_ value: Double) -> String {
        String(format: "%.0f%%", QuotaColors.clampedPercent(value))
    }
}

/// Shared ring renderer used by the compact menu-bar view and account details.
struct QuotaRingGraphic: View {
    let account: AccountState
    let diameter: CGFloat
    let showAccountLabel: Bool
    let fixedTextAppearance: QuotaAppearance?

    @Environment(\.colorScheme) private var colorScheme
    @State private var loadingRotation = 0.0
    @State private var loadingAnimationState = QuotaLoadingAnimationState()

    init(
        account: AccountState,
        diameter: CGFloat,
        showAccountLabel: Bool = true,
        fixedTextAppearance: QuotaAppearance? = nil
    ) {
        self.account = account
        self.diameter = diameter
        self.showAccountLabel = showAccountLabel
        self.fixedTextAppearance = fixedTextAppearance
    }

    var body: some View {
        let state = QuotaDonutState(account: account)
        let presentation = QuotaDonutPresentation(account: account)
        let progress = presentation.ringPercent.map { $0 / 100 } ?? 0
        let appearance: QuotaAppearance = colorScheme == .dark ? .dark : .light

        ZStack {
            Circle()
                .stroke(
                    QuotaColors.swiftUITrackColor(for: appearance),
                    style: StrokeStyle(lineWidth: QuotaDonutMetrics.ringWidth, lineCap: .round)
                )

            if state.isLoading {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(
                        Color.accentColor.opacity(0.76),
                        style: StrokeStyle(lineWidth: QuotaDonutMetrics.ringWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90 + loadingRotation))
            } else if let percent = presentation.ringPercent, percent > 0 {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        presentation.ringColor?.swiftUIColor ?? QuotaColors.swiftUIColor(for: percent),
                        style: StrokeStyle(lineWidth: QuotaDonutMetrics.ringWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            } else if state.showsErrorRing {
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(
                        QuotaColors.swiftUIColor(for: 0),
                        style: StrokeStyle(lineWidth: QuotaDonutMetrics.ringWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }

            VStack(spacing: showAccountLabel ? -1 : 0) {
                if let symbol = state.centerSymbol {
                    Text(symbol)
                        .font(.system(size: max(9, diameter * (showAccountLabel ? 0.68 : 0.74)), weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.65)
                } else if let percent = presentation.centerPercent {
                    Text(
                        showAccountLabel
                            ? QuotaDonutView.percentText(percent)
                            : QuotaDonutMetrics.compactValueText(percent)
                    )
                        .font(.system(
                            size: max(
                                showAccountLabel ? 6.5 : 9.5,
                                diameter * (showAccountLabel ? 0.34 : 0.48)
                            ),
                            weight: .semibold,
                            design: .rounded
                        ))
                        .minimumScaleFactor(showAccountLabel ? 0.55 : 0.7)
                        .lineLimit(1)
                }

                if showAccountLabel {
                    Text(account.id)
                        .font(.system(size: max(5, diameter * 0.26), weight: .semibold, design: .rounded))
                        .minimumScaleFactor(0.55)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(fixedTextAppearance.map {
                QuotaDonutMetrics.centerTextColor(for: $0).swiftUIColor
            } ?? .primary)
            .frame(width: diameter * (showAccountLabel ? 0.88 : 0.96), height: diameter * (showAccountLabel ? 0.78 : 0.88))
        }
        .frame(width: diameter, height: diameter)
        .onAppear {
            updateLoadingAnimation(isLoading: state.isLoading)
        }
        .onChange(of: state.isLoading) { _, isLoading in
            updateLoadingAnimation(isLoading: isLoading)
        }
        .onDisappear {
            loadingAnimationState.reset()
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                loadingRotation = 0
            }
        }
    }

    private func updateLoadingAnimation(isLoading: Bool) {
        switch loadingAnimationState.transition(isLoading: isLoading) {
        case .none:
            return
        case .stop:
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                loadingRotation = 0
            }
        case .start:
            loadingRotation = 0
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                loadingRotation = 360
            }
        }
    }
}
