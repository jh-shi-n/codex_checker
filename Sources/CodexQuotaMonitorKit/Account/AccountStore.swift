// 목적: 계정별 한도 상태 및 비동기 조회 세대 관리
// 이용처: 앱 한도 새로고침 및 초기화 시각 갱신
// 사용방법: refreshAll 또는 refresh(accountID:forceFresh:) 호출
import Combine
import Foundation

/// The asynchronous seam used by `AccountStore` to load one account snapshot.
/// Production callers use `CodexQuotaService.state(for:)`; tests can inject a
/// deterministic loader without touching authentication files or processes.
public typealias AccountStateLoader = @Sendable (AccountConfig) async throws -> AccountState

/// Main-actor observable state for the four independent Codex accounts.
///
/// Each account has an independent generation plus a configuration revision.
/// Results from an older account refresh or reconfiguration are ignored,
/// preventing a slow request from replacing newer UI state for that account or
/// its siblings.
@MainActor
public final class AccountStore: ObservableObject {
    public static let stableAccountIDs = ["C1", "C2", "C3", "C4"]

    @Published public private(set) var configs: [AccountConfig]
    @Published public private(set) var states: [AccountState]

    /// 최신 정상 결과에서 감지한 조기 리셋 전달; 동일 결과 재조회 시 재통지 제외
    public var onEarlyQuotaReset: (@MainActor (EarlyQuotaReset) -> Void)?

    /// 일반 한도 조회 시작 시 공용 서비스 상태 갱신 요청; 계정별 결과 대기와 분리
    public var onQuotaRefreshStarted: (@MainActor () -> Void)?

    /// 계정 설정 변경에 따른 비동기 결과 격리용 버전
    public var configurationRevision: Int { configRevision }

    private let preferencesStore: PreferencesStore
    private let stateLoader: AccountStateLoader
    /// 관측 시계 주입용 내부 경계; 기본값은 현재 시각과 시스템 가동 시간
    var observationNow: @MainActor () -> Date = { Date() }
    var observationUptime: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var configRevision = 0
    private var accountGenerations: [String: Int] = [:]
    private var inFlightFetches: [FetchKey: FetchHandle] = [:]
    private var resetHistories: [String: ResetHistory] = [:]

    /// 동일 슬롯의 계정·구독 변경 시 관측 이력을 분리하는 식별 정보
    private struct ResetHistory {
        let email: String?
        let planType: String?
        var primary = ResetTimeTracker()
        var secondary = ResetTimeTracker()
    }

    public init(
        configs: [AccountConfig] = AccountConfig.defaultAccounts(),
        preferencesStore: PreferencesStore? = nil,
        stateLoader: @escaping AccountStateLoader = { config in
            await CodexQuotaService().state(for: config)
        }
    ) {
        let normalized = Self.normalizeConfigs(configs)
        let resolvedPreferencesStore = preferencesStore ?? PreferencesStore()
        self.configs = normalized
        self.preferencesStore = resolvedPreferencesStore
        self.states = normalized.map { config in
            Self.initialState(for: config, preferencesStore: resolvedPreferencesStore)
        }
        self.stateLoader = stateLoader
    }

    /// Compatibility alias for hosts that call the published snapshots
    /// account states.
    public var accountStates: [AccountState] { states }

    /// Stable left-side C1/C2 snapshots for the notch layout.
    public var leftStates: [AccountState] {
        Self.split(states, side: .left)
    }

    /// Stable right-side C3/C4 snapshots for the notch layout.
    public var rightStates: [AccountState] {
        Self.split(states, side: .right)
    }

    /// Returns the current snapshot for one stable account identifier.
    public func state(for id: String) -> AccountState? {
        states.first(where: { $0.id == id })
    }

    /// Refreshes all accounts concurrently. Every account result is applied as
    /// soon as its task finishes, and an individual failure becomes an error
    /// state without cancelling sibling tasks.
    public func refreshAll() async {
        if configs.contains(where: \.isConfigured) { onQuotaRefreshStarted?() }
        let revision = configRevision
        let configsSnapshot = configs
        let previousStates = Dictionary(uniqueKeysWithValues: states.map { ($0.id, $0) })
        var generations: [String: Int] = [:]
        for config in configsSnapshot {
            let generation = (accountGenerations[config.id] ?? 0) + 1
            accountGenerations[config.id] = generation
            generations[config.id] = generation
        }

        states = configsSnapshot.map { config in
            Self.loadingState(for: config, previous: previousStates[config.id])
        }

        let loader = stateLoader
        await withTaskGroup(of: AccountFetchResult.self) { group in
            for config in configsSnapshot {
                guard config.isConfigured else { continue }
                let previous = previousStates[config.id]
                group.addTask {
                    await self.fetchResult(
                        config: config,
                        previous: previous,
                        loader: loader,
                        revision: revision
                    )
                }
            }

            for await result in group {
                guard configRevision == revision,
                      accountGenerations[result.config.id] == generations[result.config.id]
                else { continue }
                apply(result)
            }
        }
    }

