import SwiftUI

/// Scrollable account dashboard presented when a quota donut is clicked.
public struct AccountDetailView: View {
    public static let minimumWidth: CGFloat = TransientPopoverSizingPolicy.contentWidth
    public static let minimumHeight: CGFloat = TransientPopoverSizingPolicy.contentHeight
    public static let popoverContentSize = TransientPopoverSizingPolicy.preferredContentSize

    public let account: AccountState
    public let onRefresh: () -> Void
    public let onSettings: () -> Void
    public let loadSessionActivity: SessionActivityLoader
    public let loadCachedTokenUsage: TokenUsageSnapshotLookup
    public let refreshTokenUsage: TokenUsageSnapshotRefresh
    public let runUsageWindowProbe: UsageWindowProbeRunner
    public let onClose: () -> Void

    @State private var tokenUsageSnapshot: TokenUsageSnapshot?
    @State private var isTokenUsageLoading = false
    @State private var isTokenUsageExpanded = false
    @State private var probePresentation: UsageWindowProbePresentationResult?
    @State private var isProbeRunning = false

    public init(
        account: AccountState,
        onRefresh: @escaping () -> Void = {},
        onSettings: @escaping () -> Void = {},
        loadSessionActivity: @escaping SessionActivityLoader = { account in
            .unavailable(accountID: account.id)
        },
        loadCachedTokenUsage: @escaping TokenUsageSnapshotLookup = AccountDashboardDefaults.emptyTokenUsageLookup,
        refreshTokenUsage: @escaping TokenUsageSnapshotRefresh = AccountDashboardDefaults.unavailableTokenUsageRefresh,
        runUsageWindowProbe: @escaping UsageWindowProbeRunner = AccountDetailView.defaultProbeRunner,
        onClose: @escaping () -> Void = {}
    ) {
        self.account = account
        self.onRefresh = onRefresh
        self.onSettings = onSettings
        self.loadSessionActivity = loadSessionActivity
        self.loadCachedTokenUsage = loadCachedTokenUsage
        self.refreshTokenUsage = refreshTokenUsage
        self.runUsageWindowProbe = runUsageWindowProbe
        self.onClose = onClose
    }

