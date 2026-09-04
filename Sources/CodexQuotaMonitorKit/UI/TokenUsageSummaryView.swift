import SwiftUI

/// Four compact period cards used by the account dashboard.
public struct TokenUsageSummaryView: View {
    public let snapshot: TokenUsageSnapshot?
    public let isLoading: Bool

    public init(snapshot: TokenUsageSnapshot? = nil, isLoading: Bool = false) {
        self.snapshot = snapshot
        self.isLoading = isLoading
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Token Usage")
                .font(.headline.weight(.semibold))

            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("토큰 사용량을 불러오는 중…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        } else if let snapshot, snapshot.availability == .unavailable {
            dashboardEmptyState(
                title: "Token usage unavailable",
                detail: "Local rollout usage could not be read for this account."
            )
        } else if let snapshot, hasUsage(snapshot) {
            HStack(alignment: .top, spacing: 8) {
                metricCard(title: "오늘", subtitle: "Today", totals: snapshot.today, average: average(snapshot, days: 1))
                metricCard(title: "최근 7일", subtitle: "Last 7 days", totals: snapshot.last7Days, average: average(snapshot, days: 7))
                metricCard(title: "최근 30일", subtitle: "Last 30 days", totals: snapshot.last30Days, average: average(snapshot, days: 30))
                metricCard(
                    title: "총 세션",
                    subtitle: "Total sessions",
                    totals: totalTotals(snapshot),
                    average: snapshot.averageTokensPerSession
                )
            }
        } else {
            dashboardEmptyState(
                title: "No token usage",
                detail: "No local token usage was recorded in the last 84 days."
            )
        }
    }

    @ViewBuilder
    private func metricCard(
        title: String,
        subtitle: String,
        totals: TokenUsageTotals,
        average: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            Text(AccountDashboardFormatting.abbreviatedNumber(totals.totalTokens))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .center)
            Text("tokens")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            Divider()
                .opacity(0.4)
            tokenRow(label: "입력", value: totals.inputTokens)
            tokenRow(label: "출력", value: totals.outputTokens)
            tokenRow(label: "평균", value: Int64(max(0, average.rounded())))
        }
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(subtitle), \(AccountDashboardFormatting.numberText(totals.totalTokens)) tokens, input \(AccountDashboardFormatting.numberText(totals.inputTokens)), output \(AccountDashboardFormatting.numberText(totals.outputTokens))"
        )
    }

    @ViewBuilder
    private func tokenRow(label: String, value: Int64) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 3)
            Text(AccountDashboardFormatting.numberText(value))
                .font(.caption2.weight(.medium))
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func dashboardEmptyState(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    private func hasUsage(_ snapshot: TokenUsageSnapshot) -> Bool {
        snapshot.totalSessions > 0 || snapshot.dailyPoints.contains { $0.totalTokens > 0 }
    }

    private func totalTotals(_ snapshot: TokenUsageSnapshot) -> TokenUsageTotals {
        snapshot.dailyPoints.reduce(into: TokenUsageTotals.zero) { result, point in
            result = result.adding(point.totals)
        }
    }

    private func average(_ snapshot: TokenUsageSnapshot, days: Int) -> Double {
        let points = snapshot.dailyPoints.suffix(max(1, days))
        let totals = points.reduce(into: TokenUsageTotals.zero) { result, point in
            result = result.adding(point.totals)
        }
        let sessions = points.reduce(into: Int64.zero) { result, point in
            result = TokenUsageArithmetic.saturatingAdd(result, point.sessionCount)
        }
        guard sessions > 0 else { return 0 }
        return Double(totals.totalTokens) / Double(sessions)
    }
}