    /// 단일 계정 갱신 및 최신 정상 결과 반영 여부 반환; forceFresh 지정 시 이전 조회 재사용 방지
    @discardableResult
    public func refresh(accountID id: String, forceFresh: Bool = false) async -> Bool {
        guard let config = configs.first(where: { $0.id == id }) else { return false }

        guard config.isConfigured else {
            states = states.map { state in
                guard state.id == id else { return state }
                var initial = Self.initialState(for: config, preferencesStore: preferencesStore)
                initial.configurationGeneration = state.configurationGeneration
                return initial
            }
            return false
        }

        onQuotaRefreshStarted?()
        let revision = configRevision
        let generation = (accountGenerations[id] ?? 0) + 1
        accountGenerations[id] = generation
        let previous = state(for: id)
        states = states.map { state in
            guard state.id == id else { return state }
            return Self.loadingState(for: config, previous: previous)
        }

        let result = await fetchResult(
            config: config,
            previous: previous,
            loader: stateLoader,
            revision: revision,
            forceFresh: forceFresh
        )
        guard configRevision == revision, accountGenerations[id] == generation else { return false }
        apply(result)
        return result.state.status == .normal
    }

    /// Convenience spelling for callers holding an account configuration.
    public func refresh(_ config: AccountConfig) async {
        await refresh(accountID: config.id)
    }

    /// Replaces account paths/configuration without allowing in-flight results
    /// for the old configuration to overwrite the new one. The four stable IDs
    /// and their left/right order are always retained; omitted IDs fall back to
    /// the default account configuration.
    public func reconfigure(_ newConfigs: [AccountConfig]) {
        configRevision += 1
        for handle in inFlightFetches.values { handle.task.cancel() }
        inFlightFetches.removeAll()
        let oldStates = Dictionary(uniqueKeysWithValues: states.map { ($0.id, $0) })
        let oldConfigs = Dictionary(uniqueKeysWithValues: configs.map { ($0.id, $0) })
        let normalized = Self.normalizeConfigs(newConfigs)
        configs = normalized
        states = normalized.map { config in
            if let previous = oldStates[config.id], oldConfigs[config.id] == config {
                return previous
            }
            resetHistories[config.id] = nil
            var initial = Self.initialState(for: config, preferencesStore: preferencesStore)
            initial.configurationGeneration = (oldStates[config.id]?.configurationGeneration ?? 0) + 1
            return initial
        }
    }

    /// Reconfigures the four homes while preserving the stable side mapping.
    public func reconfigure(paths: [URL]) {
        let defaults = AccountConfig.defaultAccounts()
        let configs = Self.stableAccountIDs.enumerated().map { index, id in
            let home = paths.indices.contains(index) ? paths[index] : defaults[index].home
            let position: AccountPosition = index < 2 ? .left : .right
            return AccountConfig(id: id, home: home, position: position)
        }
        reconfigure(configs)
    }

    /// Reconfigures account homes directly from persisted path strings. This
    /// overload preserves empty slots instead of first converting them to a
    /// current-working-directory URL.
    public func reconfigure(pathStrings: [String]) {
        reconfigure(AccountConfig.accounts(for: pathStrings))
    }

    public static func split(_ states: [AccountState], side: AccountPosition) -> [AccountState] {
        let allowedIDs: Set<String> = side == .left ? ["C1", "C2"] : ["C3", "C4"]
        return states
            .filter { allowedIDs.contains($0.id) }
            .sorted { stableIndex(for: $0.id) < stableIndex(for: $1.id) }
    }

    private struct AccountFetchResult: Sendable {
        let config: AccountConfig
        let state: AccountState
    }

    private struct FetchKey: Hashable, Sendable {
        let id: String
        let homePath: String
        let revision: Int
    }

