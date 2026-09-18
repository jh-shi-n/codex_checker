import Foundation

public enum CodexQuotaServiceError: Error, Equatable, Sendable {
    case notConfigured
    case loginRequired
    case codexNotFound
    case timeout
    case processCrashed(Int32?)
    case malformedResponse(String)
    case protocolError(String)
    case transport(String)
}

extension CodexQuotaServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Account not configured"
        case .loginRequired:
            return "Login required"
        case .codexNotFound:
            return "Codex executable not found"
        case .timeout:
            return "Codex app-server timed out"
        case let .processCrashed(status):
            if let status { return "Codex app-server exited with status \(status)" }
            return "Codex app-server exited unexpectedly"
        case let .malformedResponse(message):
            return "Malformed Codex response: \(message)"
        case let .protocolError(message):
            return "Codex protocol error: \(message)"
        case let .transport(message):
            return "Codex transport error: \(message)"
        }
    }
}

/// A quota snapshot containing the rolling five-hour primary quota and the
/// overall secondary quota when the server supplies it.
public struct CodexQuota: Equatable, Sendable {
    public let email: String?
    public let planType: String?
    public let primaryResetAt: Date?
    public let secondaryResetAt: Date?
    let primaryWindowIsOverall: Bool
    private let normalizedPrimaryUsedPercent: Double
    private let normalizedSecondaryUsedPercent: Double?

    public var primaryUsedPercent: Double { normalizedPrimaryUsedPercent }
    public var primaryRemainingPercent: Double { AccountState.clampPercent(100 - normalizedPrimaryUsedPercent) }
    public var secondaryUsedPercent: Double? { normalizedSecondaryUsedPercent }
    public var secondaryRemainingPercent: Double? {
        normalizedSecondaryUsedPercent.map { AccountState.clampPercent(100 - $0) }
    }

    public var usedPercent: Double { primaryUsedPercent }
    public var remainingPercent: Double { primaryRemainingPercent }
    public var resetAt: Date? { primaryResetAt }

    public init(
        email: String? = nil,
        planType: String? = nil,
        primaryUsedPercent: Double,
        secondaryUsedPercent: Double? = nil,
        primaryResetAt: Date? = nil,
        secondaryResetAt: Date? = nil
    ) {
        self.init(
            email: email,
            planType: planType,
            primaryUsedPercent: primaryUsedPercent,
            primaryWindowIsOverall: false,
            secondaryUsedPercent: secondaryUsedPercent,
            primaryResetAt: primaryResetAt,
            secondaryResetAt: secondaryResetAt
        )
    }

    init(
        email: String? = nil,
        planType: String? = nil,
        primaryUsedPercent: Double,
        primaryWindowIsOverall: Bool,
        secondaryUsedPercent: Double? = nil,
        primaryResetAt: Date? = nil,
        secondaryResetAt: Date? = nil
    ) {
        self.email = email
        self.planType = planType
        self.primaryResetAt = primaryResetAt
        self.secondaryResetAt = secondaryResetAt
        self.primaryWindowIsOverall = primaryWindowIsOverall
        self.normalizedPrimaryUsedPercent = AccountState.clampPercent(primaryUsedPercent)
        self.normalizedSecondaryUsedPercent = secondaryUsedPercent.map(AccountState.clampPercent)
    }

    public init(
        email: String? = nil,
        planType: String? = nil,
        usedPercent: Double,
        resetAt: Date? = nil
    ) {
        self.init(
            email: email,
            planType: planType,
            primaryUsedPercent: usedPercent,
            secondaryUsedPercent: usedPercent,
            primaryResetAt: resetAt,
            secondaryResetAt: resetAt
        )
    }
}

public typealias CodexProcessFactory = @Sendable () -> any CodexProcessTransport

/// Queries one account through the Codex app-server JSON-line protocol.
public struct CodexQuotaService: Sendable {
    public static let overallTimeout: TimeInterval = 12

    private let locator: any CodexLocating
    private let processFactory: CodexProcessFactory

    public init(
        locator: any CodexLocating = CodexLocator(),
        processFactory: @escaping CodexProcessFactory = { CodexProcess() }
    ) {
        self.locator = locator
        self.processFactory = processFactory
    }

