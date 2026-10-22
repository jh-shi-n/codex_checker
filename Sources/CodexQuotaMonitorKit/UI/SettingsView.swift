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
    public static let refreshSectionTitle = "새로고침"
    public static let activitySectionTitle = "활동 알림"
    public static let quotaResetNotificationSectionTitle = "할당량 초기화 알림"
    public static let accountVisibilitySectionTitle = "표시할 계정"
    public static let accountDisplayOrderSectionTitle = "계정 표시 순서"
    public static let activityNotificationDurationLabel = "활동 알림 표시 시간"
    public static let launchAtLoginLabel = "로그인 시 자동 실행"
    /// 설정 창의 기본 콘텐츠 크기와 최소 콘텐츠 크기
    public static let defaultWindowSize = CGSize(width: 560, height: 720)
    public static let minimumWindowSize = CGSize(width: 480, height: 520)
    public static let refreshIntervalOptions: [Int] = [1, 5, 10, 30]
    public static let minimumRefreshIntervalMinutes = RefreshService.minimumIntervalMinutes
    public static let maximumRefreshIntervalMinutes = RefreshService.maximumIntervalMinutes
    nonisolated public static let accountPathCount = 4
    public static let accountPathSectionTitle = "계정 경로"
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

    /// 적용 전까지 계정 설정과 캐시를 변경하지 않는 경로 초안
    public struct AccountPathsDraft {
        public private(set) var paths: [String]
        private let originalPaths: [String]
        public private(set) var validationErrors: [Int: AccountPathValidation] = [:]

        /// 현재 설정의 네 계정 경로 복사
        public init(paths: [String]) {
            let prefix = Array(paths.prefix(SettingsView.accountPathCount))
            self.paths = prefix + Array(repeating: "", count: max(0, SettingsView.accountPathCount - prefix.count))
            self.originalPaths = self.paths
        }

        /// 저장된 설정에 영향을 주지 않는 입력 교체
        public mutating func replace(at index: Int, text: String) {
            guard paths.indices.contains(index) else { return }
            paths[index] = text
            validationErrors[index] = nil
        }

        /// 모든 경로의 검증 성공 시에만 정규화한 일괄 적용값 반환
        public mutating func commit(validator: AccountPathValidator) -> [String]? {
            validationErrors = [:]
            let normalized = paths.map(validator.normalizedPath)
            for (index, path) in normalized.enumerated() {
                guard path != validator.normalizedPath(originalPaths[index]) else { continue }
                let validation = validator.validate(path)
                if !validation.isAcceptable { validationErrors[index] = validation }
            }
            guard validationErrors.isEmpty else { return nil }
            paths = normalized
            return normalized
        }
    }

    @Binding public var refreshIntervalMinutes: Int
    @Binding public var resetReminderMinutes: Int
    @Binding public var accountPaths: [String]
    @Binding public var launchAtLogin: Bool
    @Binding public var showAccountLabels: Bool
    @Binding public var activityNotificationDurationSeconds: Int
    /// 화면에 표시할 활성 계정 ID 목록
    @Binding public var enabledAccountIDs: [String]
    /// 모든 계정의 표시 순서 목록
    @Binding public var accountDisplayOrder: [String]
    @ObservedObject public var notificationDelivery: QuotaResetNotificationDelivery
    @State private var refreshIntervalDraft: RefreshIntervalDraft
    @State private var accountPathsDraft: AccountPathsDraft
    /// 활성 계정 바인딩의 반응형 화면 초안
    @State private var enabledAccountDraft: [String]
    /// 표시 순서 바인딩의 반응형 화면 초안
    @State private var accountDisplayOrderDraft: [String]
    private let accountPathValidator: AccountPathValidator
    private let onRetryNotificationAuthorization: () -> Void
    private let onSendNotificationTest: () -> Void
    private let onOpenNotificationSettings: () -> Void

    /// 목적: 배열형 경로와 설정 바인딩을 사용하는 화면 초기화
    /// 호환성: 새 계정 표시 바인딩은 기본값 제공
    @MainActor
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
        accountDisplayOrder: Binding<[String]> = .constant(PreferencesStore.defaultAccountDisplayOrder),
        resetReminderMinutes: Binding<Int> = .constant(5),
        notificationDelivery: QuotaResetNotificationDelivery = .unavailable,
        onRetryNotificationAuthorization: @escaping () -> Void = {},
        onSendNotificationTest: @escaping () -> Void = {},
        onOpenNotificationSettings: @escaping () -> Void = {}
    ) {
        self._refreshIntervalMinutes = refreshIntervalMinutes
        self._resetReminderMinutes = resetReminderMinutes
        self._accountPaths = accountPaths
        self._launchAtLogin = launchAtLogin
        self._showAccountLabels = showAccountLabels
        self._activityNotificationDurationSeconds = activityNotificationDurationSeconds
        self._enabledAccountIDs = enabledAccountIDs
        self._accountDisplayOrder = accountDisplayOrder
        self._notificationDelivery = ObservedObject(wrappedValue: notificationDelivery)
        self.onRetryNotificationAuthorization = onRetryNotificationAuthorization
        self.onSendNotificationTest = onSendNotificationTest
        self.onOpenNotificationSettings = onOpenNotificationSettings
        self._refreshIntervalDraft = State(initialValue: RefreshIntervalDraft(value: refreshIntervalMinutes.wrappedValue))
        self._accountPathsDraft = State(initialValue: AccountPathsDraft(paths: accountPaths.wrappedValue))
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
    @MainActor
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
        accountDisplayOrder: Binding<[String]> = .constant(PreferencesStore.defaultAccountDisplayOrder),
        resetReminderMinutes: Binding<Int> = .constant(5),
        notificationDelivery: QuotaResetNotificationDelivery = .unavailable,
        onRetryNotificationAuthorization: @escaping () -> Void = {},
        onSendNotificationTest: @escaping () -> Void = {},
        onOpenNotificationSettings: @escaping () -> Void = {}
    ) {
        self._refreshIntervalMinutes = refreshIntervalMinutes
        self._resetReminderMinutes = resetReminderMinutes
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
        self._notificationDelivery = ObservedObject(wrappedValue: notificationDelivery)
        self.onRetryNotificationAuthorization = onRetryNotificationAuthorization
        self.onSendNotificationTest = onSendNotificationTest
        self.onOpenNotificationSettings = onOpenNotificationSettings
        self._refreshIntervalDraft = State(initialValue: RefreshIntervalDraft(value: refreshIntervalMinutes.wrappedValue))
        self._accountPathsDraft = State(initialValue: AccountPathsDraft(paths: [
            account1Path.wrappedValue,
            account2Path.wrappedValue,
            account3Path.wrappedValue,
            account4Path.wrappedValue,
        ]))
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
                    Picker("새로고침 간격", selection: refreshIntervalBinding) {
                        if !Self.refreshIntervalOptions.contains(refreshIntervalMinutes) {
                            Text("직접 입력: \(refreshIntervalMinutes)분").tag(refreshIntervalMinutes)
                        }
                        ForEach(Self.refreshIntervalOptions, id: \.self) { minutes in
                            Text("\(minutes)분").tag(minutes)
                        }
                    }
                    .pickerStyle(.menu)

                    HStack {
                        Text("직접 입력")
                        Spacer()
                        TextField("분", text: refreshIntervalDraftBinding)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(commitRefreshIntervalDraft)

                    }
                    Text("모든 계정에 적용됩니다. 1~60분을 입력한 뒤 Enter를 누르면 적용됩니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(Self.accountPathSectionTitle) {
                    ForEach(0..<Self.accountPathCount, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                TextField("C\(index + 1)", text: pathBinding(at: index))
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit(commitAccountPathsDraft)
                                Button("폴더 선택") { chooseAccountDirectory(at: index) }
                            }
                            if let validation = accountPathsDraft.validationErrors[index],
                               let message = validation.userMessage {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .accessibilityIdentifier("account-path-error-\(index + 1)")
                            }
                        }
                    }
                    HStack {
                        Button("경로 적용", action: commitAccountPathsDraft)
                            .disabled(accountPathsDraft.paths == Self.paddedAccountPaths(accountPaths))
                        Button("편집 취소", action: synchronizeAccountPathDrafts)
                            .disabled(accountPathsDraft.paths == Self.paddedAccountPaths(accountPaths))
                    }
                    Text("경로 적용 또는 Enter를 누를 때 저장됩니다. 편집 취소 시 기존 경로를 유지합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(Self.accountVisibilitySectionTitle) {
                    ForEach(PreferencesStore.stableAccountIDs, id: \.self) { accountID in
                        Toggle(accountID, isOn: enabledAccountBinding(for: accountID))
                    }
                    Text("선택한 계정은 왼쪽부터 최대 두 개씩 채워집니다. 모두 숨기거나 등록된 계정이 없으면 메뉴 막대 아이콘의 안내에서 설정을 열 수 있습니다.")
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
                            .accessibilityLabel("\(accountID) 위로 이동")
                            .accessibilityIdentifier("account-order-up-\(accountID.lowercased())")

                            Button {
                                moveAccount(accountID, up: false)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .disabled(index == order.count - 1)
                            .accessibilityLabel("\(accountID) 아래로 이동")
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
                            Text("\(activityNotificationDurationSeconds)초")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section(Self.quotaResetNotificationSectionTitle) {
                    Picker("초기화 사전 알림", selection: $resetReminderMinutes) {
                        Text("끔").tag(0)
                        Text("10분 전").tag(10)
                        Text("5분 전").tag(5)
                        Text("3분 전").tag(3)
                    }
                    Text("안정 관측된 초기화 시각에 다시 조회하고 도달 알림을 보냅니다. 사전 알림을 꺼도 도달 알림은 유지됩니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("권한: \(notificationAuthorizationText)")
                        Text("전달: \(notificationOutcomeText)")
                            .foregroundStyle(.secondary)
                        if let error = notificationDelivery.status.authorizationError {
                            Text("권한 오류: \(error)")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                        if let error = notificationDelivery.status.deliveryError {
                            Text("전달 오류: \(error)")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }

                    HStack {
                        Button("권한 요청 / 다시 확인", action: onRetryNotificationAuthorization)
                            .disabled(notificationControlsUnavailable)
                        Button("테스트 알림", action: onSendNotificationTest)
                            .disabled(notificationControlsUnavailable)
                        Button("알림 설정 열기", action: onOpenNotificationSettings)
                            .disabled(notificationControlsUnavailable)
                    }
                    Text("권한 요청은 버튼을 눌렀을 때만 진행됩니다. 권한을 거부한 경우 시스템 설정에서 변경할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("앱 실행") {
                    Toggle(Self.launchAtLoginLabel, isOn: $launchAtLogin)
                    Toggle("계정 이름 표시 (C1~C4)", isOn: $showAccountLabels)
                    Text("로그인 시 앱을 자동으로 실행합니다. macOS 시스템 설정 > 로그인 항목에서 승인이 필요할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
            .padding()
        }
        .frame(
            minWidth: Self.minimumWindowSize.width,
            idealWidth: Self.defaultWindowSize.width,
            minHeight: Self.minimumWindowSize.height,
            idealHeight: Self.defaultWindowSize.height
        )
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

    /// 목적: 권한 상태의 사용자 표시 문구 제공
    private var notificationAuthorizationText: String {
        switch notificationDelivery.status.authorization {
        case .checking: "상태 확인 중"
        case .notRequested: "아직 권한을 요청하지 않음"
        case .denied: "꺼짐 · 시스템 설정에서 허용 필요"
        case .authorized: "허용됨"
        case .provisional: "임시 허용"
        case .ephemeral: "임시 허용"
        case .unavailable: "앱 번들에서 실행되지 않아 사용할 수 없음"
        case .unknown: "알 수 없는 상태"
        case .error: "상태 확인 실패"
        }
    }

    /// 목적: 마지막 시스템 알림 전달 결과의 사용자 표시 문구 제공
    private var notificationOutcomeText: String {
        switch notificationDelivery.status.outcome {
        case .idle: "전달 기록 없음"
        case .delivered: "시스템 알림 전달 완료"
        case .fallback: "노치 활동 토스트에 대체 표시"
        case .testDelivered: "테스트 알림 전달 완료"
        case .testFailed: "테스트 알림 전달 실패"
        case .failed: "시스템 알림 전달 불가"
        }
    }

    /// 목적: 앱 번들과 권한 상태에 따른 알림 동작 버튼 활성 여부
    private var notificationControlsUnavailable: Bool {
        switch notificationDelivery.status.authorization {
        case .checking, .unavailable:
            true
        case .notRequested, .denied, .authorized, .provisional, .ephemeral, .unknown, .error:
            false
        }
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

    /// 적용 전까지 초안만 갱신하는 계정 경로 바인딩
    private func pathBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { accountPathsDraft.paths[index] },
            set: { accountPathsDraft.replace(at: index, text: $0) }
        )
    }

    /// 숨김 폴더를 포함한 사용자 선택 경로를 편집 초안에만 반영
    private func chooseAccountDirectory(at index: Int) {
        guard let selected = AccountFolderPicker.choose(currentPath: accountPathsDraft.paths[index]) else { return }
        accountPathsDraft.replace(at: index, text: selected)
    }

    /// 전체 검증 성공 시에만 실제 계정 경로 일괄 저장
    private func commitAccountPathsDraft() {
        guard let paths = accountPathsDraft.commit(validator: accountPathValidator),
              paths != Self.paddedAccountPaths(accountPaths) else { return }
        accountPaths = paths
    }

    /// 외부 경로 변경 또는 편집 취소 시 저장된 경로로 초안 복원
    private func synchronizeAccountPathDrafts() {
        accountPathsDraft = AccountPathsDraft(paths: accountPaths)
    }

    /// 목적: 네 경로 편집을 위한 입력 배열 길이 보정
    private static func paddedAccountPaths(_ paths: [String]) -> [String] {
        let prefix = Array(paths.prefix(accountPathCount))
        return prefix + Array(repeating: "", count: max(0, accountPathCount - prefix.count))
    }
}