    public var tokenUsageCacheLookup: TokenUsageSnapshotLookup { loadCachedTokenUsage }
    public var tokenUsageUpdate: TokenUsageSnapshotRefresh { refreshTokenUsage }
    public var probeRunner: UsageWindowProbeRunner { runUsageWindowProbe }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 12) {
                header

                AccountQuotaSection(account: account)

                TokenContributionGrid(snapshot: tokenUsageSnapshot)

                tokenUsageDisclosure

                accountActivity

                UsageWindowProbeSection(
                    account: account,
                    probe: currentProbePresentation,
                    isRunning: isProbeRunning,
                    isConfigured: account.status != .notConfigured,
                    onRun: runProbe
                )

                if let errorMessage = account.errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                footer
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(
            width: Self.popoverContentSize.width,
            height: Self.popoverContentSize.height
        )
        .background(Color(red: 0.075, green: 0.085, blue: 0.10))
        .preferredColorScheme(.dark)
        .task(id: account.id) {
            await loadCachedTokenUsageSnapshot()
        }
        .onChange(of: account.status) { _, status in
            if status == .notConfigured {
                isProbeRunning = false
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(account.id)
                        .font(.title3.weight(.semibold))
                    Text(account.planType ?? "—")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.purple.opacity(0.16)))
                }
                Text(account.email ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onRefresh) {
                Label("새로고침", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("r", modifiers: [.command])
            .help("이 계정만 새로고침")
            .accessibilityLabel("계정 새로고침")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("닫기")
            .accessibilityLabel("계정 상세 닫기")
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var tokenUsageDisclosure: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isTokenUsageExpanded.toggle()
            } label: {
                HStack(spacing: 5) {
                    Text(isTokenUsageExpanded ? "접기" : "더보기")
                        .font(.subheadline.weight(.medium))
                    Image(systemName: isTokenUsageExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isTokenUsageExpanded ? "토큰 사용량 접기" : "토큰 사용량 더보기")
            .accessibilityValue(isTokenUsageExpanded ? "펼쳐짐" : "접힘")

            if isTokenUsageExpanded {
                TokenUsageSummaryView(
                    snapshot: tokenUsageSnapshot,
                    isLoading: isTokenUsageLoading
                )

                Button(action: updateTokenUsage) {
                    HStack(spacing: 6) {
                        if isTokenUsageLoading {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Label("업데이트", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isTokenUsageLoading)
                .help("로컬 토큰 사용량 다시 읽기")
                .accessibilityLabel(
                    isTokenUsageLoading
                        ? "토큰 사용량 업데이트 중"
                        : "토큰 사용량 업데이트"
                )
                .accessibilityHint("버튼을 누를 때만 로컬 세션 사용량을 읽습니다")
            }
        }
        .animation(.easeOut(duration: 0.15), value: isTokenUsageExpanded)
    }

    @ViewBuilder
    private var accountActivity: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("Account Activity")
                    .font(.headline.weight(.semibold))
                Text("(CLI 세션)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if account.status == .notConfigured {
                Text("Configure an account path to view Codex activity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                CLIActivitySection(
                    account: account,
                    loadSessionActivity: loadSessionActivity
                )
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: onSettings) {
                Label("설정 열기", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
            .help("설정 열기")
            .accessibilityLabel("설정 열기")

            Spacer(minLength: 0)

            Button(action: onClose) {
                Text("닫기")
                    .frame(minWidth: 50)
            }
            .buttonStyle(.borderedProminent)
            .help("계정 상세 닫기")
            .accessibilityLabel("계정 상세 닫기")
        }
    }

    private var statusColor: Color {
        switch account.status {
        case .notConfigured:
            return .secondary
        case .normal:
            return QuotaColors.swiftUIColor(
                for: account.overallRemainingPercent ?? account.fiveHourRemainingPercent ?? 0
            )
        case .loading:
            return .accentColor
        case .loginRequired, .codexNotFound, .timeout, .error:
            return QuotaColors.critical.swiftUIColor
        }
    }

    private var currentProbePresentation: UsageWindowProbePresentationResult? {
        probePresentation
    }

    private func loadCachedTokenUsageSnapshot() async {
        guard !Task.isCancelled else { return }
        let snapshot = await loadCachedTokenUsage(account.id)
        guard !Task.isCancelled else { return }
        tokenUsageSnapshot = snapshot
        isTokenUsageLoading = false
    }

    private func updateTokenUsage() {
        guard !isTokenUsageLoading else { return }
        isTokenUsageLoading = true
        Task { @MainActor in
            let snapshot = await refreshTokenUsage(account)
            guard !Task.isCancelled else { return }
            tokenUsageSnapshot = snapshot
            isTokenUsageLoading = false
        }
    }

    private func runProbe() {
        guard AccountDashboardActionState.canRunProbe(
            account: account,
            isRunning: isProbeRunning
        ) else { return }

        isProbeRunning = true
        Task { @MainActor in
            let presentation = await runUsageWindowProbe(account)
            guard !Task.isCancelled else { return }
            probePresentation = presentation
            isProbeRunning = false
        }
    }

    public static func statusText(for status: AccountStatus) -> String {
        switch status {
        case .notConfigured:
            return "Not configured"
        case .normal:
            return "Normal"
        case .loading:
            return "Loading"
        case .loginRequired:
            return "Login required"
        case .codexNotFound:
            return "Codex not found"
        case .timeout:
            return "Timed out"
        case .error:
            return "Error"
        }
    }

    public static let defaultProbeRunner: UsageWindowProbeRunner = { account in
        AccountDashboardDefaults.unavailableProbe(accountID: account.id)
    }
}
