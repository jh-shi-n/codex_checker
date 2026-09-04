import Darwin
import Dispatch
import Foundation

/// A parser summary that contains only structured, non-sensitive facts about
/// the bounded JSONL stream.
public struct UsageWindowProbeParseResult: Equatable, Sendable {
    public let usage: UsageWindowProbeTokenUsage?
    public let sawNonWhitespaceOutput: Bool
    public let sawValidObject: Bool
    public let sawMalformedLine: Bool
    public let sawCompletion: Bool
    public let sawError: Bool
    /// A bounded categorical diagnosis extracted only from an error event.
    /// No source text is retained or exposed.
    public let failureCategoryHint: UsageWindowProbeFailureCategory?

    public init(
        usage: UsageWindowProbeTokenUsage? = nil,
        sawNonWhitespaceOutput: Bool = false,
        sawValidObject: Bool = false,
        sawMalformedLine: Bool = false,
        sawCompletion: Bool = false,
        sawError: Bool = false,
        failureCategoryHint: UsageWindowProbeFailureCategory? = nil
    ) {
        self.usage = usage
        self.sawNonWhitespaceOutput = sawNonWhitespaceOutput
        self.sawValidObject = sawValidObject
        self.sawMalformedLine = sawMalformedLine
        self.sawCompletion = sawCompletion
        self.sawError = sawError
        self.failureCategoryHint = failureCategoryHint
    }

    public var isMalformedOnlyOutput: Bool {
        sawNonWhitespaceOutput && sawMalformedLine && !sawValidObject
    }
}

/// Incremental, conservative JSONL parser for `codex exec --json` output.
/// It keeps no source text after each line is inspected.
public struct UsageWindowProbeJSONLParser: Sendable {
    public static let maximumLineBytes = 64 * 1_024
    public static let maximumBufferedBytes = 256 * 1_024

    private var buffer = Data()
    private var usage = UsageWindowProbeTokenUsage()
    private var sawNonWhitespaceOutput = false
    private var sawValidObject = false
    private var sawMalformedLine = false
    private var sawCompletion = false
    private var sawError = false
    private var failureCategoryHint: UsageWindowProbeFailureCategory?

    public init() {}

