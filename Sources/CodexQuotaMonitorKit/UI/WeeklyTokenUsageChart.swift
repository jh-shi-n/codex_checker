// 목적: 월요일부터 일요일까지의 일별 토큰 막대·선그래프 표시
// 이용처: 설정으로 전환 가능한 계정 상세 토큰 사용량 영역
// 사용방법: 저장된 스냅샷과 보관 정책·명시적 업데이트 동작 전달
import Charts
import SwiftUI

/// 미래·미수집 날짜와 실제 0을 구분하는 주간 표시 행
public struct TokenUsageChartDay: Identifiable, Sendable {
    public let date: Date
    public let point: TokenUsageDailyPoint?
    public let isFuture: Bool
    public let segment: Int
    public var id: Date { date }
}

/// 달력 경계·보관 경계·누계 계산을 UI에서 분리한 주간 모델
public struct TokenUsageWeek: Sendable {
    public let start: Date
    public let end: Date
    public let days: [TokenUsageChartDay]
    public let offset: Int
    public let canGoBack: Bool
    public var canGoForward: Bool { offset < 0 }
    public var total: TokenUsageTotals { days.compactMap(\.point).reduce(.zero) { $0.adding($1.totals) } }

    /// 월~일 고정 주간과 유효한 날짜별 집계·선 구간 구성
    public init(snapshot: TokenUsageSnapshot?, now: Date = Date(), weekOffset: Int = 0,
                retentionMonths: Int = 12, calendar input: Calendar = .autoupdatingCurrent) {
        var calendar = input
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        let current = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        let cutoff = TokenUsageOptions(retentionMonths: retentionMonths).cutoff(at: now, calendar: calendar)
        let firstWeek = calendar.dateInterval(of: .weekOfYear, for: cutoff)?.start ?? cutoff
        let back = max(0, (calendar.dateComponents([.day], from: firstWeek, to: current).day ?? 0) / 7)
        offset = max(-back, min(0, weekOffset))
        start = calendar.date(byAdding: .day, value: offset * 7, to: current) ?? current
        end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        canGoBack = start > firstWeek
        let today = calendar.startOfDay(for: now)
        let available = snapshot?.availability == .available
        let points = Dictionary((snapshot?.dailyPoints ?? []).map { (calendar.startOfDay(for: $0.date), $0) }, uniquingKeysWith: { _, last in last })
        let recorded = snapshot?.recordedDates.map { Set($0.map { calendar.startOfDay(for: $0) }) }
        var segment = 0
        let selectedStart = start
        days = (0..<7).map { index in
            let date = calendar.date(byAdding: .day, value: index, to: selectedStart) ?? selectedStart
            let known = available && date >= cutoff && date <= today && (recorded?.contains(date) ?? true)
            let point = known ? points[date] : nil
            if point == nil { segment += 1 }
            return TokenUsageChartDay(date: date, point: point, isFuture: date > today, segment: segment)
        }
    }
}

/// 같은 데이터로 잔디·주간 차트를 전환하는 반응형 표시 영역
@MainActor
struct TokenUsageDisplaySection: View {
    @ObservedObject var preferences: PreferencesStore
    let snapshot: TokenUsageSnapshot?
    let isLoading: Bool
    let onUpdate: () -> Void
    let onReload: () async -> Void

    var body: some View {
        Group {
            if preferences.tokenUsageOptions.weeklyChartEnabled {
                WeeklyTokenUsageChart(snapshot: snapshot, options: preferences.tokenUsageOptions,
                    isLoading: isLoading, onUpdate: onUpdate)
            } else {
                TokenContributionGrid(snapshot: snapshot, isLoading: isLoading, onUpdate: onUpdate)
            }
        }
        .task(id: preferences.tokenUsageOptions.retentionMonths) { await onReload() }
    }
}

/// 선택 날짜 상세와 주간 누계를 제공하는 네이티브 차트
public struct WeeklyTokenUsageChart: View {
    public let snapshot: TokenUsageSnapshot?
    public let options: TokenUsageOptions
    public let isLoading: Bool
    public let onUpdate: () -> Void
    private let now: Date
    private let calendar: Calendar
    @State private var weekOffset = 0
    @State private var selectedDate: Date?

    /// 스냅샷과 표시 정책·수동 업데이트 및 검증용 달력 초기화
    public init(snapshot: TokenUsageSnapshot?, options: TokenUsageOptions, isLoading: Bool = false,
                now: Date = Date(), calendar: Calendar = .autoupdatingCurrent, onUpdate: @escaping () -> Void = {}) {
        self.snapshot = snapshot; self.options = options; self.isLoading = isLoading
        self.now = now; self.calendar = calendar; self.onUpdate = onUpdate
    }

