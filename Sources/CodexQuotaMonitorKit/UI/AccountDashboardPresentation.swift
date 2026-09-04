import Foundation

/// The callback contracts used by the account dashboard.  The closures are
/// deliberately account-state based so a panel can never accidentally read a
/// sibling account's home or usage data.
public typealias UsageWindowProbeRunner = @MainActor @Sendable (AccountState) async -> UsageWindowProbePresentationResult
public typealias TokenUsageSnapshotLookup = @MainActor @Sendable (String) async -> TokenUsageSnapshot?
public typealias TokenUsageSnapshotRefresh = @MainActor @Sendable (AccountState) async -> TokenUsageSnapshot
public typealias TokenUsageCacheLookup = TokenUsageSnapshotLookup
public typealias TokenUsageRefreshHandler = TokenUsageSnapshotRefresh

/// A UI-safe probe record.  Only the already bounded probe result and the two
/// observed primary reset values are retained; process output and account
/// paths are intentionally not part of this model.
public struct UsageWindowProbePresentationResult: Equatable, Sendable {
    public let result: UsageWindowProbeResult
    public let primaryResetBefore: Date?
    public let primaryResetAfter: Date?

    public init(
        result: UsageWindowProbeResult,
        primaryResetBefore: Date? = nil,
        primaryResetAfter: Date? = nil
    ) {
        self.result = result
        self.primaryResetBefore = primaryResetBefore
        self.primaryResetAfter = primaryResetAfter
    }

    public var isSuccess: Bool { result.isSuccess }
    public var usage: UsageWindowProbeTokenUsage? { result.usage }
    public var failureCategory: UsageWindowProbeFailureCategory? { result.failureCategory }
}

public typealias UsageWindowProbeCompositeResult = UsageWindowProbePresentationResult
public typealias UsageWindowProbeOutcome = UsageWindowProbePresentationResult

/// Pure formatting and semantic helpers shared by the dashboard and focused
/// presentation tests.  They never access account files or invoke a service.
public enum AccountDashboardFormatting {
    public static func numberText(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    public static func abbreviatedNumber(_ value: Int64) -> String {
        let sign = value < 0 ? "-" : ""
        let magnitude = Double(value.magnitude)
        let (scaled, suffix): (Double, String) = {
            switch magnitude {
            case 1_000_000_000...:
                return (magnitude / 1_000_000_000, "B")
            case 1_000_000...:
                return (magnitude / 1_000_000, "M")
            case 1_000...:
                return (magnitude / 1_000, "K")
            default:
                return (magnitude, "")
            }
        }()

        guard !suffix.isEmpty else { return "\(sign)\(numberText(value))" }
        let rounded: String
        if scaled >= 100 || scaled.rounded() == scaled {
            rounded = String(format: "%.0f", scaled)
        } else {
            var trimmed = String(format: "%.1f", scaled)
            while trimmed.last == "0" { trimmed.removeLast() }
            if trimmed.last == "." { trimmed.removeLast() }
            rounded = trimmed
        }
        return "\(sign)\(rounded)\(suffix)"
    }

    public static func tokenCountText(_ value: Int64) -> String {
        numberText(max(0, value))
    }

    public static func dateText(
        _ date: Date?,
        dateStyle: DateFormatter.Style = .medium,
        timeStyle: DateFormatter.Style = .short
    ) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter.string(from: date)
    }

