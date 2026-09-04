import Combine
import Foundation

/// UserDefaults-backed preferences with deterministic normalization for the
/// four-account monitor. This type never reads authentication files.
@MainActor
public final class PreferencesStore: ObservableObject {
    public enum Keys {
        public static let refreshIntervalMinutes = "CodexQuotaMonitor.refreshIntervalMinutes"
        public static let accountPaths = "CodexQuotaMonitor.accountPaths"
        public static let launchAtLogin = "CodexQuotaMonitor.launchAtLogin"
        public static let showAccountLabels = "CodexQuotaMonitor.showAccountLabels"
        public static let activityNotificationDurationSeconds = "CodexQuotaMonitor.activityNotificationDurationSeconds"
        public static let lastSuccessfulQuotaSnapshots = "CodexQuotaMonitor.lastSuccessfulQuotaSnapshots"
    }

    /// The small, local-only part of a successful account response that is
    /// useful while the next refresh is in progress. It deliberately excludes
    /// identity, credentials, and the raw app-server response.
    public struct QuotaSnapshot: Codable, Equatable, Sendable {
        public let usedPercent: Double?
        public let remainingPercent: Double?
        public let resetAt: Date?
        public let secondaryUsedPercent: Double?
        public let secondaryRemainingPercent: Double?
        public let secondaryResetAt: Date?
        public let lastUpdated: Date?

        public var primaryUsedPercent: Double? { usedPercent }
        public var primaryRemainingPercent: Double? { remainingPercent }
        public var primaryResetAt: Date? { resetAt }

        public init(
            usedPercent: Double? = nil,
            remainingPercent: Double? = nil,
            resetAt: Date? = nil,
            secondaryUsedPercent: Double? = nil,
            secondaryRemainingPercent: Double? = nil,
            secondaryResetAt: Date? = nil,
            lastUpdated: Date? = nil
        ) {
            self.usedPercent = usedPercent.map(AccountState.clampPercent)
            self.remainingPercent = remainingPercent.map(AccountState.clampPercent)
            self.resetAt = resetAt
            self.secondaryUsedPercent = secondaryUsedPercent.map(AccountState.clampPercent)
            self.secondaryRemainingPercent = secondaryRemainingPercent.map(AccountState.clampPercent)
            self.secondaryResetAt = secondaryResetAt
            self.lastUpdated = lastUpdated
        }
    }

    public static let accountPathCount = 4
    nonisolated public static let defaultActivityNotificationDurationSeconds = 3
    nonisolated public static let minimumActivityNotificationDurationSeconds = 1
    nonisolated public static let maximumActivityNotificationDurationSeconds = 10

    @Published public private(set) var refreshIntervalMinutes: Int
    @Published public private(set) var accountPaths: [String]
    @Published public private(set) var launchAtLogin: Bool
    @Published public private(set) var showAccountLabels: Bool
    @Published public private(set) var activityNotificationDurationSeconds: Int

    private let userDefaults: UserDefaults
    private let defaultPaths: [String]
    private let homeDirectory: URL
    private let fileSystem: AccountPathFileSystem
    private var quotaSnapshotsStorage: [String: QuotaSnapshot]