    /// Appends arbitrary stdout chunks. Oversized fragments are treated as a
    /// malformed result and are not retained indefinitely.
    public mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }

        var start = data.startIndex
        while start < data.endIndex {
            guard let newline = data[start..<data.endIndex].firstIndex(of: 0x0A) else {
                appendFragment(data[start..<data.endIndex])
                return
            }

            appendFragment(data[start..<newline])
            consumeBufferedLine()
            start = data.index(after: newline)
        }
    }

    /// Parses a final line without a newline delimiter and returns the safe
    /// structured summary.
    public mutating func finish() -> UsageWindowProbeParseResult {
        if !buffer.isEmpty {
            consumeBufferedLine()
        }
        return parseResult
    }

    public var parseResult: UsageWindowProbeParseResult {
        UsageWindowProbeParseResult(
            usage: usage.hasReportedUsage ? usage : nil,
            sawNonWhitespaceOutput: sawNonWhitespaceOutput,
            sawValidObject: sawValidObject,
            sawMalformedLine: sawMalformedLine,
            sawCompletion: sawCompletion,
            sawError: sawError,
            failureCategoryHint: failureCategoryHint
        )
    }

    private mutating func appendFragment<S: Collection>(_ fragment: S) where S.Element == UInt8 {
        guard !fragment.isEmpty else { return }
        if buffer.count > Self.maximumBufferedBytes - fragment.count {
            buffer.removeAll(keepingCapacity: false)
            sawMalformedLine = true
            sawNonWhitespaceOutput = true
            return
        }
        buffer.append(contentsOf: fragment)
        if !fragment.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
            sawNonWhitespaceOutput = true
        }
        if buffer.count > Self.maximumLineBytes {
            buffer.removeAll(keepingCapacity: false)
            sawMalformedLine = true
        }
    }

    private mutating func consumeBufferedLine() {
        defer { buffer.removeAll(keepingCapacity: false) }
        guard !buffer.isEmpty else { return }
        let line = Data(buffer)
        let trimmed = line.drop(while: { byte in
            byte == 0x20 || byte == 0x09 || byte == 0x0D
        })
        guard !trimmed.isEmpty else { return }

        guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed), options: []),
              let dictionary = object as? [String: Any]
        else {
            sawMalformedLine = true
            return
        }

        sawValidObject = true
        if containsError(in: dictionary) {
            sawError = true
            if let hint = diagnosticHint(in: dictionary) {
                failureCategoryHint = preferredHint(failureCategoryHint, hint)
            }
        }
        if containsCompletion(in: dictionary) {
            sawCompletion = true
        }
        collectUsage(from: dictionary)
    }

    private func containsError(in dictionary: [String: Any]) -> Bool {
        containsError(in: dictionary as Any, depth: 0)
    }

    private func containsError(in value: Any, depth: Int) -> Bool {
        guard depth <= 5 else { return false }
        guard let dictionary = value as? [String: Any] else {
            if let array = value as? [Any] {
                return array.contains { containsError(in: $0, depth: depth + 1) }
            }
            return false
        }
        for (key, value) in dictionary {
            let normalizedKey = canonicalKey(key)
            if ["error", "errors", "failure", "failed"].contains(normalizedKey) {
                return true
            }
            if ["type", "event", "method", "status", "state"].contains(normalizedKey),
               let text = value as? String,
               containsErrorWord(text) {
                return true
            }
            if ["item", "event", "response", "result", "data", "details"].contains(normalizedKey),
               containsError(in: value, depth: depth + 1) {
                return true
            }
        }
        return false
    }

    private func containsCompletion(in dictionary: [String: Any]) -> Bool {
        for (key, value) in dictionary {
            let normalizedKey = canonicalKey(key)
            if ["completed", "complete", "done", "finished", "success", "succeeded"].contains(normalizedKey),
               isTruthyOrCompletion(value) {
                return true
            }
            if ["type", "event", "method", "status", "state"].contains(normalizedKey),
               let text = value as? String,
               containsCompletionWord(text) {
                return true
            }
        }
        return false
    }

    private func containsErrorWord(_ value: String) -> Bool {
        let text = value.lowercased()
        return text.contains("error") || text.contains("failed") || text.contains("failure")
    }

    private func containsCompletionWord(_ value: String) -> Bool {
        let text = value.lowercased()
        return text.contains("completed") || text.contains("complete") ||
            text.contains("finished") || text.contains("succeeded") ||
            text == "done" || text == "success"
    }

    private func diagnosticHint(in dictionary: [String: Any]) -> UsageWindowProbeFailureCategory? {
        var fragments: [String] = []
        collectDiagnosticText(from: dictionary, depth: 0, into: &fragments)
        return UsageWindowProbeDiagnostic.hint(from: fragments.joined(separator: " "))
    }

    private func collectDiagnosticText(
        from value: Any,
        depth: Int,
        into fragments: inout [String]
    ) {
        guard depth <= 4, fragments.count < 32 else { return }
        if let dictionary = value as? [String: Any] {
            for (key, nested) in dictionary {
                let normalizedKey = canonicalKey(key)
                if ["error", "errors", "failure", "failed", "message", "reason", "detail", "code", "type", "status"].contains(normalizedKey) {
                    if let text = nested as? String {
                        fragments.append(text)
                    } else if let number = nested as? NSNumber {
                        fragments.append(number.stringValue)
                    }
                    collectDiagnosticText(from: nested, depth: depth + 1, into: &fragments)
                } else if ["response", "result", "data", "error"].contains(normalizedKey) {
                    collectDiagnosticText(from: nested, depth: depth + 1, into: &fragments)
                }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                collectDiagnosticText(from: nested, depth: depth + 1, into: &fragments)
            }
        }
    }

    private func preferredHint(
        _ current: UsageWindowProbeFailureCategory?,
        _ candidate: UsageWindowProbeFailureCategory
    ) -> UsageWindowProbeFailureCategory {
        guard let current else { return candidate }
        let rank: [UsageWindowProbeFailureCategory: Int] = [
            .unsupportedModel: 3,
            .authenticationFailure: 2,
            .rateLimited: 1,
        ]
        return (rank[candidate] ?? 0) > (rank[current] ?? 0) ? candidate : current
    }

    private func isTruthyOrCompletion(_ value: Any) -> Bool {
        if let bool = value as? Bool { return bool }
        if let text = value as? String { return containsCompletionWord(text) }
        return false
    }

    private mutating func collectUsage(from root: [String: Any]) {
        var remainingNodes = 2_048
        collectUsage(from: root, depth: 0, remainingNodes: &remainingNodes)
    }

    private mutating func collectUsage(
        from value: Any,
        depth: Int,
        remainingNodes: inout Int
    ) {
        guard depth <= 8, remainingNodes > 0 else { return }
        remainingNodes -= 1

        if let dictionary = value as? [String: Any] {
            var input = usage.inputTokens
            var output = usage.outputTokens
            var total = usage.totalTokens
            for (key, rawValue) in dictionary {
                let normalizedKey = canonicalKey(key)
                if isInputTokenKey(normalizedKey), let count = tokenCount(rawValue) {
                    input = count
                } else if isOutputTokenKey(normalizedKey), let count = tokenCount(rawValue) {
                    output = count
                } else if isTotalTokenKey(normalizedKey), let count = tokenCount(rawValue) {
                    total = count
                }
            }
            usage = UsageWindowProbeTokenUsage(
                inputTokens: input,
                outputTokens: output,
                totalTokens: total
            )

            for (key, nested) in dictionary {
                let normalizedKey = canonicalKey(key)
                if isUsageContainerKey(normalizedKey) || nested is [String: Any] || nested is [Any] {
                    collectUsage(from: nested, depth: depth + 1, remainingNodes: &remainingNodes)
                }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                collectUsage(from: nested, depth: depth + 1, remainingNodes: &remainingNodes)
            }
        }
    }

    private func canonicalKey(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func isInputTokenKey(_ key: String) -> Bool {
        ["inputtokens", "prompttokens", "inputtokencount", "prompttokencount", "tokensin"].contains(key)
    }

    private func isOutputTokenKey(_ key: String) -> Bool {
        ["outputtokens", "completiontokens", "outputtokencount", "completiontokencount", "tokensout"].contains(key)
    }

    private func isTotalTokenKey(_ key: String) -> Bool {
        ["totaltokens", "totaltokencount", "tokenstotal"].contains(key)
    }

    private func isUsageContainerKey(_ key: String) -> Bool {
        ["usage", "tokenusage", "tokencounts", "tokens", "response", "result", "data", "turn"].contains(key)
    }

    private func tokenCount(_ value: Any) -> Int? {
        if let number = value as? NSNumber {
            let double = number.doubleValue
            guard double.isFinite, double >= 0, double.rounded() == double,
                  double <= Double(Int.max)
            else { return nil }
            return Int(double)
        }
        if let text = value as? String,
           let parsed = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           parsed >= 0 {
            return parsed
        }
        return nil
    }
}