    private final class FetchHandle: @unchecked Sendable {
        let task: Task<AccountFetchResult, Never>

        init(task: Task<AccountFetchResult, Never>) {
            self.task = task
        }
    }

    /// 계정별 조회 병합 및 필요 시 새로운 조회 생성
    private func fetchResult(
        config: AccountConfig,
        previous: AccountState?,
        loader: @escaping AccountStateLoader,
        revision: Int,
        forceFresh: Bool = false
    ) async -> AccountFetchResult {
        let key = FetchKey(id: config.id, homePath: config.home.path, revision: revision)
        let handle: FetchHandle
        if !forceFresh, let existing = inFlightFetches[key] {
            handle = existing
        } else {
            let task = Task.detached(priority: nil) {
                await Self.fetch(config: config, previous: previous, loader: loader)
            }
            let created = FetchHandle(task: task)
            inFlightFetches[key] = created
            handle = created
        }

        let result = await handle.task.value
        if inFlightFetches[key] === handle {
            inFlightFetches[key] = nil
        }
        return result
    }

    nonisolated private static func fetch(
        config: AccountConfig,
        previous: AccountState?,
        loader: AccountStateLoader
    ) async -> AccountFetchResult {
        guard config.isConfigured else {
            return AccountFetchResult(
                config: config,
                state: AccountState.notConfigured(id: config.id)
            )
        }
        do {
            var state = try await loader(config)
            if state.id != config.id {
                state = AccountState(
                    id: config.id,
                    email: state.email,
                    planType: state.planType,
                    primaryUsedPercent: state.primaryUsedPercent,
                    secondaryUsedPercent: state.secondaryUsedPercent,
                    primaryResetAt: state.primaryResetAt,
                    secondaryResetAt: state.secondaryResetAt,
                    resetCredits: state.resetCredits,
                    lastUpdated: state.lastUpdated,
                    status: state.status,
                    errorMessage: state.errorMessage
                )
            }
            if Self.shouldPreservePreviousSnapshot(for: state.status) {
                state = Self.mergedNonNormalState(state, previous: previous, id: config.id)
            }
            return AccountFetchResult(config: config, state: state)
        } catch {
            return AccountFetchResult(
                config: config,
                state: Self.errorState(
                    for: config,
                    previous: previous,
                    message: String(describing: error)
                )
            )
        }
    }

    /// Timeout and generic app-server/process failures can recover on a later
    /// refresh, so retain the last successful quota for their presentation.
    /// Login-required and missing-executable states are intentionally kept
    /// distinct and must not display stale quota values.
    nonisolated private static func shouldPreservePreviousSnapshot(for status: AccountStatus) -> Bool {
        switch status {
        case .timeout, .error:
            return true
        case .notConfigured, .normal, .loading, .loginRequired, .codexNotFound:
            return false
        }
    }

    nonisolated private static func mergedNonNormalState(
        _ returned: AccountState,
        previous: AccountState?,
        id: String
    ) -> AccountState {
        guard let previous else { return returned }
        return AccountState(
            id: id,
            email: previous.email ?? returned.email,
            planType: previous.planType ?? returned.planType,
            primaryUsedPercent: previous.primaryUsedPercent ?? returned.primaryUsedPercent,
            secondaryUsedPercent: previous.secondaryUsedPercent ?? returned.secondaryUsedPercent,
            primaryResetAt: previous.primaryResetAt ?? returned.primaryResetAt,
            secondaryResetAt: previous.secondaryResetAt ?? returned.secondaryResetAt,
            resetCredits: previous.resetCredits ?? returned.resetCredits,
            lastUpdated: previous.lastUpdated ?? returned.lastUpdated,
            status: returned.status,
            errorMessage: returned.errorMessage
        )
    }