    public init(
        userDefaults: UserDefaults = .standard,
        defaultPaths: [String]? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileSystem: AccountPathFileSystem = .live
    ) {
        self.userDefaults = userDefaults
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.fileSystem = fileSystem
        let requestedDefaults = defaultPaths ?? AccountConfig.defaultAccounts(homeDirectory: self.homeDirectory).map { $0.home.path }
        self.defaultPaths = Self.normalizedDefaultPaths(requestedDefaults, homeDirectory: self.homeDirectory)

        let rawInterval = userDefaults.object(forKey: Keys.refreshIntervalMinutes)
        let persistedInterval = rawInterval as? Int
        let normalizedInterval = RefreshService.normalizedIntervalMinutes(persistedInterval ?? 5)
        self.refreshIntervalMinutes = normalizedInterval

        let rawPaths = userDefaults.object(forKey: Keys.accountPaths)
        let persistedPaths = rawPaths as? [String]
        let normalizedPathResult = Self.normalizedPathResult(
            persistedPaths,
            defaults: self.defaultPaths,
            homeDirectory: self.homeDirectory
        )
        if let persistedPaths, persistedPaths.count == Self.accountPathCount {
            self.accountPaths = Self.validatedPersistedPaths(
                normalizedPathResult.values,
                homeDirectory: self.homeDirectory,
                fileSystem: self.fileSystem
            )
        } else {
            self.accountPaths = normalizedPathResult.values
        }

        let rawLaunchAtLogin = userDefaults.object(forKey: Keys.launchAtLogin)
        self.launchAtLogin = rawLaunchAtLogin as? Bool ?? false
        let rawShowAccountLabels = userDefaults.object(forKey: Keys.showAccountLabels)
        let persistedShowAccountLabels = rawShowAccountLabels as? Bool
        self.showAccountLabels = persistedShowAccountLabels ?? false
        let rawActivityDuration = userDefaults.object(forKey: Keys.activityNotificationDurationSeconds)
        let persistedActivityDuration = rawActivityDuration as? Int
        self.activityNotificationDurationSeconds = Self.normalizedActivityNotificationDurationSeconds(
            persistedActivityDuration ?? Self.defaultActivityNotificationDurationSeconds
        )
        let rawQuotaSnapshots = userDefaults.data(forKey: Keys.lastSuccessfulQuotaSnapshots)
        self.quotaSnapshotsStorage = Self.decodedQuotaSnapshots(
            rawQuotaSnapshots,
            homeDirectory: self.homeDirectory
        )

        // Missing keys are allowed to remain absent. Invalid or non-canonical
        // raw values are written back once so subsequent launches read the
        // canonical representation directly.
        let intervalNeedsPersistence = rawInterval != nil && persistedInterval != normalizedInterval
        let pathsNeedPersistence = rawPaths != nil && persistedPaths != self.accountPaths
        let launchNeedsPersistence = rawLaunchAtLogin != nil && rawLaunchAtLogin as? Bool == nil
        let showLabelsNeedPersistence = rawShowAccountLabels != nil && persistedShowAccountLabels == nil
        let activityDurationNeedsPersistence = rawActivityDuration != nil
            && persistedActivityDuration != activityNotificationDurationSeconds
        let quotaSnapshotsNeedPersistence = rawQuotaSnapshots != nil
            && Self.encodedQuotaSnapshots(quotaSnapshotsStorage) != rawQuotaSnapshots
        if intervalNeedsPersistence || pathsNeedPersistence || launchNeedsPersistence
            || showLabelsNeedPersistence || activityDurationNeedsPersistence || quotaSnapshotsNeedPersistence {
            persist()
        }
    }

    /// Compatibility alias for settings views that use the shorter name.
    public var intervalMinutes: Int { refreshIntervalMinutes }

    /// Compatibility alias for hosts that refer to persisted homes as paths.
    public var paths: [String] { accountPaths }

    /// Canonicalized snapshots currently retained in local settings. The
    /// dictionary key is the normalized account home path, never an account
    /// identifier, so changing a home cannot reuse another account's data.
    public var lastSuccessfulQuotaSnapshots: [String: QuotaSnapshot] {
        quotaSnapshotsStorage
    }

    public func quotaSnapshot(for accountPath: String) -> QuotaSnapshot? {
        let normalizedPath = normalizedAccountPath(accountPath)
        guard !normalizedPath.isEmpty else { return nil }
        return quotaSnapshotsStorage[normalizedPath]
    }

    public func quotaSnapshot(for accountPath: URL) -> QuotaSnapshot? {
        quotaSnapshot(for: accountPath.path)
    }

    /// Records only the quota fields needed for a loading/error placeholder.
    /// Invalid or empty paths are ignored rather than creating an unscoped
    /// snapshot entry.
    public func updateQuotaSnapshot(for accountPath: String, snapshot: QuotaSnapshot) {
        let normalizedPath = normalizedAccountPath(accountPath)
        guard !normalizedPath.isEmpty else { return }
        quotaSnapshotsStorage[normalizedPath] = snapshot
        persist()
    }

