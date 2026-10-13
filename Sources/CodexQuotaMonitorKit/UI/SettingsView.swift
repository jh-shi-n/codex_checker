// 목적: 설정 창 라우팅과 계정 표시·앱 설정 편집 UI 제공
import SwiftUI

public enum SettingsWindowPresentationRoute: Equatable, Sendable {
    case focusSettingsScene
    case createFallback
    case focusExistingFallback
}

/// Pure routing policy used by the app delegate. A handled Settings action
/// keeps the SwiftUI scene as the host; an unhandled action gets one reusable
/// fallback host, which always wins once it exists.
public enum SettingsWindowPresentationPolicy {
    public static func route(
        actionHandled: Bool,
        hasFallbackWindow: Bool
    ) -> SettingsWindowPresentationRoute {
        if hasFallbackWindow {
            return .focusExistingFallback
        }
        return actionHandled ? .focusSettingsScene : .createFallback
    }
}

/// 목적: 호출자 바인딩을 통해 계정 표시와 앱 설정을 편집하는 화면
public struct SettingsView: View {
    public static let refreshSectionTitle = "Refresh"
    public static let activitySectionTitle = "Activity"
    public static let accountVisibilitySectionTitle = "Displayed accounts"
    public static let accountDisplayOrderSectionTitle = "Account order"
    public static let activityNotificationDurationLabel = "Activity notification duration"
    public static let launchAtLoginLabel = "Launch at login"
    public static let refreshIntervalOptions: [Int] = [1, 5, 10, 30]
    public static let minimumRefreshIntervalMinutes = RefreshService.minimumIntervalMinutes
    public static let maximumRefreshIntervalMinutes = RefreshService.maximumIntervalMinutes
    public static let accountPathCount = 4
    public static let accountPathSectionTitle = "Account paths"
    public static let minimumActivityNotificationDurationSeconds = PreferencesStore.minimumActivityNotificationDurationSeconds
    public static let maximumActivityNotificationDurationSeconds = PreferencesStore.maximumActivityNotificationDurationSeconds

    /// Draft text used by the direct minute editor. Empty/non-numeric text is
    /// not committed, while numeric values use the shared service policy.
    public struct RefreshIntervalDraft: Equatable, Sendable {
        public private(set) var text: String

        public init(value: Int) {
            self.text = String(RefreshService.normalizedIntervalMinutes(value))
        }

        public mutating func replace(text: String) {
            self.text = text
        }