    public static func remainingTimeText(
        until date: Date?,
        now: Date = Date()
    ) -> String {
        guard let date else { return "—" }
        let seconds = Int((date.timeIntervalSince(now)).rounded())
        guard seconds > 0 else { return "곧 초기화" }
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)시간 \(minutes)분" : "\(hours)시간"
        }
        return "\(max(1, minutes))분"
    }

    /// Presents reset observation as `before → after (▼N분)` or
    /// `before → after (▲N분)`.  A missing side is kept explicit rather than
    /// implying that the probe changed the reset schedule.
    public static func resetDeltaText(
        before: Date?,
        after: Date?,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        guard let before, let after else {
            if let after { return dateText(after, dateStyle: .none, timeStyle: .short) }
            if let before { return dateText(before, dateStyle: .none, timeStyle: .short) }
            return "—"
        }

        let beforeText = dateText(before, dateStyle: .none, timeStyle: .short)
        let afterText = dateText(after, dateStyle: .none, timeStyle: .short)
        let minutes = Int((after.timeIntervalSince(before) / 60).rounded())
        guard minutes != 0 else { return "\(beforeText) → \(afterText)" }
        let arrow = minutes < 0 ? "▼" : "▲"
        let unit = "분"
        _ = calendar
        return "\(beforeText) → \(afterText) (\(arrow)\(abs(minutes))\(unit))"
    }

    public static func dateDeltaText(
        before: Date?,
        after: Date?,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        resetDeltaText(before: before, after: after, calendar: calendar)
    }
}

public enum AccountDashboardDefaults {
    /// Produces the same fixed 84-day shape as the local provider without
    /// touching a compatibility home URL or reading any file.
    public static func unavailableTokenUsageSnapshot(
        generatedAt: Date = Date()
    ) -> TokenUsageSnapshot {
        TokenUsageAggregator().emptySnapshot(
            generatedAt: generatedAt,
            availability: .unavailable,
            error: .invalidHome
        )
    }

    /// A cache miss is intentionally distinct from an unavailable scan. It
    /// lets the dashboard render its empty state until Update is requested.
    public static let emptyTokenUsageLookup: TokenUsageSnapshotLookup = { _ in nil }

    /// Safe fallback for hosts that do not install the app's explicit update
    /// closure. It never scans a home or claims that usage was read.
    public static let unavailableTokenUsageRefresh: TokenUsageSnapshotRefresh = { _ in
        unavailableTokenUsageSnapshot()
    }

    public static func unavailableProbe(
        accountID: String,
        category: UsageWindowProbeFailureCategory = .notConfigured,
        now: Date = Date()
    ) -> UsageWindowProbePresentationResult {
        UsageWindowProbePresentationResult(
            result: UsageWindowProbeResult(
                accountID: accountID,
                status: .failure,
                startedAt: now,
                completedAt: now,
                failureCategory: category
            )
        )
    }
}

/// Relative levels used by the 12×7 contribution grid.  `.none` is also the
/// explicit no-data state; positive values map to the four visible intensity
/// levels in the reference design.
public enum TokenContributionIntensity: Int, CaseIterable, Equatable, Sendable {
    case none = 0
    case low = 1
    case medium = 2
    case high = 3
    case veryHigh = 4

    public static var noData: Self { .none }
    public static var normal: Self { .medium }
    public static var veryLow: Self { .low }

    public static func level(
        for value: Int64,
        distribution: [Int64]
    ) -> Self {
        guard value > 0 else { return .none }
        let positive = distribution.filter { $0 > 0 }.sorted()
        guard !positive.isEmpty else { return .none }
        let rank = positive.lastIndex(of: value) ?? {
            // A value not present in the supplied distribution is placed just
            // below the next observed value, preserving relative ordering.
            var insertion = 0
            while insertion < positive.count, positive[insertion] < value {
                insertion += 1
            }
            return insertion
        }()
        let bucket = min(3, (rank * 4) / max(1, positive.count))
        return [.low, .medium, .high, .veryHigh][bucket]
    }

    public static func level(for value: Int64, in distribution: [Int64]) -> Self {
        level(for: value, distribution: distribution)
    }
}

/// Non-UI action guards make it easy to test callback state without creating a
/// SwiftUI view or launching an AppKit process.
public enum AccountDashboardActionState {
    public static func canRunProbe(
        account: AccountState,
        isRunning: Bool
    ) -> Bool {
        account.status != .notConfigured && !isRunning
    }
}