    /// Async entry point that permits independent accounts to run concurrently.
    public func fetch(for config: AccountConfig) async -> Result<CodexQuota, CodexQuotaServiceError> {
        await Task.detached(priority: nil) {
            fetchSync(for: config)
        }.value
    }

    /// Synchronous core used by the async wrapper and deterministic transport tests.
    public func fetchSync(for config: AccountConfig) -> Result<CodexQuota, CodexQuotaServiceError> {
        guard config.isConfigured else {
            return .failure(.notConfigured)
        }
        guard FileManager.default.fileExists(atPath: config.authFile.path) else {
            return .failure(.loginRequired)
        }
        guard let executable = locator.locate() else {
            return .failure(.codexNotFound)
        }

        let deadline = Date().addingTimeInterval(Self.overallTimeout)
        let process = processFactory()
        defer { process.terminate(until: deadline) }

        do {
            try process.launch(executable: executable, home: config.home)

            // The initialize request is deliberately sent alone. Some app-server
            // versions do not process later requests until its response is read.
            try process.send(CodexProtocol.initializeRequest)
            let initializeResponses = try process.readResponses(for: [0], until: deadline)
            guard let initializeResponse = initializeResponses[0] else {
                throw CodexQuotaServiceError.timeout
            }
            try validateResponse(initializeResponse, requestName: "initialize")

            for request in CodexProtocol.postInitializeRequests {
                try process.send(request)
            }

            let responses = try process.readResponses(for: [1, 2], until: deadline)
            guard let accountResponse = responses[1] else {
                throw CodexQuotaServiceError.timeout
            }
            guard let rateLimitsResponse = responses[2] else {
                throw CodexQuotaServiceError.timeout
            }
            try validateResponse(accountResponse, requestName: "account/read")
            try validateResponse(rateLimitsResponse, requestName: "account/rateLimits/read")

            return .success(try parseQuota(accountResponse: accountResponse, rateLimitsResponse: rateLimitsResponse))
        } catch let error as CodexQuotaServiceError {
            return .failure(error)
        } catch let error as CodexProcessError {
            return .failure(map(error))
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

    /// Convenience state API for AccountStore/UI workers.
    public func state(for config: AccountConfig) async -> AccountState {
        await Task.detached(priority: nil) {
            stateSync(for: config)
        }.value
    }

    public func stateSync(for config: AccountConfig) -> AccountState {
        switch fetchSync(for: config) {
        case let .success(quota):
            let primaryIsOverall = quota.primaryWindowIsOverall
            return AccountState(
                id: config.id,
                email: quota.email,
                planType: quota.planType,
                primaryUsedPercent: primaryIsOverall ? nil : quota.primaryUsedPercent,
                secondaryUsedPercent: primaryIsOverall
                    ? quota.secondaryUsedPercent ?? quota.primaryUsedPercent
                    : quota.secondaryUsedPercent,
                primaryResetAt: primaryIsOverall ? nil : quota.primaryResetAt,
                secondaryResetAt: primaryIsOverall
                    ? quota.secondaryResetAt ?? quota.primaryResetAt
                    : quota.secondaryResetAt,
                lastUpdated: Date(),
                status: .normal
            )
        case let .failure(error):
            if error == .notConfigured {
                return AccountState.notConfigured(id: config.id)
            }
            let status: AccountStatus
            switch error {
            case .notConfigured:
                // Handled above so the presentation state does not carry an
                // error message for a deliberate empty settings slot.
                status = .notConfigured
            case .loginRequired:
                status = .loginRequired
            case .codexNotFound:
                status = .codexNotFound
            case .timeout:
                status = .timeout
            case .processCrashed, .malformedResponse, .protocolError, .transport:
                status = .error
            }
            return AccountState(
                id: config.id,
                status: status,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func validateResponse(_ message: CodexMessage, requestName: String) throws {
        if message.containsError {
            guard let error = message.error else {
                throw CodexQuotaServiceError.malformedResponse("Invalid error object for \(requestName)")
            }
            throw CodexQuotaServiceError.protocolError(
                error.message ?? "Request \(requestName) failed"
            )
        }
        guard message.hasResult else {
            throw CodexQuotaServiceError.malformedResponse("Missing result for \(requestName)")
        }
    }

    private func parseQuota(
        accountResponse: CodexMessage,
        rateLimitsResponse: CodexMessage
    ) throws -> CodexQuota {
        var email: String?
        var planType: String?

        if let accountValue = accountResponse.result?.objectValue?["account"], accountValue != .null {
            guard let account = accountValue.objectValue else {
                throw CodexQuotaServiceError.malformedResponse("account is not an object")
            }
            email = account["email"]?.stringValue
            planType = account["planType"]?.stringValue
        }

        guard let result = rateLimitsResponse.result?.objectValue else {
            throw CodexQuotaServiceError.malformedResponse("Missing rate limit result")
        }
        let limits = result["rateLimits"]?.objectValue ?? [:]
        let limitsByID = result["rateLimitsByLimitId"]?.objectValue
        let candidates = [
            classifyLimit(
                key: "primary",
                values: limit(key: "primary", historicalLimits: limits, limitsByID: limitsByID)
            ),
            classifyLimit(
                key: "secondary",
                values: limit(key: "secondary", historicalLimits: limits, limitsByID: limitsByID)
            ),
        ].compactMap { $0 }
        let primary = selectLimit(candidates, window: .fiveHour)
        let secondary = selectLimit(candidates, window: .overall)
        guard let selected = primary ?? secondary,
              let selectedUsedPercent = finiteUsedPercent(in: selected.values) else {
            throw CodexQuotaServiceError.malformedResponse("Missing rateLimits.primary.usedPercent")
        }

        return CodexQuota(
            email: email,
            planType: planType,
            primaryUsedPercent: selectedUsedPercent,
            primaryWindowIsOverall: primary == nil && secondary != nil,
            secondaryUsedPercent: secondary.flatMap { finiteUsedPercent(in: $0.values) },
            primaryResetAt: primary.flatMap { resetDate(in: $0.values) },
            secondaryResetAt: secondary.flatMap { resetDate(in: $0.values) }
        )
    }

    private enum QuotaWindow: Equatable {
        case fiveHour
        case overall
    }

    private struct ClassifiedLimit {
        let window: QuotaWindow
        let values: [String: CodexJSONValue]
        let usesExplicitDuration: Bool
    }

    private func classifyLimit(
        key: String,
        values: [String: CodexJSONValue]?
    ) -> ClassifiedLimit? {
        guard let values else { return nil }
        if let duration = values["windowDurationMins"]?.numberValue {
            guard duration.isFinite else { return nil }
            if duration == 300 {
                return ClassifiedLimit(window: .fiveHour, values: values, usesExplicitDuration: true)
            }
            if duration == 10080 {
                return ClassifiedLimit(window: .overall, values: values, usesExplicitDuration: true)
            }
            return nil
        }

        let window: QuotaWindow = key == "primary" ? .fiveHour : .overall
        return ClassifiedLimit(window: window, values: values, usesExplicitDuration: false)
    }

    private func selectLimit(
        _ candidates: [ClassifiedLimit],
        window: QuotaWindow
    ) -> ClassifiedLimit? {
        candidates.first { $0.window == window && $0.usesExplicitDuration }
            ?? candidates.first { $0.window == window }
    }

    private func finiteUsedPercent(in values: [String: CodexJSONValue]) -> Double? {
        values["usedPercent"]?.numberValue.flatMap { $0.isFinite ? $0 : nil }
    }

    private func resetDate(in values: [String: CodexJSONValue]) -> Date? {
        values["resetsAt"]?.numberValue.map(Date.init(timeIntervalSince1970:))
    }

    /// Prefer historical fields, then the metered Codex bucket used by newer
    /// app-server versions. No other product bucket is eligible.
    private func limit(
        key: String,
        historicalLimits: [String: CodexJSONValue],
        limitsByID: [String: CodexJSONValue]?
    ) -> [String: CodexJSONValue]? {
        if let historical = historicalLimits[key], historical != .null {
            return historical.objectValue
        }

        return limitsByID?["codex"]?.objectValue?[key]?.objectValue
    }

    private func map(_ error: CodexProcessError) -> CodexQuotaServiceError {
        switch error {
        case .timeout:
            return .timeout
        case let .processExited(status):
            return .processCrashed(status)
        case let .launchFailed(message):
            return .transport(message)
        case .notRunning:
            return .processCrashed(nil)
        case let .writeFailed(message), let .readFailed(message):
            return .transport(message)
        }
    }
}