    private var week: TokenUsageWeek {
        TokenUsageWeek(snapshot: snapshot, now: now, weekOffset: weekOffset,
                       retentionMonths: options.retentionMonths, calendar: calendar)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("일별 토큰 사용량").font(.headline)
                Spacer()
                Button(action: onUpdate) {
                    Label(isLoading ? "업데이트 중…" : "업데이트", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.appAction)
                .disabled(isLoading).help("로컬 토큰 기록 다시 읽기")
            }
            HStack {
                Button { moveWeek(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.appIcon)
                    .disabled(!week.canGoBack).accessibilityLabel("이전 주")
                Text("\(week.start.formatted(date: .abbreviated, time: .omitted)) – \(lastDay.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).monospacedDigit()
                Button { moveWeek(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.appIcon)
                    .disabled(!week.canGoForward).accessibilityLabel("다음 주")
                Spacer()
                Text(week.days.contains(where: { $0.point != nil })
                    ? "주간 \(AccountDashboardFormatting.numberText(week.total.totalTokens)) 토큰" : "주간 집계 없음")
                    .font(.caption.weight(.semibold))
            }
            if let snapshot, snapshot.availability == .available {
                chart
                detail
                Text("마지막 집계: \(AccountDashboardFormatting.dateText(snapshot.generatedAt)) · 오늘은 집계 중 · 캐시는 입력에 포함")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(snapshot?.error?.userMessage ?? "업데이트를 누르면 로컬 기록에서 일별 사용량을 집계합니다.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
            }
        }
    }

    private var lastDay: Date { calendar.date(byAdding: .day, value: -1, to: week.end) ?? week.start }

    private var chart: some View {
        Chart {
            ForEach(week.days) { day in
                if let point = day.point {
                    if options.chartStyle == .bar {
                        BarMark(x: .value("날짜", day.date, unit: .day), y: .value("토큰", point.totalTokens))
                            .foregroundStyle(Color.accentColor.opacity(isSelected(day.date) ? 1 : 0.65))
                            .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
                            .accessibilityValue("\(point.totalTokens) 토큰")
                    } else {
                        LineMark(x: .value("날짜", day.date, unit: .day), y: .value("토큰", point.totalTokens), series: .value("연속 구간", day.segment))
                            .interpolationMethod(.linear).foregroundStyle(Color.accentColor)
                        PointMark(x: .value("날짜", day.date, unit: .day), y: .value("토큰", point.totalTokens))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
        .chartXScale(domain: week.start...week.end)
        .chartYScale(domain: 0...max(5, Double(week.days.compactMap { $0.point?.totalTokens }.max() ?? 0)))
        .chartXAxis {
            AxisMarks(values: week.days.map(\.date)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        VStack(spacing: 1) {
                            Text(date, format: .dateTime.weekday(.narrow))
                            Text(date, format: .dateTime.day())
                        }
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel { if let number = value.as(Double.self) { Text(number.formatted(.number.notation(.compactName))) } }
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
                    switch phase {
                    case let .active(location):
                        if let frame = proxy.plotFrame {
                            let bounds = geometry[frame]
                            selectedDate = bounds.contains(location)
                                ? proxy.value(atX: location.x - bounds.minX, as: Date.self) : nil
                        }
                    case .ended: selectedDate = nil
                    }
                }
            }
        }
        .frame(height: 145)
    }

    private var detail: some View {
        let date = selectedDate ?? (week.offset == 0 ? now : week.start)
        let day = week.days.first { calendar.isDate($0.date, inSameDayAs: date) }
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(date.formatted(date: .abbreviated, time: .omitted))\(calendar.isDate(date, inSameDayAs: now) ? " · 오늘 집계 중" : "")")
                .fontWeight(.semibold)
            if let point = day?.point {
                Text("입력 \(AccountDashboardFormatting.numberText(point.inputTokens)) · 출력 \(AccountDashboardFormatting.numberText(point.outputTokens)) · 캐시 \(point.cachedInputTokens.map(AccountDashboardFormatting.numberText) ?? "—") · 합계 \(AccountDashboardFormatting.numberText(point.totalTokens))")
            } else { Text(day?.isFuture == true ? "아직 도래하지 않은 날짜입니다." : "이 날짜의 보관된 집계가 없습니다.") }
        }
        .font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(8)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    /// 날짜 선택 상태의 막대 강조 여부 반환
    private func isSelected(_ date: Date) -> Bool {
        calendar.isDate(date, inSameDayAs: selectedDate ?? now)
    }

    /// 허용된 주간 범위 안에서 이동하고 날짜 선택 초기화
    private func moveWeek(_ direction: Int) {
        weekOffset = week.offset + direction
        selectedDate = nil
    }
}
