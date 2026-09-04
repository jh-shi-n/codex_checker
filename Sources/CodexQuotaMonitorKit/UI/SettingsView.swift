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

/// Settings content. It edits caller-owned bindings only; persistence and
/// launch-at-login registration are deliberately left to the host app.
public struct SettingsView: View {
    public static let refreshSectionTitle = "Refresh"
    public static let activitySectionTitle = "Activity"
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
    @State private var refreshIntervalDraft: RefreshIntervalDraft
    @State private var accountPathDrafts: [String]
    @State private var accountPathValidationErrors: [Int: AccountPathValidation]
    private let accountPathValidator: AccountPathValidator

    public init(
        refreshIntervalMinutes: Binding<Int>,
        accountPaths: Binding<[String]>,
        launchAtLogin: Binding<Bool>,
        showAccountLabels: Binding<Bool> = .constant(false),
        activityNotificationDurationSeconds: Binding<Int> = .constant(
            PreferencesStore.defaultActivityNotificationDurationSeconds
        ),
        accountPathValidator: AccountPathValidator = .live
    ) {
        self._refreshIntervalMinutes = refreshIntervalMinutes
        self._accountPaths = accountPaths
        self._launchAtLogin = launchAtLogin
        self._showAccountLabels = showAccountLabels
        self._activityNotificationDurationSeconds = activityNotificationDurationSeconds
        self._refreshIntervalDraft = State(initialValue: RefreshIntervalDraft(value: refreshIntervalMinutes.wrappedValue))
        self._accountPathDrafts = State(initialValue: Self.paddedAccountPaths(accountPaths.wrappedValue))
        self._accountPathValidationErrors = State(initialValue: [:])
        self.accountPathValidator = accountPathValidator
    }

    /// Convenience initializer for hosts that keep four paths as individual
    /// settings instead of one collection.
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
        accountPathValidator: AccountPathValidator = .live
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
        self._refreshIntervalDraft = State(initialValue: RefreshIntervalDraft(value: refreshIntervalMinutes.wrappedValue))
        self._accountPathDrafts = State(initialValue: Self.paddedAccountPaths([
            account1Path.wrappedValue,
            account2Path.wrappedValue,
            account3Path.wrappedValue,
            account4Path.wrappedValue,
        ]))
        self._accountPathValidationErrors = State(initialValue: [:])
        self.accountPathValidator = accountPathValidator
    }

    public var body: some View {
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
        .padding()
        .frame(minWidth: 360)
        .onAppear(perform: synchronizeAccountPathDrafts)
        .onChange(of: accountPaths) { _, _ in
            synchronizeAccountPathDrafts()
        }
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

    private func commitRefreshIntervalDraft() {
        guard let value = refreshIntervalDraft.commit() else {
            refreshIntervalDraft = RefreshIntervalDraft(value: refreshIntervalMinutes)
            return
        }
        refreshIntervalMinutes = value
    }

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

    private func synchronizeAccountPathDrafts() {
        let paths = Self.paddedAccountPaths(accountPaths)
        guard paths != accountPathDrafts else { return }
        accountPathDrafts = paths
        accountPathValidationErrors = [:]
    }

    private static func paddedAccountPaths(_ paths: [String]) -> [String] {
        let prefix = Array(paths.prefix(accountPathCount))
        return prefix + Array(repeating: "", count: max(0, accountPathCount - prefix.count))
    }
}