    public func updateQuotaSnapshot(for accountPath: URL, snapshot: QuotaSnapshot) {
        updateQuotaSnapshot(for: accountPath.path, snapshot: snapshot)
    }

    public func removeQuotaSnapshot(for accountPath: String) {
        let normalizedPath = normalizedAccountPath(accountPath)
        guard !normalizedPath.isEmpty else { return }
        quotaSnapshotsStorage.removeValue(forKey: normalizedPath)
        persist()
    }

    public func removeQuotaSnapshot(for accountPath: URL) {
        removeQuotaSnapshot(for: accountPath.path)
    }

    /// Returns the normalized representation used as a snapshot key.
    public func normalizedAccountPath(_ path: String) -> String {
        Self.normalizedAccountPath(path, homeDirectory: homeDirectory)
    }

    public func normalizedAccountPath(_ path: URL) -> String {
        normalizedAccountPath(path.path)
    }

    /// Validates one account path using the same injected filesystem policy as
    /// persistence. Empty paths are accepted as unconfigured.
    public func validateAccountPath(_ path: String) -> AccountPathValidation {
        AccountConfig.validatePath(
            path,
            homeDirectory: homeDirectory,
            fileSystem: fileSystem
        )
    }

    public func validateAccountPath(_ path: URL) -> AccountPathValidation {
        validateAccountPath(path.path)
    }

    public static func validateAccountPath(
        _ path: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileSystem: AccountPathFileSystem = .live
    ) -> AccountPathValidation {
        AccountConfig.validatePath(
            path,
            homeDirectory: homeDirectory,
            fileSystem: fileSystem
        )
    }

    public static func normalizedAccountPath(
        _ path: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        canonicalPath(path, homeDirectory: homeDirectory.standardizedFileURL)
    }

    /// Stores the shared bounded interval; non-positive values become the
    /// five-minute default and values above the maximum clamp before being
    /// published and persisted.
    public func updateRefreshInterval(minutes: Int) {
        refreshIntervalMinutes = RefreshService.normalizedIntervalMinutes(minutes)
        persist()
    }

    public func updateAccountPaths(_ paths: [String]) {
        guard paths.count == Self.accountPathCount else { return }

        var updatedPaths = accountPaths
        if updatedPaths.count != Self.accountPathCount {
            updatedPaths = defaultPaths
        }

        for (index, path) in paths.enumerated() {
            let normalized = AccountConfig.normalizedPath(path, homeDirectory: homeDirectory)
            switch validateAccountPath(normalized) {
            case .empty:
                // Empty is an explicit, supported unconfigured state.
                updatedPaths[index] = ""
            case .valid:
                updatedPaths[index] = normalized
            case .missing, .notDirectory, .unreadable:
                // Keep the last accepted value. This prevents an invalid
                // binding update from being persisted or queried by a host
                // that reacts to the published paths.
                continue
            }
        }

        guard updatedPaths != accountPaths else { return }
        accountPaths = updatedPaths
        persist()
    }