/// Converts bounded diagnostic text to a small categorical hint. Matching is
/// intentionally conservative and never returns the original text.
private enum UsageWindowProbeDiagnostic {
    static func hint(from data: Data) -> UsageWindowProbeFailureCategory? {
        guard !data.isEmpty else { return nil }
        return hint(from: String(decoding: data, as: UTF8.self))
    }

    static func hint(from text: String) -> UsageWindowProbeFailureCategory? {
        let normalized = text.lowercased()
        let compact = normalized.filter { $0.isLetter || $0.isNumber }

        if normalized.contains("too many requests") ||
            normalized.contains("rate limit") ||
            compact.contains("ratelimit") ||
            normalized.contains("throttl") ||
            normalized.contains("429") {
            return .rateLimited
        }

        let modelMentioned = normalized.contains("model") || compact.contains("unsupportedmodel")
        if modelMentioned && (
            normalized.contains("unsupported") ||
            normalized.contains("not found") ||
            normalized.contains("unknown model") ||
            normalized.contains("invalid model") ||
            normalized.contains("not available") ||
            compact.contains("modeldoesnotexist")
        ) {
            return .unsupportedModel
        }

        if normalized.contains("unauthorized") ||
            normalized.contains("authentication") ||
            normalized.contains("not logged in") ||
            normalized.contains("login required") ||
            normalized.contains("invalid api key") ||
            normalized.contains("api key") && normalized.contains("invalid") ||
            normalized.contains("token expired") {
            return .authenticationFailure
        }
        return nil
    }
}

