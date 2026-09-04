import SwiftUI

/// A fixed 84-day (12 columns × 7 weekday rows) local contribution grid.
public struct TokenContributionGrid: View {
    public static let columnCount = 12
    public static let rowCount = 7
    public static let dayCount = columnCount * rowCount
    public static let notLoadedMessage = "토큰 사용량이 아직 로드되지 않았습니다. 아래 업데이트를 눌러 확인하세요."

    public let snapshot: TokenUsageSnapshot?
    public let calendar: Calendar

    @State private var hoveredCell: ContributionCell?

    public init(
        snapshot: TokenUsageSnapshot?,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.snapshot = snapshot
        self.calendar = calendar
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Token Contribution")
                    .font(.headline.weight(.semibold))
                Text("(최근 12주)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let snapshot, snapshot.availability == .unavailable {
                emptyGridMessage("Token contribution data unavailable")
            } else if let snapshot {
                grid(snapshot: snapshot)
            } else {
                emptyGridMessage(Self.notLoadedMessage)
            }
        }
    }

    /// Maps a daily value to the relative level used by the grid.  Zero is
    /// intentionally kept as `.none` so an empty day is distinguishable from
    /// a low-usage day.
    public static func intensity(
        for point: TokenUsageDailyPoint,
        points: [TokenUsageDailyPoint]
    ) -> TokenContributionIntensity {
        intensity(for: point.totalTokens, distribution: points.map(\.totalTokens))
    }

    public static func intensity(
        for value: Int64,
        distribution: [Int64]
    ) -> TokenContributionIntensity {
        TokenContributionIntensity.level(for: value, distribution: distribution)
    }

    public static func isNoData(_ point: TokenUsageDailyPoint) -> Bool {
        point.totalTokens <= 0 && point.sessionCount <= 0
    }

    /// Keeps the dashboard shape stable even when a custom test/provider
    /// supplies fewer than the contract's 84 points.
    public static func normalizedPoints(
        _ points: [TokenUsageDailyPoint],
        dayCount: Int = dayCount
    ) -> [TokenUsageDailyPoint] {
        let safeCount = max(0, dayCount)
        if points.count >= safeCount { return Array(points.suffix(safeCount)) }
        let missing = safeCount - points.count
        let filler = (0..<missing).map { index in
            TokenUsageDailyPoint(
                date: Date(timeIntervalSince1970: TimeInterval(index)),
                totals: .zero,
                sessionCount: 0
            )
        }
        return filler + points
    }

    @ViewBuilder
    private func grid(snapshot: TokenUsageSnapshot) -> some View {
        let points = Self.normalizedPoints(snapshot.dailyPoints)
        let distribution = points.map(\.totalTokens)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("")
                        .font(.caption2)
                        .frame(height: 13)
                    ForEach(Self.weekdayLabels, id: \.self) { label in
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 13, height: 13, alignment: .trailing)
                    }
                }

                HStack(alignment: .top, spacing: 4) {
                    ForEach(0..<Self.columnCount, id: \.self) { column in
                        VStack(spacing: 4) {
                            Text(monthLabel(for: points[column * Self.rowCount].date))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(height: 13)

                            ForEach(0..<Self.rowCount, id: \.self) { row in
                                let index = column * Self.rowCount + row
                                let point = points[index]
                                contributionCell(
                                    point: point,
                                    intensity: Self.intensity(for: point.totalTokens, distribution: distribution)
                                )
                            }
                        }
                    }
                }
            }
            legend
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Contribution intensity: no data, low, medium, high, very high")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if let hoveredCell {
                contributionTooltip(hoveredCell.point)
                    .zIndex(1)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hoveredCell?.id)
    }

    @ViewBuilder
    private func contributionCell(
        point: TokenUsageDailyPoint,
        intensity: TokenContributionIntensity
    ) -> some View {
        let cell = ContributionCell(point: point, intensity: intensity)
        Button {
            hoveredCell = cell
        } label: {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Self.color(for: intensity))
                .overlay {
                    if intensity == .none {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                    }
                }
                .frame(width: 13, height: 13)
        }
        .buttonStyle(.plain)
        .help(Self.tooltip(for: point))
        .accessibilityLabel(Self.tooltip(for: point))
        .onHover { isHovered in
            if isHovered {
                hoveredCell = cell
            } else if hoveredCell?.id == cell.id {
                hoveredCell = nil
            }
        }
    }

    @ViewBuilder
    private func contributionTooltip(_ point: TokenUsageDailyPoint) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(AccountDashboardFormatting.dateText(point.date, dateStyle: .long, timeStyle: .none))
                .font(.subheadline.weight(.semibold))
            metricRow(label: "입력", value: point.inputTokens)
            metricRow(label: "출력", value: point.outputTokens)
            textRow(label: "캐시", value: "—")
            metricRow(label: "합계", value: point.totalTokens)
            metricRow(label: "세션", value: point.sessionCount)
        }
        .padding(10)
        .frame(width: 190, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.94))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
    }

    @ViewBuilder
    private func metricRow(label: String, value: Int64) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(AccountDashboardFormatting.numberText(value))
                .monospacedDigit()
        }
        .font(.caption)
    }

    @ViewBuilder
    private func textRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.caption)
    }

    @ViewBuilder
    private var legend: some View {
        HStack(spacing: 7) {
            ForEach(TokenContributionIntensity.allCases, id: \.rawValue) { level in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Self.color(for: level))
                        .frame(width: 11, height: 11)
                    Text(Self.label(for: level))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func emptyGridMessage(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
    }

    private func monthLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter.string(from: date)
    }

    public static func label(for level: TokenContributionIntensity) -> String {
        switch level {
        case .none:
            return "없음"
        case .low:
            return "낮음"
        case .medium:
            return "보통"
        case .high:
            return "높음"
        case .veryHigh:
            return "매우 높음"
        }
    }

    public static func color(for level: TokenContributionIntensity) -> Color {
        switch level {
        case .none:
            return Color.white.opacity(0.08)
        case .low:
            return Color(red: 0.20, green: 0.35, blue: 0.23)
        case .medium:
            return Color(red: 0.28, green: 0.55, blue: 0.30)
        case .high:
            return Color(red: 0.39, green: 0.75, blue: 0.30)
        case .veryHigh:
            return Color(red: 0.57, green: 0.92, blue: 0.32)
        }
    }

    public static func tooltip(for point: TokenUsageDailyPoint) -> String {
        let date = AccountDashboardFormatting.dateText(point.date, dateStyle: .medium, timeStyle: .none)
        return "\(date) · input \(AccountDashboardFormatting.numberText(point.inputTokens)), output \(AccountDashboardFormatting.numberText(point.outputTokens)), cache —, total \(AccountDashboardFormatting.numberText(point.totalTokens)), sessions \(AccountDashboardFormatting.numberText(point.sessionCount))"
    }

    private static let weekdayLabels = ["월", "화", "수", "목", "금", "토", "일"]

    private struct ContributionCell: Identifiable, Equatable {
        let point: TokenUsageDailyPoint
        let intensity: TokenContributionIntensity

        var id: Date { point.date }
    }
}