    public func updateLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = enabled
        persist()
    }

    public func updateShowAccountLabels(_ enabled: Bool) {
        showAccountLabels = enabled
        persist()
    }

    public func updateActivityNotificationDuration(seconds: Int) {
        activityNotificationDurationSeconds = Self.normalizedActivityNotificationDurationSeconds(seconds)
        persist()
    }

    public func setRefreshInterval(_ minutes: Int) {
        updateRefreshInterval(minutes: minutes)
    }

    public func setAccountPaths(_ paths: [String]) {
        updateAccountPaths(paths)
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        updateLaunchAtLogin(enabled)
    }

    public func setShowAccountLabels(_ enabled: Bool) {
        updateShowAccountLabels(enabled)
    }

    public func setActivityNotificationDuration(seconds: Int) {
        updateActivityNotificationDuration(seconds: seconds)
    }

    /// Compatibility aliases for hosts that spell out the persisted unit.
    public func updateActivityNotificationDurationSeconds(_ seconds: Int) {
        updateActivityNotificationDuration(seconds: seconds)
    }

    public func setActivityNotificationDurationSeconds(_ seconds: Int) {
        updateActivityNotificationDuration(seconds: seconds)
    }

    public func persist() {
        userDefaults.set(refreshIntervalMinutes, forKey: Keys.refreshIntervalMinutes)
        userDefaults.set(accountPaths, forKey: Keys.accountPaths)
        userDefaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
        userDefaults.set(showAccountLabels, forKey: Keys.showAccountLabels)
        userDefaults.set(
            activityNotificationDurationSeconds,
            forKey: Keys.activityNotificationDurationSeconds
        )
        if let encoded = Self.encodedQuotaSnapshots(quotaSnapshotsStorage), !quotaSnapshotsStorage.isEmpty {
            userDefaults.set(encoded, forKey: Keys.lastSuccessfulQuotaSnapshots)
        } else {
            userDefaults.removeObject(forKey: Keys.lastSuccessfulQuotaSnapshots)
        }
    }

    nonisolated public static func normalizedActivityNotificationDurationSeconds(_ seconds: Int) -> Int {
        min(
            max(seconds, minimumActivityNotificationDurationSeconds),
            maximumActivityNotificationDurationSeconds
        )
    }

    public static func normalizedPaths(
        _ paths: [String]?,
        defaults: [String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String] {
        normalizedPathResult(paths, defaults: defaults, homeDirectory: homeDirectory).values
    }

    private struct PathNormalization: Sendable {
        let values: [String]
        let changed: Bool
    }

    private static func normalizedPathResult(
        _ paths: [String]?,
        defaults: [String],
        homeDirectory: URL
    ) -> PathNormalization {
        let normalizedDefaults = normalizedDefaultPaths(defaults, homeDirectory: homeDirectory)
        guard let paths, paths.count == accountPathCount else {
            return PathNormalization(values: normalizedDefaults, changed: paths != nil)
        }

        let values = paths.enumerated().map { index, value in
            let canonical = canonicalPath(value, homeDirectory: homeDirectory)
            // Empty is a deliberate unconfigured value. Defaults are used
            // only when the entire persisted collection is missing or has an
            // invalid slot count.
            return canonical
        }
        return PathNormalization(values: values, changed: values != paths)
    }

    private static func validatedPersistedPaths(
        _ paths: [String],
        homeDirectory: URL,
        fileSystem: AccountPathFileSystem
    ) -> [String] {
        paths.map { path in
            let normalized = canonicalPath(path, homeDirectory: homeDirectory)
            switch AccountConfig.validatePath(
                normalized,
                homeDirectory: homeDirectory,
                fileSystem: fileSystem
            ) {
            case .empty:
                return ""
            case .valid:
                return normalized
            case .missing, .notDirectory, .unreadable:
                // A previously saved path may disappear between launches.
                // Treat it as unconfigured rather than starting a lookup at
                // a known-invalid location.
                return ""
            }
        }
    }

    private static func normalizedDefaultPaths(_ paths: [String], homeDirectory: URL) -> [String] {
        let fallback = AccountConfig.defaultAccounts(homeDirectory: homeDirectory).map { $0.home.path }
        guard paths.count == accountPathCount else { return fallback }
        return paths.enumerated().map { index, value in
            let canonical = canonicalPath(value, homeDirectory: homeDirectory)
            return canonical.isEmpty ? fallback[index] : canonical
        }
    }

    private static func canonicalPath(_ path: String, homeDirectory: URL) -> String {
        AccountConfig.normalizedPath(path, homeDirectory: homeDirectory)
    }

    private static func decodedQuotaSnapshots(
        _ data: Data?,
        homeDirectory: URL
    ) -> [String: QuotaSnapshot] {
        guard let data,
              let decoded = try? JSONDecoder().decode([String: QuotaSnapshot].self, from: data)
        else {
            return [:]
        }

        return decoded.reduce(into: [:]) { snapshots, entry in
            let normalizedPath = normalizedAccountPath(entry.key, homeDirectory: homeDirectory)
            guard !normalizedPath.isEmpty else { return }
            snapshots[normalizedPath] = entry.value
        }
    }

    private static func encodedQuotaSnapshots(_ snapshots: [String: QuotaSnapshot]) -> Data? {
        guard !snapshots.isEmpty else { return Data() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(snapshots)
    }
}