    /// 최신 상태 및 정상 스냅샷 저장 후 조기 리셋 이벤트 전달
    private func apply(_ result: AccountFetchResult) {
        guard let index = states.firstIndex(where: { $0.id == result.config.id }) else { return }
        var state = result.state
        state.configurationGeneration = states[index].configurationGeneration
        if state.status == .normal {
            var history = resetHistories[state.id]
            if history?.email != state.email || history?.planType != state.planType {
                history = nil
            }
            var current = history ?? ResetHistory(email: state.email, planType: state.planType)
            let now = observationNow()
            let uptime = observationUptime()
            let maximumGap = max(900, Double(preferencesStore.refreshIntervalMinutes) * 120 + 30)
            if let updated = state.lastUpdated,
               abs(updated.timeIntervalSince(now)) <= 30 {
                state.primaryResetObservation = current.primary.observe(
                    resetAt: state.primaryResetAt, observedAt: updated,
                    uptime: uptime, maximumGap: maximumGap
                )
                state.secondaryResetObservation = current.secondary.observe(
                    resetAt: state.secondaryResetAt, observedAt: updated,
                    uptime: uptime, maximumGap: maximumGap
                )
                resetHistories[state.id] = current
            } else {
                resetHistories[state.id] = nil
            }
        } else {
            resetHistories[state.id] = nil
            if Self.shouldPreservePreviousSnapshot(for: state.status) {
                state.primaryResetObservation = states[index].primaryResetObservation
                state.secondaryResetObservation = states[index].secondaryResetObservation
            }
        }
        states[index] = state
        guard result.config.isConfigured, result.state.status == .normal else { return }
        let earlyReset = EarlyQuotaReset.detect(
            previous: preferencesStore.quotaSnapshot(for: result.config.home),
            current: result.state
        )
        preferencesStore.updateQuotaSnapshot(
            for: result.config.home,
            snapshot: PreferencesStore.QuotaSnapshot(
                usedPercent: result.state.usedPercent,
                remainingPercent: result.state.remainingPercent,
                resetAt: result.state.resetAt,
                secondaryUsedPercent: result.state.secondaryUsedPercent,
                secondaryRemainingPercent: result.state.secondaryRemainingPercent,
                secondaryResetAt: result.state.secondaryResetAt,
                resetCredits: result.state.resetCredits,
                lastUpdated: result.state.lastUpdated
            )
        )
        if let earlyReset {
            onEarlyQuotaReset?(earlyReset)
        }
    }

    private static func initialState(
        for config: AccountConfig,
        preferencesStore: PreferencesStore
    ) -> AccountState {
        guard config.isConfigured else {
            return AccountState.notConfigured(id: config.id)
        }
        guard let snapshot = preferencesStore.quotaSnapshot(for: config.home) else {
            return AccountState.loading(id: config.id)
        }
        return AccountState(
            id: config.id,
            primaryUsedPercent: snapshot.primaryUsedPercent,
            secondaryUsedPercent: snapshot.secondaryUsedPercent,
            primaryRemainingPercent: snapshot.primaryRemainingPercent,
            secondaryRemainingPercent: snapshot.secondaryRemainingPercent,
            primaryResetAt: snapshot.primaryResetAt,
            secondaryResetAt: snapshot.secondaryResetAt,
            resetCredits: snapshot.resetCredits,
            lastUpdated: snapshot.lastUpdated,
            status: .loading
        )
    }

    /// 직전 경로 세대를 유지한 로딩 상태 구성 및 이전 오류 해제
    private static func loadingState(for config: AccountConfig, previous: AccountState?) -> AccountState {
        guard config.isConfigured else {
            var state = AccountState.notConfigured(id: config.id)
            state.configurationGeneration = previous?.configurationGeneration ?? 0
            return state
        }
        guard let previous else { return AccountState.loading(id: config.id) }
        var state = previous
        state.status = .loading
        state.errorMessage = nil
        return state
    }

    nonisolated private static func errorState(
        for config: AccountConfig,
        previous: AccountState?,
        message: String
    ) -> AccountState {
        guard let previous else {
            return AccountState(id: config.id, status: .error, errorMessage: message)
        }
        return AccountState(
            id: config.id,
            email: previous.email,
            planType: previous.planType,
            primaryUsedPercent: previous.primaryUsedPercent,
            secondaryUsedPercent: previous.secondaryUsedPercent,
            primaryResetAt: previous.primaryResetAt,
            secondaryResetAt: previous.secondaryResetAt,
            resetCredits: previous.resetCredits,
            lastUpdated: previous.lastUpdated,
            status: .error,
            errorMessage: message
        )
    }

    private static func normalizeConfigs(_ input: [AccountConfig]) -> [AccountConfig] {
        let defaults = AccountConfig.defaultAccounts()
        let byID = Dictionary(input.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return stableAccountIDs.enumerated().map { index, id in
            byID[id] ?? defaults[index]
        }
    }

    private static func stableIndex(for id: String) -> Int {
        stableAccountIDs.firstIndex(of: id) ?? stableAccountIDs.count
    }
}