/// Per-request filesystem roots that expose only the selected account's
/// authentication file to Codex. The source account home is never read or
/// enumerated; its `auth.json` is referenced through a symbolic link.
internal struct UsageWindowProbeExecutionIsolation: Sendable {
    internal let rootURL: URL
    internal let codexHomeURL: URL
    internal let workingDirectoryURL: URL

    internal var isolatedCodexHomeURL: URL { codexHomeURL }
    internal var isolatedWorkingDirectoryURL: URL { workingDirectoryURL }

    private init(rootURL: URL, codexHomeURL: URL, workingDirectoryURL: URL) {
        self.rootURL = rootURL
        self.codexHomeURL = codexHomeURL
        self.workingDirectoryURL = workingDirectoryURL
    }

    internal static func create(
        configuredAccountHome: URL,
        fileManager: FileManager = .default
    ) throws -> UsageWindowProbeExecutionIsolation {
        let rootURL = fileManager.temporaryDirectory
            .standardizedFileURL
            .appendingPathComponent("codex-quota-probe-\(UUID().uuidString)", isDirectory: true)
        let codexHomeURL = rootURL.appendingPathComponent("codex-home", isDirectory: true)
        let workingDirectoryURL = rootURL.appendingPathComponent("working-directory", isDirectory: true)
        let privateDirectoryAttributes: [FileAttributeKey: Any] = [
            .posixPermissions: NSNumber(value: Int16(0o700)),
        ]

        do {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: false,
                attributes: privateDirectoryAttributes
            )
            try fileManager.createDirectory(
                at: codexHomeURL,
                withIntermediateDirectories: false,
                attributes: privateDirectoryAttributes
            )
            try fileManager.createDirectory(
                at: workingDirectoryURL,
                withIntermediateDirectories: false,
                attributes: privateDirectoryAttributes
            )

            let sourceAuthURL = configuredAccountHome.appendingPathComponent("auth.json")
            let isolatedAuthURL = codexHomeURL.appendingPathComponent("auth.json")
            try fileManager.createSymbolicLink(
                at: isolatedAuthURL,
                withDestinationURL: sourceAuthURL
            )
        } catch {
            try? fileManager.removeItem(at: rootURL)
            throw error
        }

        return UsageWindowProbeExecutionIsolation(
            rootURL: rootURL,
            codexHomeURL: codexHomeURL,
            workingDirectoryURL: workingDirectoryURL
        )
    }

    internal func cleanup(fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        do {
            try fileManager.removeItem(at: rootURL)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            // A concurrent cleanup may have removed the root already.
        }
    }
}

/// Live asynchronous Process-backed runner. It runs on a utility queue,
/// captures each stream under a strict byte cap, and terminates a child within
/// bounded graceful and forced windows after timeout.
public final class UsageWindowProbeLiveProcessRunner: UsageWindowProbeProcessRunning, @unchecked Sendable {
    public static let defaultGracefulTerminationTimeout: TimeInterval = 0.25
    public static let defaultForcedTerminationTimeout: TimeInterval = 0.25

