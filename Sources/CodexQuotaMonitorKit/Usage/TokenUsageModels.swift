import Foundation

/// The two token counters that are safe for the local usage presentation.
/// Values are normalized at construction time so a malformed negative value
/// can never cross the usage boundary.
public struct TokenUsageTotals: Equatable, Sendable {
    public let inputTokens: Int64
    public let outputTokens: Int64

    public var totalTokens: Int64 {
        TokenUsageArithmetic.saturatingAdd(inputTokens, outputTokens)
    }

    public init(inputTokens: Int64 = 0, outputTokens: Int64 = 0) {
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
    }

    public static let zero = Self()

    public func adding(_ other: Self) -> Self {
        Self(
            inputTokens: TokenUsageArithmetic.saturatingAdd(inputTokens, other.inputTokens),
            outputTokens: TokenUsageArithmetic.saturatingAdd(outputTokens, other.outputTokens)
        )
    }
}

/// One rollout/session contribution on one local calendar day.
public struct TokenUsageSessionUsage: Equatable, Sendable {
    public let date: Date
    public let totals: TokenUsageTotals

    public var inputTokens: Int64 { totals.inputTokens }
    public var outputTokens: Int64 { totals.outputTokens }
    public var totalTokens: Int64 { totals.totalTokens }

    public init(date: Date, totals: TokenUsageTotals = .zero) {
        self.date = date
        self.totals = totals
    }

    public init(date: Date, inputTokens: Int64, outputTokens: Int64) {
        self.init(
            date: date,
            totals: TokenUsageTotals(inputTokens: inputTokens, outputTokens: outputTokens)
        )
    }
}

/// An already aggregated day used by the dashboard contribution grid.
public struct TokenUsageDailyPoint: Equatable, Sendable {
    public let date: Date
    public let totals: TokenUsageTotals
    public let sessionCount: Int64

    public var inputTokens: Int64 { totals.inputTokens }
    public var outputTokens: Int64 { totals.outputTokens }
    public var totalTokens: Int64 { totals.totalTokens }

    public init(
        date: Date,
        totals: TokenUsageTotals = .zero,
        sessionCount: Int64 = 0
    ) {
        self.date = date
        self.totals = totals
        self.sessionCount = max(0, sessionCount)
    }

    public init(
        date: Date,
        inputTokens: Int64,
        outputTokens: Int64,
        sessionCount: Int64 = 0
    ) {
        self.init(
            date: date,
            totals: TokenUsageTotals(inputTokens: inputTokens, outputTokens: outputTokens),
            sessionCount: sessionCount
        )
    }
}

/// Whether a snapshot can be shown. An unavailable snapshot still has a
/// zero-filled day shape when produced by `TokenUsageAggregator`.
public enum TokenUsageAvailability: String, Codable, Equatable, Sendable {
    case available
    case unavailable
}

public enum TokenUsageSnapshotError: String, Codable, Equatable, Sendable {
    case invalidHome
    case sessionsDirectoryUnavailable
}

/// Immutable, privacy-bounded usage data for one configured CODEX_HOME.
public struct TokenUsageSnapshot: Equatable, Sendable {
    public static let historyDayCount = 84

    public let generatedAt: Date
    public let dailyPoints: [TokenUsageDailyPoint]
    public let today: TokenUsageTotals
    public let last7Days: TokenUsageTotals
    public let last30Days: TokenUsageTotals
    public let totalSessions: Int64
    public let averageTokensPerSession: Double
    public let availability: TokenUsageAvailability
    public let error: TokenUsageSnapshotError?

    /// Compatibility aliases make the snapshot convenient for callers that
    /// refer to the grid as `daily` or the summaries as `*Totals`.
    public var daily: [TokenUsageDailyPoint] { dailyPoints }
    public var points: [TokenUsageDailyPoint] { dailyPoints }
    public var todayTotals: TokenUsageTotals { today }
    public var last7DaysTotals: TokenUsageTotals { last7Days }
    public var last30DaysTotals: TokenUsageTotals { last30Days }
    public var state: TokenUsageAvailability { availability }

    public init(
        generatedAt: Date,
        dailyPoints: [TokenUsageDailyPoint],
        today: TokenUsageTotals = .zero,
        last7Days: TokenUsageTotals = .zero,
        last30Days: TokenUsageTotals = .zero,
        totalSessions: Int64 = 0,
        averageTokensPerSession: Double = 0,
        availability: TokenUsageAvailability = .available,
        error: TokenUsageSnapshotError? = nil
    ) {
        self.generatedAt = generatedAt
        self.dailyPoints = dailyPoints
        self.today = today
        self.last7Days = last7Days
        self.last30Days = last30Days
        self.totalSessions = max(0, totalSessions)
        self.averageTokensPerSession = averageTokensPerSession.isFinite
            ? max(0, averageTokensPerSession)
            : 0
        self.availability = availability
        self.error = error
    }

    public init(
        generatedAt: Date,
        daily: [TokenUsageDailyPoint],
        today: TokenUsageTotals = .zero,
        last7Days: TokenUsageTotals = .zero,
        last30Days: TokenUsageTotals = .zero,
        totalSessions: Int64 = 0,
        averageTokensPerSession: Double = 0,
        availability: TokenUsageAvailability = .available,
        error: TokenUsageSnapshotError? = nil
    ) {
        self.init(
            generatedAt: generatedAt,
            dailyPoints: daily,
            today: today,
            last7Days: last7Days,
            last30Days: last30Days,
            totalSessions: totalSessions,
            averageTokensPerSession: averageTokensPerSession,
            availability: availability,
            error: error
        )
    }
}

/// A home-based provider contract keeps account credentials and account
/// metadata out of the usage reader.
public protocol TokenUsageProvider: Sendable {
    func snapshot(home: URL) async -> TokenUsageSnapshot
}

public typealias LocalTokenUsageProviding = TokenUsageProvider

public enum TokenUsageArithmetic {
    @inline(__always)
    public static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        if rhs > 0 && lhs > Int64.max - rhs { return Int64.max }
        if rhs < 0 && lhs < Int64.min - rhs { return Int64.min }
        return lhs + rhs
    }
}

public typealias DailyTokenUsage = TokenUsageDailyPoint
public typealias TokenUsageDay = TokenUsageDailyPoint
public typealias TokenUsageSummary = TokenUsageTotals
public typealias TokenUsageRolloutUsage = TokenUsageSessionUsage
