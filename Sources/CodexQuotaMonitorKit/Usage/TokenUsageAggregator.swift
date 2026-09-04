import Foundation

/// Deterministically converts one-session records into an 84-day local
/// calendar series and inclusive today/7-day/30-day summaries.
public struct TokenUsageAggregator: Sendable {
    public static let historyDayCount = TokenUsageSnapshot.historyDayCount

    public let calendar: Calendar

    public init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
    }

    public func aggregate(
        sessions: [TokenUsageSessionUsage],
        generatedAt: Date,
        availability: TokenUsageAvailability = .available,
        error: TokenUsageSnapshotError? = nil
    ) -> TokenUsageSnapshot {
        let today = calendar.startOfDay(for: generatedAt)
        let firstDay = calendar.date(
            byAdding: .day,
            value: -(Self.historyDayCount - 1),
            to: today
        ) ?? today

        var byDay: [Date: DayAccumulator] = [:]
        for session in sessions {
            let day = calendar.startOfDay(for: session.date)
            guard day >= firstDay, day <= today else { continue }

            var accumulator = byDay[day] ?? DayAccumulator()
            accumulator.totals = accumulator.totals.adding(session.totals)
            accumulator.sessionCount = TokenUsageArithmetic.saturatingAdd(
                accumulator.sessionCount,
                1
            )
            byDay[day] = accumulator
        }

        return makeSnapshot(
            generatedAt: generatedAt,
            today: today,
            values: byDay,
            availability: availability,
            error: error
        )
    }

    public func aggregate(
        _ sessions: [TokenUsageSessionUsage],
        generatedAt: Date,
        availability: TokenUsageAvailability = .available,
        error: TokenUsageSnapshotError? = nil
    ) -> TokenUsageSnapshot {
        aggregate(
            sessions: sessions,
            generatedAt: generatedAt,
            availability: availability,
            error: error
        )
    }

    /// Aggregates pre-bucketed values. This is useful for deterministic hosts
    /// that already have one `TokenUsageDailyPoint` per source.
    public func aggregate(
        dailyPoints: [TokenUsageDailyPoint],
        generatedAt: Date,
        availability: TokenUsageAvailability = .available,
        error: TokenUsageSnapshotError? = nil
    ) -> TokenUsageSnapshot {
        let today = calendar.startOfDay(for: generatedAt)
        let firstDay = calendar.date(
            byAdding: .day,
            value: -(Self.historyDayCount - 1),
            to: today
        ) ?? today

        var byDay: [Date: DayAccumulator] = [:]
        for point in dailyPoints {
            let day = calendar.startOfDay(for: point.date)
            guard day >= firstDay, day <= today else { continue }

            var accumulator = byDay[day] ?? DayAccumulator()
            accumulator.totals = accumulator.totals.adding(point.totals)
            accumulator.sessionCount = TokenUsageArithmetic.saturatingAdd(
                accumulator.sessionCount,
                point.sessionCount
            )
            byDay[day] = accumulator
        }

        return makeSnapshot(
            generatedAt: generatedAt,
            today: today,
            values: byDay,
            availability: availability,
            error: error
        )
    }

    public func snapshot(
        sessions: [TokenUsageSessionUsage],
        generatedAt: Date,
        availability: TokenUsageAvailability = .available,
        error: TokenUsageSnapshotError? = nil
    ) -> TokenUsageSnapshot {
        aggregate(
            sessions: sessions,
            generatedAt: generatedAt,
            availability: availability,
            error: error
        )
    }

    public func emptySnapshot(
        generatedAt: Date,
        availability: TokenUsageAvailability = .available,
        error: TokenUsageSnapshotError? = nil
    ) -> TokenUsageSnapshot {
        aggregate(
            sessions: [],
            generatedAt: generatedAt,
            availability: availability,
            error: error
        )
    }

    private func makeSnapshot(
        generatedAt: Date,
        today: Date,
        values: [Date: DayAccumulator],
        availability: TokenUsageAvailability,
        error: TokenUsageSnapshotError?
    ) -> TokenUsageSnapshot {
        let points = (0..<Self.historyDayCount).compactMap { reverseOffset -> TokenUsageDailyPoint? in
            guard let date = calendar.date(byAdding: .day, value: reverseOffset - (Self.historyDayCount - 1), to: today) else {
                return nil
            }
            let value = values[date] ?? DayAccumulator()
            return TokenUsageDailyPoint(
                date: date,
                totals: value.totals,
                sessionCount: value.sessionCount
            )
        }

        // Calendar arithmetic above is expected to produce every point. Keep
        // the public invariant even if a custom Calendar ever refuses a date.
        let fixedPoints: [TokenUsageDailyPoint]
        if points.count == Self.historyDayCount {
            fixedPoints = points
        } else {
            fixedPoints = zeroFilledFallback(today: today, existing: points)
        }

        let todayTotals = rangeTotals(fixedPoints, count: 1)
        let last7Totals = rangeTotals(fixedPoints, count: 7)
        let last30Totals = rangeTotals(fixedPoints, count: 30)
        let totalSessions = fixedPoints.reduce(into: Int64.zero) { partialResult, point in
            partialResult = TokenUsageArithmetic.saturatingAdd(partialResult, point.sessionCount)
        }
        let allTotals = rangeTotals(fixedPoints, count: fixedPoints.count)
        let average = totalSessions > 0
            ? Double(allTotals.totalTokens) / Double(totalSessions)
            : 0

        return TokenUsageSnapshot(
            generatedAt: generatedAt,
            dailyPoints: fixedPoints,
            today: todayTotals,
            last7Days: last7Totals,
            last30Days: last30Totals,
            totalSessions: totalSessions,
            averageTokensPerSession: average,
            availability: availability,
            error: error
        )
    }

    private func rangeTotals(
        _ points: [TokenUsageDailyPoint],
        count: Int
    ) -> TokenUsageTotals {
        guard count > 0 else { return .zero }
        return points.suffix(count).reduce(into: TokenUsageTotals.zero) { partialResult, point in
            partialResult = partialResult.adding(point.totals)
        }
    }

    private func zeroFilledFallback(
        today: Date,
        existing: [TokenUsageDailyPoint]
    ) -> [TokenUsageDailyPoint] {
        var byDate = Dictionary(uniqueKeysWithValues: existing.map { ($0.date, $0) })
        return (0..<Self.historyDayCount).map { reverseOffset in
            let date = calendar.date(
                byAdding: .day,
                value: reverseOffset - (Self.historyDayCount - 1),
                to: today
            ) ?? today
            return byDate.removeValue(forKey: date)
                ?? TokenUsageDailyPoint(date: date)
        }
    }

    private struct DayAccumulator: Sendable {
        var totals: TokenUsageTotals = .zero
        var sessionCount: Int64 = 0
    }
}

public typealias TokenUsageAggregation = TokenUsageAggregator