    private let inheritedEnvironment: [String: String]
    private let gracefulTerminationTimeout: TimeInterval
    private let forcedTerminationTimeout: TimeInterval

    public init(
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        gracefulTerminationTimeout: TimeInterval = UsageWindowProbeLiveProcessRunner.defaultGracefulTerminationTimeout,
        forcedTerminationTimeout: TimeInterval = UsageWindowProbeLiveProcessRunner.defaultForcedTerminationTimeout
    ) {
        self.inheritedEnvironment = inheritedEnvironment
        self.gracefulTerminationTimeout = max(0, gracefulTerminationTimeout)
        self.forcedTerminationTimeout = max(0, forcedTerminationTimeout)
    }

    public func run(
        command: UsageWindowProbeCommand,
        timeout: TimeInterval
    ) async throws -> UsageWindowProbeProcessResult {
        let cancellation = ProcessCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<UsageWindowProbeProcessResult, Error>) in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        continuation.resume(returning: try self.runSynchronously(
                            command: command,
                            timeout: timeout,
                            cancellation: cancellation
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: {
            cancellation.cancel()
        })
    }

    private func runSynchronously(
        command: UsageWindowProbeCommand,
        timeout: TimeInterval,
        cancellation: ProcessCancellation
    ) throws -> UsageWindowProbeProcessResult {
        let isolation: UsageWindowProbeExecutionIsolation
        do {
            isolation = try UsageWindowProbeExecutionIsolation.create(
                configuredAccountHome: command.configuredAccountHome,
                fileManager: .default
            )
        } catch {
            throw UsageWindowProbeProcessError.launchFailure
        }
        defer {
            try? isolation.cleanup(fileManager: .default)
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let outputCollector = BoundedDataCollector(limit: UsageWindowProbeProcessResult.maximumStandardOutputBytes)
        let errorCollector = BoundedDataCollector(limit: UsageWindowProbeProcessResult.maximumStandardErrorBytes)
        let termination = DispatchSemaphore(value: 0)

        process.executableURL = command.executableURL
        process.arguments = command.arguments
        var environment = inheritedEnvironment
        for (key, value) in command.environmentOverrides {
            environment[key] = value
        }
        environment["CODEX_HOME"] = isolation.codexHomeURL.path
        environment["PWD"] = isolation.workingDirectoryURL.path
        process.environment = environment
        process.currentDirectoryURL = isolation.workingDirectoryURL
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { _ in termination.signal() }

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                outputCollector.append(data)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                errorCollector.append(data)
            }
        }

        guard !cancellation.isCancelled else {
            close(pipe: inputPipe)
            close(pipe: outputPipe)
            close(pipe: errorPipe)
            throw UsageWindowProbeProcessError.cancelled
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            close(pipe: inputPipe)
            close(pipe: outputPipe)
            close(pipe: errorPipe)
            throw UsageWindowProbeProcessError.launchFailure
        }
        cancellation.install(process)
        if cancellation.isCancelled {
            process.terminate()
        }
        // The parent must release its copies of the pipe write ends. Keeping
        // them open would make the post-exit drain wait forever for EOF.
        closeParentWritingHandles(inputPipe: inputPipe, outputPipe: outputPipe, errorPipe: errorPipe)

        let boundedTimeout = max(0.001, timeout)
        var didTimeout = false
        if termination.wait(timeout: .now() + boundedTimeout) == .timedOut {
            didTimeout = true
            terminate(process, termination: termination)
        }

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        drain(outputPipe.fileHandleForReading, into: outputCollector)
        drain(errorPipe.fileHandleForReading, into: errorCollector)

        let status: Int32? = process.isRunning ? nil : process.terminationStatus
        process.terminationHandler = nil
        close(pipe: inputPipe)
        close(pipe: outputPipe)
        close(pipe: errorPipe)

