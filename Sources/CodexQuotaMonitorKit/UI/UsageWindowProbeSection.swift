import SwiftUI

/// 할당량 초기화 갱신 상태와 실행 동작 표시
public struct UsageWindowProbeSection: View {
    /// 섹션 제목
    public static let sectionTitle = "할당량 초기화 갱신"

    public let account: AccountState
    public let probe: UsageWindowProbePresentationResult?
    public let isRunning: Bool
    public let isConfigured: Bool
    public let onRun: () -> Void

    /// 계정과 최신 Reset 결과를 받는 섹션 생성
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
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.purple)
                Text(Self.sectionTitle)
                    .font(.headline.weight(.semibold))
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
                .help("최소 Ping 요청 후 최신 할당량을 조회합니다. 실제 사용량이 발생할 수 있습니다.")
                .accessibilityLabel(buttonTitle)
                .accessibilityHint("최소 요청으로 서버 사용량이 발생할 수 있습니다")
            }

            Text("최소 요청 후 서버에서 최신 할당량과 초기화 시각을 조회합니다. 실제 사용량이 발생할 수 있습니다.")
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

    /// 설정 계정의 유휴 상태 실행 허용 여부
    public var canRun: Bool {
        isConfigured && AccountDashboardActionState.canRunProbe(
            account: account,
            isRunning: isRunning
        )
    }

    /// 실행 중 여부에 따른 버튼 표시명
    public var buttonTitle: String {
        if isRunning { return "갱신 중…" }
        return "초기화 갱신"
    }

    @ViewBuilder
    private var probeDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            detailRow(label: "마지막 실행", value: lastRunText)
            detailRow(label: "결과", value: resultText)
            detailRow(label: "사용 토큰", value: tokenText)
            detailRow(label: "5시간 Reset", value: primaryResetText)
            detailRow(label: "7일 Reset", value: secondaryResetText)
        }
        .font(.caption)
    }

    /// 결과 행의 레이블과 표시값 구성
    @ViewBuilder
    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .fontWeight(.medium)
                .lineLimit(2)
        }
    }

    private var lastRunText: String {
        guard let completedAt = probe?.result.completedAt else { return "—" }
        return AccountDashboardFormatting.dateText(completedAt)
    }

    /// Ping 실행과 한도 재조회 결과를 구분한 문구
    private var resultText: String {
        // While a new request is active, do not leave a previous failure or
        // success looking like the current result. The terminal categorical
        // result is shown again as soon as the callback completes.
        if isRunning { return "실행 중" }
        guard let result = probe?.result else {
            return "대기"
        }
        if result.isSuccess, probe?.quotaRefreshSucceeded == false {
            return "Ping 성공 · 한도 조회 실패"
        }
        if result.isSuccess, probe?.quotaRefreshSucceeded == true {
            return "갱신 성공"
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

    private var primaryResetText: String {
        resetText(
            before: probe?.primaryResetBefore,
            after: probe?.primaryResetAfter,
            current: account.primaryResetAt
        )
    }

    private var secondaryResetText: String {
        resetText(
            before: probe?.secondaryResetBefore,
            after: probe?.secondaryResetAfter,
            current: account.secondaryResetAt
        )
    }

    /// 조회 결과가 없는 경우 현재 서버 시각을 유지하는 표시
    private func resetText(before: Date?, after: Date?, current: Date?) -> String {
        guard probe != nil,
              before != nil || after != nil || probe?.quotaRefreshSucceeded != nil
        else {
            return AccountDashboardFormatting.dateText(
                current,
                dateStyle: .medium,
                timeStyle: .short
            )
        }
        return AccountDashboardFormatting.resetObservationText(
            before: before,
            after: after,
            quotaRefreshSucceeded: probe?.quotaRefreshSucceeded
        )
    }
}
