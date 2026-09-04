import SwiftUI

/// Presentation of the explicit, read-only usage-window probe.
public struct UsageWindowProbeSection: View {
    public let account: AccountState
    public let probe: UsageWindowProbePresentationResult?
    public let isRunning: Bool
    public let isConfigured: Bool
    public let onRun: () -> Void

    public init(
        account: AccountState,
        probe: UsageWindowProbePresentationResult? = nil,
        isRunning: Bool = false,
        isConfigured: Bool? = nil,
        onRun: @escaping () -> Void = {}
    ) {
        self.account = account
        self.probe = probe
        self.isRunning = isRunning
        self.isConfigured = isConfigured ?? (account.status != .notConfigured)
        self.onRun = onRun
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "flask")
                    .foregroundStyle(.purple)
                Text("Usage Window Probe")
                    .font(.headline.weight(.semibold))
                Text("(Ping)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 12) {
                probeDetails
                Spacer(minLength: 8)
                Button(action: onRun) {
                    Label(buttonTitle, systemImage: isRunning ? "hourglass" : "bolt.fill")
                        .frame(minWidth: 188)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(!canRun)
                .help("실제 Codex 사용량이 발생할 수 있습니다. 읽기 전용 Ping을 실행합니다.")
                .accessibilityLabel(buttonTitle)
                .accessibilityHint("실제 사용량이 발생할 수 있는 읽기 전용 확인입니다")
            }

            Text("최소 요청을 실행하여 사용량과 Reset 시각 변화를 관찰합니다. 실제 사용량이 발생할 수 있습니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        }
    }

    public var canRun: Bool {
        isConfigured && AccountDashboardActionState.canRunProbe(
            account: account,
            isRunning: isRunning
        )
    }

    public var buttonTitle: String {
        if isRunning { return "Ping 실행 중…" }
        return "Luna Light로 Ping 실행"
    }

    @ViewBuilder
    private var probeDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            detailRow(label: "마지막 실행", value: lastRunText)
            detailRow(label: "결과", value: resultText)
            detailRow(label: "사용 토큰", value: tokenText)
            detailRow(label: "Reset", value: resetText)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .fontWeight(.medium)
                .lineLimit(2)
        }
    }

    private var lastRunText: String {
        guard let completedAt = probe?.result.completedAt else { return "—" }
        return AccountDashboardFormatting.dateText(completedAt)
    }

    private var resultText: String {
        // While a new request is active, do not leave a previous failure or
        // success looking like the current result. The terminal categorical
        // result is shown again as soon as the callback completes.
        if isRunning { return "실행 중" }
        guard let result = probe?.result else {
            return "대기"
        }
        return result.isSuccess ? "성공" : (result.failureCategory?.userMessage ?? "실패")
    }

    private var tokenText: String {
        guard let usage = probe?.result.usage, usage.hasReportedUsage else { return "—" }
        let total = usage.totalTokensIncludingComponents
        return [
            usage.inputTokens.map { "입력 \(AccountDashboardFormatting.numberText(Int64($0)))" },
            usage.outputTokens.map { "출력 \(AccountDashboardFormatting.numberText(Int64($0)))" },
            total.map { "합계 \(AccountDashboardFormatting.numberText(Int64($0)))" },
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    private var resetText: String {
        guard let probe else { return AccountDashboardFormatting.dateText(account.primaryResetAt) }
        return AccountDashboardFormatting.resetDeltaText(
            before: probe.primaryResetBefore,
            after: probe.primaryResetAfter
        )
    }
}