        if didTimeout {
            throw UsageWindowProbeProcessError.timeout
        }
        if cancellation.isCancelled {
            throw UsageWindowProbeProcessError.cancelled
        }
        guard status != nil else {
            throw UsageWindowProbeProcessError.processFailure
        }
        return UsageWindowProbeProcessResult(
            exitStatus: status,
            stdout: outputCollector.value,
            stderr: errorCollector.value
        )
    }

    private func terminate(_ process: Process, termination: DispatchSemaphore) {
        guard process.isRunning else { return }
        process.terminate()
        if termination.wait(timeout: .now() + gracefulTerminationTimeout) == .timedOut,
           process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            _ = termination.wait(timeout: .now() + forcedTerminationTimeout)
        }
    }

    private func drain(_ handle: FileHandle, into collector: BoundedDataCollector) {
        while true {
            let chunk = handle.readData(ofLength: 8 * 1_024)
            guard !chunk.isEmpty else { return }
            collector.append(chunk)
        }
    }

    private func close(pipe: Pipe) {
        try? pipe.fileHandleForWriting.close()
        try? pipe.fileHandleForReading.close()
    }

    private func closeParentWritingHandles(inputPipe: Pipe, outputPipe: Pipe, errorPipe: Pipe) {
        try? inputPipe.fileHandleForWriting.close()
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
    }
}

public typealias LiveUsageWindowProbeProcessRunner = UsageWindowProbeLiveProcessRunner

private final class ProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func install(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldTerminate = cancelled
        lock.unlock()
        if shouldTerminate, process.isRunning {
            process.terminate()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        if let process, process.isRunning {
            process.terminate()
        }
    }
}

