// 목적: 24주 토큰 잔디와 선택 날짜의 상시 상세 정보 표시
// 이용처: 계정 상세의 기여량·수동 업데이트 영역
// 사용방법: 기본 오늘 표시, 날짜 셀 호버 시 해당 일자로 전환
import SwiftUI

/// 168일의 로컬 기여량 표시; 24개 주별 열과 7개 요일 행 구성
public struct TokenContributionGrid: View {
    public static let columnCount = TokenUsageSnapshot.historyDayCount / rowCount
    public static let rowCount = 7
    public static let dayCount = columnCount * rowCount
    public static let notLoadedMessage = "토큰 사용량이 아직 로드되지 않았습니다. 오른쪽 위 업데이트를 눌러 확인하세요."

    public let snapshot: TokenUsageSnapshot?
    public let calendar: Calendar
    public let isLoading: Bool
    public let onUpdate: (() -> Void)?

    @State private var hoveredCell: ContributionCell?

    /// 집계 스냅샷·달력·수동 갱신 동작 초기화
    public init(
        snapshot: TokenUsageSnapshot?,
        calendar: Calendar = .autoupdatingCurrent,
        isLoading: Bool = false,
        onUpdate: (() -> Void)? = nil
    ) {
        self.snapshot = snapshot
        self.calendar = calendar
        self.isLoading = isLoading
        self.onUpdate = onUpdate
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("토큰 기여량")
                    .font(.headline.weight(.semibold))
                Text("(최근 24주)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let onUpdate {
                    Button(action: onUpdate) {
                        HStack(spacing: 6) {
                            if isLoading {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Label("업데이트", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .buttonStyle(.appAction)
                    .disabled(isLoading)
                    .help("로컬 토큰 사용량 다시 읽기")
                    .accessibilityLabel(isLoading ? "토큰 사용량 업데이트 중" : "토큰 사용량 업데이트")
                    .accessibilityHint("과거 기록을 포함한 로컬 세션 사용량을 다시 집계합니다")
                }
            }

            if let snapshot, snapshot.availability == .unavailable {
                emptyGridMessage(snapshot.error?.userMessage ?? "토큰 기여량을 읽지 못했습니다.")
            } else if let snapshot {
                Text("집계 기준: \(AccountDashboardFormatting.dateText(snapshot.generatedAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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

    /// 이전 저장 통계의 부족한 날짜를 실제 달력 기준으로 보완하여 168일 형태 유지
    public static func normalizedPoints(
        _ points: [TokenUsageDailyPoint],
        dayCount: Int = dayCount,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [TokenUsageDailyPoint] {
        let safeCount = max(0, dayCount)
        if points.count >= safeCount { return Array(points.suffix(safeCount)) }
        let missing = safeCount - points.count
        let lastDate = calendar.startOfDay(for: points.last?.date ?? Date())
        let filler = (0..<missing).map { index in
            TokenUsageDailyPoint(
                date: calendar.date(byAdding: .day, value: index - (safeCount - 1), to: lastDate) ?? lastDate,
                totals: .zero,
                sessionCount: 0
            )
        }
        return filler + points
    }

    /// 호버 날짜 우선 선택; 선택 해제·날짜 누락 시 오늘 정보와 0 사용량 제공
    public static func detailPoint(
        in snapshot: TokenUsageSnapshot,
        hoveredDate: Date?,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> TokenUsageDailyPoint {
        if let hoveredDate,
           let point = snapshot.dailyPoints.first(where: { calendar.isDate($0.date, inSameDayAs: hoveredDate) }) {
            return point
        }
        return snapshot.dailyPoints.first(where: { calendar.isDate($0.date, inSameDayAs: now) })
            ?? TokenUsageDailyPoint(date: calendar.startOfDay(for: now))
    }

    /// 동일 행에서 잔디 2/3와 날짜별 상세 1/3 배치
    @ViewBuilder
    private func grid(snapshot: TokenUsageSnapshot) -> some View {
        let points = Self.normalizedPoints(snapshot.dailyPoints, calendar: calendar)
        let intensities = TokenContributionIntensity.levels(for: points.map(\.totalTokens))
        ContributionColumnsLayout {
            GeometryReader { geometry in
                let rowSize = max(1, (geometry.size.height - 13 - 21 - 8 - 11) / CGFloat(Self.rowCount))
                let columnWidth = max(1, (geometry.size.width - 19) / CGFloat(Self.columnCount))
                let cellSize = min(rowSize, max(1, columnWidth - 2))
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 6) {
                        VStack(alignment: .trailing, spacing: 3) {
                            Color.clear.frame(width: 13, height: 13)
                            ForEach(Self.weekdayLabels(startingAt: points[0].date, calendar: calendar), id: \.self) { label in
                                Text(label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 13, height: rowSize)
                            }
                        }

                        HStack(alignment: .top, spacing: 0) {
                            ForEach(0..<Self.columnCount, id: \.self) { column in
                                let date = points[column * Self.rowCount].date
                                let showsMonth = column == 0 || !calendar.isDate(
                                    date, equalTo: points[(column - 1) * Self.rowCount].date, toGranularity: .month
                                )
                                VStack(spacing: 3) {
                                    Text(showsMonth ? monthLabel(for: date) : "")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                        .frame(width: columnWidth, height: 13, alignment: .leading)

                                    ForEach(0..<Self.rowCount, id: \.self) { row in
                                        let point = points[column * Self.rowCount + row]
                                        contributionCell(
                                            point: point,
                                            intensity: intensities[point.totalTokens] ?? .none,
                                            size: cellSize
                                        )
                                        .frame(height: rowSize)
                                    }
                                }
                                .frame(width: columnWidth)
                            }
                        }
                    }
                    legend
                        .frame(height: 11)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Contribution intensity: no data, low, medium, high, very high")
                }
            }
            contributionDetails(Self.detailPoint(in: snapshot, hoveredDate: hoveredCell?.id, calendar: calendar))
        }
        .animation(.easeOut(duration: 0.12), value: hoveredCell?.id)
    }

    /// 날짜 셀의 클릭·호버 입력에 따른 상세 정보 전환
    @ViewBuilder
    private func contributionCell(
        point: TokenUsageDailyPoint,
        intensity: TokenContributionIntensity,
        size: CGFloat
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
                .frame(width: size, height: size)
        }
        .buttonStyle(.appGraphic)
        .accessibilityLabel(Self.tooltip(for: point))
        .onHover { isHovered in
            if isHovered {
                hoveredCell = cell
            } else if hoveredCell?.id == cell.id {
                hoveredCell = nil
            }
        }
    }

    /// 오늘 또는 호버 날짜의 입력·출력·캐시·합계·세션 상시 표시
    @ViewBuilder
    private func contributionDetails(_ point: TokenUsageDailyPoint) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(AccountDashboardFormatting.dateText(point.date, dateStyle: .long, timeStyle: .none))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            metricRow(label: "입력", value: point.inputTokens)
            metricRow(label: "출력", value: point.outputTokens)
            textRow(label: "캐시", value: point.cachedInputTokens.map(AccountDashboardFormatting.numberText) ?? "—")
            metricRow(label: "합계", value: point.totalTokens)
            metricRow(label: "세션", value: point.sessionCount)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
        }
    }

    /// 날짜별 숫자 항목의 레이블·값 표시
    @ViewBuilder
    private func metricRow(label: String, value: Int64) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(AccountDashboardFormatting.numberText(value))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .font(.caption)
    }

    /// 캐시 미제공을 포함한 텍스트 항목 표시
    @ViewBuilder
    private func textRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
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

    /// 날짜별 사용량의 도움말·접근성 표시; 미제공 캐시는 대시로 구분
    public static func tooltip(for point: TokenUsageDailyPoint) -> String {
        let date = AccountDashboardFormatting.dateText(point.date, dateStyle: .medium, timeStyle: .none)
        return "\(date) · input \(AccountDashboardFormatting.numberText(point.inputTokens)), output \(AccountDashboardFormatting.numberText(point.outputTokens)), cache \(point.cachedInputTokens.map(AccountDashboardFormatting.numberText) ?? "—"), total \(AccountDashboardFormatting.numberText(point.totalTokens)), sessions \(AccountDashboardFormatting.numberText(point.sessionCount))"
    }

    /// 집계 첫 날짜와 같은 순서로 배치한 요일 라벨
    public static func weekdayLabels(startingAt date: Date, calendar: Calendar = .autoupdatingCurrent) -> [String] {
        let labels = ["일", "월", "화", "수", "목", "금", "토"]
        let firstWeekday = calendar.component(.weekday, from: date) - 1
        return (0..<rowCount).map { labels[(firstWeekday + $0) % rowCount] }
    }

    private struct ContributionCell: Identifiable, Equatable {
        let point: TokenUsageDailyPoint
        let intensity: TokenContributionIntensity

        var id: Date { point.date }
    }
}

/// 가용 너비 2:1 배분 및 오른쪽 상세 높이에 맞춘 잔디 레이아웃
private struct ContributionColumnsLayout: Layout {
    private let spacing: CGFloat = 12

    /// 상세 카드의 자연 높이와 부모 가용 너비 사용
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(0, proposal.width ?? 608)
        let unit = max(0, width - spacing) / 3
        let detail = subviews[1].sizeThatFits(ProposedViewSize(width: unit, height: nil))
        return CGSize(width: width, height: detail.height)
    }

    /// 상단 기준의 잔디 왼쪽·상세 오른쪽 배치
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let unit = max(0, bounds.width - spacing) / 3
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: unit * 2, height: bounds.height))
        subviews[1].place(at: CGPoint(x: bounds.minX + unit * 2 + spacing, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: unit, height: nil))
    }
}