        @discardableResult
        public mutating func commit() -> Int? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let value = Int(trimmed) else { return nil }
            let normalized = RefreshService.normalizedIntervalMinutes(value)
            text = String(normalized)
            return normalized
        }
    }

    @Binding public var refreshIntervalMinutes: Int
    @Binding public var accountPaths: [String]
    @Binding public var launchAtLogin: Bool
    @Binding public var showAccountLabels: Bool
    @Binding public var activityNotificationDurationSeconds: Int
    /// 화면에 표시할 활성 계정 ID 목록
    @Binding public var enabledAccountIDs: [String]
    /// 모든 계정의 표시 순서 목록
    @Binding public var accountDisplayOrder: [String]
    @State private var refreshIntervalDraft: RefreshIntervalDraft
    @State private var accountPathDrafts: [String]
    @State private var accountPathValidationErrors: [Int: AccountPathValidation]
    /// 활성 계정 바인딩의 반응형 화면 초안
    @State private var enabledAccountDraft: [String]
    /// 표시 순서 바인딩의 반응형 화면 초안
    @State private var accountDisplayOrderDraft: [String]
    private let accountPathValidator: AccountPathValidator

    /// 목적: 배열형 경로와 설정 바인딩을 사용하는 화면 초기화
    /// 호환성: 새 계정 표시 바인딩은 기본값 제공
    public init(
        refreshIntervalMinutes: Binding<Int>,
        accountPaths: Binding<[String]>,
        launchAtLogin: Binding<Bool>,
        showAccountLabels: Binding<Bool> = .constant(false),
        activityNotificationDurationSeconds: Binding<Int> = .constant(
            PreferencesStore.defaultActivityNotificationDurationSeconds
        ),
        accountPathValidator: AccountPathValidator = .live,
        enabledAccountIDs: Binding<[String]> = .constant(PreferencesStore.defaultEnabledAccountIDs),
        accountDisplayOrder: Binding<[String]> = .constant(PreferencesStore.defaultAccountDisplayOrder)
    ) {
        self._refreshIntervalMinutes = refreshIntervalMinutes
        self._accountPaths = accountPaths
        self._launchAtLogin = launchAtLogin
        self._showAccountLabels = showAccountLabels
        self._activityNotificationDurationSeconds = activityNotificationDurationSeconds
        self._enabledAccountIDs = enabledAccountIDs
        self._accountDisplayOrder = accountDisplayOrder
        self._refreshIntervalDraft = State(initialValue: RefreshIntervalDraft(value: refreshIntervalMinutes.wrappedValue))
        self._accountPathDrafts = State(initialValue: Self.paddedAccountPaths(accountPaths.wrappedValue))
        self._accountPathValidationErrors = State(initialValue: [:])
        self._enabledAccountDraft = State(
            initialValue: Self.normalizedEnabledAccountIDs(enabledAccountIDs.wrappedValue)
        )
        self._accountDisplayOrderDraft = State(
            initialValue: Self.normalizedDisplayOrder(accountDisplayOrder.wrappedValue)
        )
        self.accountPathValidator = accountPathValidator
    }

    /// 목적: 개별 경로 바인딩을 유지하는 호스트용 화면 초기화
    /// 호환성: 새 계정 표시 바인딩은 기본값 제공
    public init(
        refreshIntervalMinutes: Binding<Int>,
        account1Path: Binding<String>,
        account2Path: Binding<String>,
        account3Path: Binding<String>,
        account4Path: Binding<String>,
        launchAtLogin: Binding<Bool>,
        showAccountLabels: Binding<Bool> = .constant(false),
        activityNotificationDurationSeconds: Binding<Int> = .constant(
            PreferencesStore.defaultActivityNotificationDurationSeconds
        ),
        accountPathValidator: AccountPathValidator = .live,
        enabledAccountIDs: Binding<[String]> = .constant(PreferencesStore.defaultEnabledAccountIDs),
        accountDisplayOrder: Binding<[String]> = .constant(PreferencesStore.defaultAccountDisplayOrder)
    ) {
        self._refreshIntervalMinutes = refreshIntervalMinutes
        self._accountPaths = Binding(
            get: {
                [account1Path.wrappedValue, account2Path.wrappedValue, account3Path.wrappedValue, account4Path.wrappedValue]
            },
            set: { values in
                let normalized = values + Array(repeating: "", count: max(0, Self.accountPathCount - values.count))
                account1Path.wrappedValue = normalized[0]
                account2Path.wrappedValue = normalized[1]
                account3Path.wrappedValue = normalized[2]
                account4Path.wrappedValue = normalized[3]
            }
        )
        self._launchAtLogin = launchAtLogin
        self._showAccountLabels = showAccountLabels
        self._activityNotificationDurationSeconds = activityNotificationDurationSeconds
        self._enabledAccountIDs = enabledAccountIDs
        self._accountDisplayOrder = accountDisplayOrder
        self._refreshIntervalDraft = State(initialValue: RefreshIntervalDraft(value: refreshIntervalMinutes.wrappedValue))
        self._accountPathDrafts = State(initialValue: Self.paddedAccountPaths([
            account1Path.wrappedValue,
            account2Path.wrappedValue,
            account3Path.wrappedValue,
            account4Path.wrappedValue,
        ]))
        self._accountPathValidationErrors = State(initialValue: [:])
        self._enabledAccountDraft = State(
            initialValue: Self.normalizedEnabledAccountIDs(enabledAccountIDs.wrappedValue)
        )
        self._accountDisplayOrderDraft = State(
            initialValue: Self.normalizedDisplayOrder(accountDisplayOrder.wrappedValue)
        )
        self.accountPathValidator = accountPathValidator
    }

    /// 목적: 계정 표시·경로·갱신·시작 설정 화면 구성
    public var body: some View {
        ScrollView {
            Form {
                Section(Self.refreshSectionTitle) {
                    Picker("Quick interval", selection: refreshIntervalBinding) {
                        ForEach(Self.refreshIntervalOptions, id: \.self) { minutes in
                            Text("\(minutes) min").tag(minutes)
                        }
                    }
                    .pickerStyle(.menu)

                    HStack {
                        Text("Custom interval")
                        Spacer()
                        TextField("Minutes", text: refreshIntervalDraftBinding)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(commitRefreshIntervalDraft)
                        Stepper(
                            "",
                            value: refreshIntervalBinding,
                            in: Self.minimumRefreshIntervalMinutes...Self.maximumRefreshIntervalMinutes
                        )
                        .labelsHidden()
                    }
                    Text("Applies to all four accounts. Enter 1–1,440 minutes and press Return to apply.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(Self.accountPathSectionTitle) {
                    ForEach(0..<Self.accountPathCount, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("C\(index + 1)", text: pathBinding(at: index))
                                .textFieldStyle(.roundedBorder)
                            if let validation = accountPathValidationErrors[index],
                               let message = validation.userMessage {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .accessibilityIdentifier("account-path-error-\(index + 1)")
                            }
                        }
                    }
                }

                Section(Self.accountVisibilitySectionTitle) {
                    ForEach(PreferencesStore.stableAccountIDs, id: \.self) { accountID in
                        Toggle(accountID, isOn: enabledAccountBinding(for: accountID))
                    }
                    Text("Enabled accounts fill the left side first (up to two), then the right. If all are hidden, open Settings from the menu bar gear.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(Self.accountDisplayOrderSectionTitle) {
                    ForEach(normalizedAccountDisplayOrder, id: \.self) { accountID in
                        let order = normalizedAccountDisplayOrder
                        let index = order.firstIndex(of: accountID) ?? 0
                        HStack {
                            Text(accountID)
                            Spacer()
                            Button {
                                moveAccount(accountID, up: true)
                            } label: {
                                Image(systemName: "chevron.up")
                            }
                            .disabled(index == 0)
                            .accessibilityLabel("Move \(accountID) up")
                            .accessibilityIdentifier("account-order-up-\(accountID.lowercased())")

                            Button {
                                moveAccount(accountID, up: false)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .disabled(index == order.count - 1)
                            .accessibilityLabel("Move \(accountID) down")
                            .accessibilityIdentifier("account-order-down-\(accountID.lowercased())")
                        }
                    }
                }

                Section(Self.activitySectionTitle) {
                    Stepper(
                        value: activityNotificationDurationBinding,
                        in: Self.minimumActivityNotificationDurationSeconds...Self.maximumActivityNotificationDurationSeconds
                    ) {
                        HStack {
                            Text(Self.activityNotificationDurationLabel)
                            Spacer()
                            Text("\(activityNotificationDurationSeconds) seconds")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Startup") {
                    Toggle(Self.launchAtLoginLabel, isOn: $launchAtLogin)
                    Toggle("Show account labels (C1–C4)", isOn: $showAccountLabels)
                    Text("When enabled, the app launches automatically when you log in. macOS may ask for approval in System Settings > Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
            .padding()
        }
        .frame(minWidth: 360, minHeight: 420)
        .onAppear {
            synchronizeAccountPathDrafts()
            synchronizeAccountDisplayDrafts()
        }
        .onChange(of: accountPaths) { _, _ in synchronizeAccountPathDrafts() }
        .onChange(of: enabledAccountIDs) { _, _ in synchronizeAccountDisplayDrafts() }
        .onChange(of: accountDisplayOrder) { _, _ in synchronizeAccountDisplayDrafts() }
    }

    private var refreshIntervalBinding: Binding<Int> {
        Binding(
            get: { refreshIntervalMinutes },
            set: { value in
                let normalized = RefreshService.normalizedIntervalMinutes(value)
                refreshIntervalMinutes = normalized
                refreshIntervalDraft = RefreshIntervalDraft(value: normalized)
            }
        )
    }

    private var refreshIntervalDraftBinding: Binding<String> {
        Binding(
            get: { refreshIntervalDraft.text },
            set: { refreshIntervalDraft.replace(text: $0) }
        )
    }

    private var activityNotificationDurationBinding: Binding<Int> {
        Binding(
            get: { activityNotificationDurationSeconds },
            set: {
                activityNotificationDurationSeconds = PreferencesStore
                    .normalizedActivityNotificationDurationSeconds($0)
            }
        )
    }

    /// 목적: 표시 계정 ID별 활성 상태 바인딩 제공
    private func enabledAccountBinding(for accountID: String) -> Binding<Bool> {
        Binding(
            get: { enabledAccountDraft.contains(accountID) },
            set: { isEnabled in
                var ids = Self.normalizedEnabledAccountIDs(enabledAccountDraft)
                if isEnabled {
                    if !ids.contains(accountID) { ids.append(accountID) }
                } else {
                    ids.removeAll { $0 == accountID }
                }
                let normalized = Self.normalizedEnabledAccountIDs(ids)
                enabledAccountDraft = normalized
                enabledAccountIDs = normalized
            }
        )
    }

    /// 목적: 표시 순서를 표준 계정 ID의 완전한 순열로 제공
    private var normalizedAccountDisplayOrder: [String] {
        Self.normalizedDisplayOrder(accountDisplayOrderDraft)
    }

    /// 목적: 활성 계정·표시 순서 초안을 외부 바인딩과 동기화
    private func synchronizeAccountDisplayDrafts() {
        let enabledIDs = Self.normalizedEnabledAccountIDs(enabledAccountIDs)
        if enabledAccountDraft != enabledIDs {
            enabledAccountDraft = enabledIDs
        }
        if enabledAccountIDs != enabledIDs {
            enabledAccountIDs = enabledIDs
        }

        let displayOrder = Self.normalizedDisplayOrder(accountDisplayOrder)
        if accountDisplayOrderDraft != displayOrder {
            accountDisplayOrderDraft = displayOrder
        }
        if accountDisplayOrder != displayOrder {
            accountDisplayOrder = displayOrder
        }
    }

    /// 목적: 계정 표시 순서를 정규화해 초안·호출자 바인딩에 반영
    private func updateAccountDisplayOrder(_ ids: [String]) {
        let normalized = Self.normalizedDisplayOrder(ids)
        accountDisplayOrderDraft = normalized
        accountDisplayOrder = normalized
    }

    /// 목적: 활성 계정 ID의 대문자 표준화·중복 제거
    private static func normalizedEnabledAccountIDs(_ ids: [String]) -> [String] {
        let stableIDs = PreferencesStore.stableAccountIDs
        var normalized: [String] = []
        for rawID in ids {
            let accountID = rawID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard stableIDs.contains(accountID), !normalized.contains(accountID) else { continue }
            normalized.append(accountID)
        }
        return normalized
    }

    /// 목적: 중복·미지원 ID를 제거하고 누락 계정을 기본 순서로 추가
    private static func normalizedDisplayOrder(_ ids: [String]) -> [String] {
        let stableIDs = PreferencesStore.stableAccountIDs
        var normalized = normalizedEnabledAccountIDs(ids)
        let missingIDs = stableIDs.filter { !normalized.contains($0) }
        normalized.append(contentsOf: missingIDs)
        return normalized
    }

    /// 목적: 지정 계정을 위·아래 한 칸 이동
    private func moveAccount(_ accountID: String, up: Bool) {
        var order = normalizedAccountDisplayOrder
        guard let index = order.firstIndex(of: accountID) else { return }
        let destination = index + (up ? -1 : 1)
        guard order.indices.contains(destination) else { return }
        order.swapAt(index, destination)
        updateAccountDisplayOrder(order)
    }

    /// 목적: 직접 입력한 갱신 간격의 유효값 반영
    private func commitRefreshIntervalDraft() {
        guard let value = refreshIntervalDraft.commit() else {
            refreshIntervalDraft = RefreshIntervalDraft(value: refreshIntervalMinutes)
            return
        }
        refreshIntervalMinutes = value
    }

    /// 목적: 경로 입력을 검증하고 호출자 바인딩에 유효한 값만 전달
    private func pathBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                guard accountPathDrafts.indices.contains(index) else {
                    return accountPaths.indices.contains(index) ? accountPaths[index] : ""
                }
                return accountPathDrafts[index]
            },
            set: { value in
                var drafts = Self.paddedAccountPaths(accountPathDrafts)
                drafts[index] = value
                accountPathDrafts = drafts

                let validation = accountPathValidator.validate(value)
                switch validation {
                case .empty, .valid:
                    accountPathValidationErrors[index] = nil
                    drafts[index] = accountPathValidator.normalizedPath(value)
                    accountPathDrafts = drafts

                    var paths = Self.paddedAccountPaths(accountPaths)
                    paths[index] = drafts[index]
                    accountPaths = paths
                case .missing, .notDirectory, .unreadable:
                    // Keep invalid text in the draft so the user can correct
                    // it, but do not pass it through the caller-owned binding.
                    accountPathValidationErrors[index] = validation
                }
            }
        )
    }

    /// 목적: 외부 경로 변경에 맞춰 편집 초안과 오류 초기화
    private func synchronizeAccountPathDrafts() {
        let paths = Self.paddedAccountPaths(accountPaths)
        guard paths != accountPathDrafts else { return }
        accountPathDrafts = paths
        accountPathValidationErrors = [:]
    }

    /// 목적: 네 경로 편집을 위한 입력 배열 길이 보정
    private static func paddedAccountPaths(_ paths: [String]) -> [String] {
        let prefix = Array(paths.prefix(accountPathCount))
        return prefix + Array(repeating: "", count: max(0, accountPathCount - prefix.count))
    }
}