private final class BoundedDataCollector: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var data = Data()

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let remaining = limit - data.count
        guard remaining > 0 else { return }
        data.append(chunk.prefix(remaining))
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// Actor-isolated service for one bounded, injectable usage-window request.
/// Calls for the same account are rejected while one is active; different
/// accounts can run independently because each call owns its runner request.
public actor UsageWindowProbeService {
    public static let defaultTimeout: TimeInterval = 60
    public static let overallTimeout: TimeInterval = defaultTimeout

    private let fileSystem: UsageWindowProbeFileSystem
    private let executableLocator: any CodexLocating
    private let processRunner: any UsageWindowProbeProcessRunning
    private let commandBuilder: UsageWindowProbeCommandBuilder
    private let timeout: TimeInterval
    private let clock: @Sendable () -> Date
    private var activeAccountIDs = Set<String>()
    private var states: [String: UsageWindowProbeState] = [:]

    public init(
        fileSystem: UsageWindowProbeFileSystem = .live,
        executableLocator: any CodexLocating = CodexLocator(),
        processRunner: any UsageWindowProbeProcessRunning = UsageWindowProbeLiveProcessRunner(),
        commandBuilder: UsageWindowProbeCommandBuilder = UsageWindowProbeCommandBuilder(),
        timeout: TimeInterval = UsageWindowProbeService.defaultTimeout,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileSystem = fileSystem
        self.executableLocator = executableLocator
        self.processRunner = processRunner
        self.commandBuilder = commandBuilder
        self.timeout = max(0.001, timeout)
        self.clock = clock
    }

    /// Runs the probe for one configured account. This service only returns
    /// the probe result; refreshing AccountStore and interpreting reset times
    /// remain responsibilities of the caller.
    public func probe(_ config: AccountConfig) async -> UsageWindowProbeResult {
        let startedAt = clock()
        let commandMetadata = commandBuilder.metadata
        if activeAccountIDs.contains(config.id) {
            let completedAt = clock()
            return UsageWindowProbeResult(
                accountID: config.id,
                status: .failure,
                startedAt: startedAt,
                completedAt: completedAt,
                failureCategory: .alreadyRunning,
                commandMetadata: commandMetadata
            )
        }

        activeAccountIDs.insert(config.id)
        states[config.id] = UsageWindowProbeState(
            accountID: config.id,
            status: .running,
            startedAt: startedAt,
            commandMetadata: commandMetadata
        )

        let result = await execute(config: config, startedAt: startedAt)
        activeAccountIDs.remove(config.id)
        states[config.id] = UsageWindowProbeState(
            accountID: config.id,
            status: result.isSuccess ? .success : .failure,
            startedAt: result.startedAt,
            completedAt: result.completedAt,
            result: result,
            commandMetadata: result.commandMetadata
        )
        return result
    }

    public func probe(for config: AccountConfig) async -> UsageWindowProbeResult {
        await probe(config)
    }

    public func run(for config: AccountConfig) async -> UsageWindowProbeResult {
        await probe(config)
    }

    public func state(for accountID: String) -> UsageWindowProbeState {
        states[accountID] ?? .idle(accountID: accountID)
    }

    public func latestState(for accountID: String) -> UsageWindowProbeState {
        state(for: accountID)
    }

    private func execute(
        config: AccountConfig,
        startedAt: Date
    ) async -> UsageWindowProbeResult {
        let metadata = commandBuilder.metadata
        guard config.isConfigured, let configuredHome = config.configuredHome else {
            return failure(
                accountID: config.id,
                startedAt: startedAt,
                category: .notConfigured,
                metadata: metadata
            )
        }

        let authMetadata = fileSystem.metadata(config.authFile)
        guard authMetadata.isUsableAuthenticationFile else {
            return failure(
                accountID: config.id,
                startedAt: startedAt,
                category: .missingAuthentication,
                metadata: metadata
            )
        }

        guard let executable = executableLocator.locate() else {
            return failure(
                accountID: config.id,
                startedAt: startedAt,
                category: .executableUnavailable,
                metadata: metadata
            )
        }

        let command = commandBuilder.build(
            executable: executable,
            configuredAccountHome: configuredHome
        )

        do {
            let processResult = try await processRunner.run(command: command, timeout: timeout)
            var parser = UsageWindowProbeJSONLParser()
            parser.append(processResult.stdout)
            let parsed = parser.finish()
            let boundedStreamHint = parsed.failureCategoryHint ??
                UsageWindowProbeDiagnostic.hint(from: processResult.stderr)

            guard processResult.exitStatus == 0 else {
                return failure(
                    accountID: config.id,
                    startedAt: startedAt,
                    category: boundedStreamHint ?? .nonZeroExit,
                    metadata: command.metadata
                )
            }

            if parsed.sawError {
                return failure(
                    accountID: config.id,
                    startedAt: startedAt,
                    category: boundedStreamHint ?? .commandFailure,
                    metadata: command.metadata
                )
            }
            if parsed.isMalformedOnlyOutput {
                return failure(
                    accountID: config.id,
                    startedAt: startedAt,
                    category: .malformedOutput,
                    metadata: command.metadata
                )
            }

            return UsageWindowProbeResult(
                accountID: config.id,
                status: .success,
                startedAt: startedAt,
                completedAt: clock(),
                usage: parsed.usage,
                commandMetadata: command.metadata
            )
        } catch let error as UsageWindowProbeProcessError {
            let category: UsageWindowProbeFailureCategory
            switch error {
            case .timeout:
                category = .timeout
            case .launchFailure:
                category = .launchFailure
            case .processFailure:
                category = .processFailure
            case .cancelled:
                category = .processFailure
            }
            return failure(
                accountID: config.id,
                startedAt: startedAt,
                category: category,
                metadata: command.metadata
            )
        } catch {
            return failure(
                accountID: config.id,
                startedAt: startedAt,
                category: .processFailure,
                metadata: command.metadata
            )
        }
    }

    private func failure(
        accountID: String,
        startedAt: Date,
        category: UsageWindowProbeFailureCategory,
        metadata: UsageWindowProbeCommandMetadata
    ) -> UsageWindowProbeResult {
        UsageWindowProbeResult(
            accountID: accountID,
            status: .failure,
            startedAt: startedAt,
            completedAt: clock(),
            failureCategory: category,
            commandMetadata: metadata
        )
    }
}
