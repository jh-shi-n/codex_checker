// 목적: 네 계정 모니터의 사용자 설정 로드·정규화·영속화
import Combine
import Foundation

/// 목적: 네 계정 모니터의 사용자 설정 정규화·저장·제공
/// 제한: 인증 파일 읽기 제외
@MainActor
public final class PreferencesStore: ObservableObject {
    /// 목적: UserDefaults 저장 키 정의
    public enum Keys {
        public static let refreshIntervalMinutes = "CodexQuotaMonitor.refreshIntervalMinutes"
        public static let resetReminderMinutes = "CodexQuotaMonitor.resetReminderMinutes"
        public static let accountPaths = "CodexQuotaMonitor.accountPaths"
        public static let enabledAccountIDs = "CodexQuotaMonitor.enabledAccountIDs"
        public static let accountDisplayOrder = "CodexQuotaMonitor.accountDisplayOrder"
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
        public let resetCredits: RateLimitResetCredits?
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
            resetCredits: RateLimitResetCredits? = nil,
            lastUpdated: Date? = nil
        ) {
            self.usedPercent = usedPercent.map(AccountState.clampPercent)
            self.remainingPercent = remainingPercent.map(AccountState.clampPercent)
            self.resetAt = resetAt
            self.secondaryUsedPercent = secondaryUsedPercent.map(AccountState.clampPercent)
            self.secondaryRemainingPercent = secondaryRemainingPercent.map(AccountState.clampPercent)
            self.secondaryResetAt = secondaryResetAt
            self.resetCredits = resetCredits
            self.lastUpdated = lastUpdated
        }
    }

    public static let accountPathCount = 4
    /// 기본 표시 계정 ID: C1–C4
    nonisolated public static let stableAccountIDs = ["C1", "C2", "C3", "C4"]
    /// 초기 활성 계정 ID: 전체 계정
    nonisolated public static let defaultEnabledAccountIDs = stableAccountIDs
    /// 초기 계정 표시 순서: C1부터 C4까지
    nonisolated public static let defaultAccountDisplayOrder = stableAccountIDs
    nonisolated public static let defaultActivityNotificationDurationSeconds = 3
    nonisolated public static let minimumActivityNotificationDurationSeconds = 1
    nonisolated public static let maximumActivityNotificationDurationSeconds = 10

    @Published public private(set) var refreshIntervalMinutes: Int
    /// 초기화 사전 알림 시점; 0은 사전 알림만 해제
    @Published public private(set) var resetReminderMinutes: Int
    @Published public private(set) var accountPaths: [String]
    /// 활성 표시 계정 ID, 빈 배열 허용
    @Published public private(set) var enabledAccountIDs: [String]
    /// C1–C4 전체 계정의 표시 순서
    @Published public private(set) var accountDisplayOrder: [String]
    @Published public private(set) var launchAtLogin: Bool
    @Published public private(set) var showAccountLabels: Bool
    @Published public private(set) var activityNotificationDurationSeconds: Int

    private let userDefaults: UserDefaults
    private let defaultPaths: [String]
    private let homeDirectory: URL
    private let fileSystem: AccountPathFileSystem
    private var quotaSnapshotsStorage: [String: QuotaSnapshot]

    /// 목적: 설정값 로드, 기본값 병합, 비정규 저장값 정리
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
        self.resetReminderMinutes = Self.normalizedResetReminderMinutes(
            userDefaults.object(forKey: Keys.resetReminderMinutes) as? Int ?? 5
        )

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

        let rawEnabledAccountIDs = userDefaults.object(forKey: Keys.enabledAccountIDs)
        let persistedEnabledAccountIDs = rawEnabledAccountIDs as? [String]
        self.enabledAccountIDs = Self.normalizedAccountIDs(persistedEnabledAccountIDs)
        let rawAccountDisplayOrder = userDefaults.object(forKey: Keys.accountDisplayOrder)
        let persistedAccountDisplayOrder = rawAccountDisplayOrder as? [String]
        self.accountDisplayOrder = Self.normalizedAccountDisplayOrder(persistedAccountDisplayOrder)

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
        let enabledAccountIDsNeedPersistence = rawEnabledAccountIDs != nil
            && persistedEnabledAccountIDs != enabledAccountIDs
        let accountDisplayOrderNeedsPersistence = rawAccountDisplayOrder != nil
            && persistedAccountDisplayOrder != accountDisplayOrder
        let launchNeedsPersistence = rawLaunchAtLogin != nil && rawLaunchAtLogin as? Bool == nil
        let showLabelsNeedPersistence = rawShowAccountLabels != nil && persistedShowAccountLabels == nil
        let activityDurationNeedsPersistence = rawActivityDuration != nil
            && persistedActivityDuration != activityNotificationDurationSeconds
        let quotaSnapshotsNeedPersistence = rawQuotaSnapshots != nil
            && Self.encodedQuotaSnapshots(quotaSnapshotsStorage) != rawQuotaSnapshots
        if intervalNeedsPersistence || pathsNeedPersistence || enabledAccountIDsNeedPersistence
            || accountDisplayOrderNeedsPersistence || launchNeedsPersistence
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

    /// 사전 알림 시점 저장; 도달 시각 재조회와 알림은 별도 유지
    public func updateResetReminder(minutes: Int) {
        resetReminderMinutes = Self.normalizedResetReminderMinutes(minutes)
        persist()
    }

    /// 사전 알림 선택값의 허용 범위 정규화
    nonisolated public static func normalizedResetReminderMinutes(_ minutes: Int) -> Int {
        [0, 3, 5, 10].contains(minutes) ? minutes : 5
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

    /// 목적: 활성 계정 ID를 정규화해 게시·저장
    /// 조건: 빈 배열 허용, 유효한 C1–C4 ID만 유지
    public func updateEnabledAccountIDs(_ ids: [String]) {
        enabledAccountIDs = Self.normalizedAccountIDs(ids)
        persist()
    }

    /// 목적: 계정 표시 순서를 전체 ID 순열로 정규화해 게시·저장
    /// 조건: 누락 ID는 기본 순서대로 뒤에 추가
    public func updateAccountDisplayOrder(_ ids: [String]) {
        accountDisplayOrder = Self.normalizedAccountDisplayOrder(ids)
        persist()
    }

    /// 목적: 활성 계정만 저장된 표시 순서로 반환
    /// 반환: 입력 상태 중 활성화된 C1–C4 계정 상태
    public func visibleAccounts(_ states: [AccountState]) -> [AccountState] {
        accountDisplayOrder.compactMap { id in
            guard enabledAccountIDs.contains(id) else { return nil }
            return states.first { $0.id == id }
        }
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

    /// 목적: 현재 설정값 전체를 UserDefaults에 기록
    public func persist() {
        userDefaults.set(refreshIntervalMinutes, forKey: Keys.refreshIntervalMinutes)
        userDefaults.set(resetReminderMinutes, forKey: Keys.resetReminderMinutes)
        userDefaults.set(accountPaths, forKey: Keys.accountPaths)
        userDefaults.set(enabledAccountIDs, forKey: Keys.enabledAccountIDs)
        userDefaults.set(accountDisplayOrder, forKey: Keys.accountDisplayOrder)
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

    /// 목적: 유효한 계정 ID를 대문자 표준형·중복 없는 배열로 변환
    private static func normalizedAccountIDs(_ ids: [String]?) -> [String] {
        guard let ids else { return defaultEnabledAccountIDs }
        var normalized: [String] = []
        for id in ids {
            let canonical = id.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard stableAccountIDs.contains(canonical), !normalized.contains(canonical) else { continue }
            normalized.append(canonical)
        }
        return normalized
    }

    /// 목적: 활성 계정 ID를 전체 계정의 완전한 표시 순서로 변환
    /// 조건: 중복·알 수 없는 ID 제거 후 누락 ID를 기본 순서로 추가
    private static func normalizedAccountDisplayOrder(_ ids: [String]?) -> [String] {
        guard let ids else { return defaultAccountDisplayOrder }
        var normalized = normalizedAccountIDs(ids)
        let missingIDs = stableAccountIDs.filter { !normalized.contains($0) }
        normalized.append(contentsOf: missingIDs)
        return normalized
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
