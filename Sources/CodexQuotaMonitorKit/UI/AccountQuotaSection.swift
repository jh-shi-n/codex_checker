import SwiftUI

/// The two quota windows shown near the top of the account dashboard.
public struct AccountQuotaSection: View {
    public let account: AccountState

    public init(account: AccountState) {
        self.account = account
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("현재 할당량")
                        .font(.headline.weight(.semibold))
                        .fixedSize()
                    if let notice = AccountDashboardFormatting.fiveHourResetNotice(for: account, now: context.date) {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }

            HStack(alignment: .top, spacing: 8) {
                quotaCard(
                    title: "5시간 할당량",
                    subtitle: "5-hour quota",
                    remaining: account.fiveHourRemainingPercent,
                    resetAt: account.primaryResetAt,
                    observation: account.primaryResetObservation
                )
                quotaCard(
                    title: "전체 할당량",
                    subtitle: "Overall quota",
                    remaining: account.overallRemainingPercent,
                    resetAt: account.secondaryResetAt,
                    observation: account.secondaryResetObservation
                )
            }
        }
    }

    /// 한도 잔여량과 현재 실행에서 누적한 초기화 시각 관측 표시
    @ViewBuilder
    private func quotaCard(
        title: String,
        subtitle: String,
        remaining: Double?,
        resetAt: Date?,
        observation: ResetTimeObservation
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .accessibilityLabel(subtitle)

            HStack(alignment: .center, spacing: 10) {
                DashboardQuotaRing(remainingPercent: remaining)
                    .frame(width: 72, height: 72)

                VStack(alignment: .leading, spacing: 4) {
                    Text("남은 시간")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(observation == .movingObserved ? "초기화 시각 변동 중" :
                            AccountDashboardFormatting.remainingTimeText(until: resetAt))
                        .font(.caption.weight(.medium))
                        .lineLimit(1)

                    Text("초기화")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(observation == .movingObserved ? "시각 이동 관측" :
                            AccountDashboardFormatting.dateText(resetAt))
                        .font(.caption.weight(.medium))
                        .lineLimit(1)

                    Text(AccountDashboardFormatting.resetObservationStatusText(
                        observation, resetAt: resetAt, status: account.status
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                    Text(AccountDetailView.statusText(for: account.status))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(statusColor(remaining: remaining))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(subtitle), \(remaining.map { QuotaDonutView.percentText($0) } ?? "—")")
    }

    private func statusColor(remaining: Double?) -> Color {
        switch account.status {
        case .normal:
            return QuotaColors.swiftUIColor(for: remaining ?? 0)
        case .loading:
            return .accentColor
        case .notConfigured:
            return .secondary
        case .loginRequired, .codexNotFound, .timeout, .error:
            return QuotaColors.critical.swiftUIColor
        }
    }
}

/// A quota ring whose value can be selected independently of the account's
/// compact dual-window donut.
struct DashboardQuotaRing: View {
    let remainingPercent: Double?

    var body: some View {
        let value = remainingPercent.map(QuotaColors.clampedPercent)
        let progress = (value ?? 0) / 100
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: 9)
            if let value {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        QuotaColors.swiftUIColor(for: value),
                        style: StrokeStyle(lineWidth: 9, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(QuotaDonutView.percentText(value))
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                    Text("남음")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("—")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Quota \(value.map { QuotaDonutView.percentText($0) } ?? "unavailable")")
    }
}
