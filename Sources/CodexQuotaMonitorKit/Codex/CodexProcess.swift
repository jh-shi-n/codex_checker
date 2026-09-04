import Darwin
import Dispatch
import Foundation

public enum CodexProcessError: Error, Equatable, Sendable {
    case notRunning
    case launchFailed(String)
    case writeFailed(String)
    case readFailed(String)
    case processExited(Int32)
    case timeout
}

public protocol CodexProcessTransport: AnyObject, Sendable {
    func launch(executable: URL, home: URL) throws
    func send(_ request: CodexRequest) throws
    func readResponses(for ids: Set<Int>, until deadline: Date) throws -> [Int: CodexMessage]
    func terminate()
    func terminate(until deadline: Date)
}

public extension CodexProcessTransport {
    /// Compatibility default for deterministic transports that do not own a child process.
    func terminate(until deadline: Date) {
        terminate()
    }
}

/// A line-oriented Foundation.Process transport for `codex app-server`.
/// Each instance owns one process and one isolated CODEX_HOME.
public final class CodexProcess: CodexProcessTransport, @unchecked Sendable {
    private static let gracefulTerminationTimeout: TimeInterval = 0.25
    private static let forcedTerminationTimeout: TimeInterval = 0.25

    private let inheritedEnvironment: [String: String]
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var resourcesCleanedUp = true
    private var decoder = CodexLineDecoder()
    private let wakeSignal = DispatchSemaphore(value: 0)

    public init() {
        self.inheritedEnvironment = ProcessInfo.processInfo.environment
    }

    init(inheritedEnvironment: [String: String]) {
        self.inheritedEnvironment = inheritedEnvironment
    }

    deinit {
        terminate()
    }

    public func launch(executable: URL, home: URL) throws {
        guard process == nil else { throw CodexProcessError.launchFailed("Process already launched") }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = executable
        process.arguments = ["app-server"]
        var environment = inheritedEnvironment
        environment["PATH"] = Self.childPath(
            inheritedPath: environment["PATH"],
            executable: executable
        )
        environment["CODEX_HOME"] = home.standardizedFileURL.path
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { [weak self] _ in
            self?.wakeSignal.signal()
        }

        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        self.resourcesCleanedUp = false

        do {
            try process.run()
            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] _ in
                self?.wakeSignal.signal()
            }
            try setNonBlocking(outputPipe.fileHandleForReading)
            try setNonBlocking(errorPipe.fileHandleForReading)
            errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                self?.drainStandardError(handle)
            }
        } catch {
            let launchError: CodexProcessError
            if let error = error as? CodexProcessError {
                launchError = error
            } else {
                launchError = .launchFailed(error.localizedDescription)
            }
            terminate(until: Date().addingTimeInterval(0.25))
            throw launchError
        }
    }

    public func send(_ request: CodexRequest) throws {
        guard process != nil, let input = inputPipe?.fileHandleForWriting else {
            throw CodexProcessError.notRunning
        }
        do {
            try input.write(contentsOf: request.encodedLine())
        } catch {
            throw CodexProcessError.writeFailed(error.localizedDescription)
        }
    }

    public func readResponses(for ids: Set<Int>, until deadline: Date) throws -> [Int: CodexMessage] {
        guard !ids.isEmpty else { return [:] }
        guard let process, let output = outputPipe?.fileHandleForReading else {
            throw CodexProcessError.notRunning
        }

        var responses: [Int: CodexMessage] = [:]
        while responses.count < ids.count {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw CodexProcessError.timeout }

            let waitInterval = DispatchTimeInterval.nanoseconds(
                Int(max(1, min(remaining, 60) * 1_000_000_000))
            )
            if wakeSignal.wait(timeout: .now() + waitInterval) == .timedOut {
                throw CodexProcessError.timeout
            }

            switch try readAvailable(from: output) {
            case let .data(data):
                for message in try decode(data) {
                    if let id = message.id, ids.contains(id) {
                        responses[id] = message
                    }
                }
                if responses.count == ids.count { return responses }
            case .wouldBlock:
                // Readability can be a stale/spurious signal. The descriptor is
                // non-blocking, so retrying the semaphore wait cannot exceed deadline.
                continue
            case .endOfFile:
                for message in try finishDecoding() {
                    if let id = message.id, ids.contains(id) {
                        responses[id] = message
                    }
                }
                if responses.count == ids.count { return responses }
                guard !process.isRunning else {
                    throw CodexProcessError.readFailed("Codex output closed before process exit")
                }
                throw CodexProcessError.processExited(process.terminationStatus)
            }
        }
        return responses
    }

    private func decode(_ data: Data) throws -> [CodexMessage] {
        do {
            return try decoder.append(data)
        } catch let error as CodexLineDecoderError {
            decoder.reset()
            throw CodexProcessError.readFailed(error.localizedDescription)
        }
    }

    private func finishDecoding() throws -> [CodexMessage] {
        do {
            return try decoder.finish()
        } catch let error as CodexLineDecoderError {
            decoder.reset()
            throw CodexProcessError.readFailed(error.localizedDescription)
        }
    }

    /// Stops the process and closes all pipe handles. Safe to call repeatedly.
    public func terminate() {
        terminate(until: Date().addingTimeInterval(Self.gracefulTerminationTimeout))
    }

    /// Sends SIGTERM, then force-kills an uncooperative child. Both waits are
    /// bounded by the caller's deadline and explicit short termination windows.
    public func terminate(until deadline: Date) {
        guard !resourcesCleanedUp else { return }

        if let process, process.isRunning {
            process.terminate()
            waitForExit(process, until: min(
                deadline,
                Date().addingTimeInterval(Self.gracefulTerminationTimeout)
            ))

            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                waitForExit(process, until: min(
                    deadline,
                    Date().addingTimeInterval(Self.forcedTerminationTimeout)
                ))
            }
        }

        cleanupResources()
        process = nil
    }

    private func waitForExit(_ process: Process, until deadline: Date) {
        while process.isRunning {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return }
            Thread.sleep(forTimeInterval: min(0.01, remaining))
        }
    }

    private enum NonBlockingRead {
        case data(Data)
        case wouldBlock
        case endOfFile
    }

    private static func childPath(inheritedPath: String?, executable: URL) -> String {
        let preferredDirectories = [
            executable.deletingLastPathComponent().standardizedFileURL.path,
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
        ]
        let inheritedDirectories = (inheritedPath ?? "")
            .split(separator: ":")
            .map(String.init)

        var seen = Set<String>()
        return (preferredDirectories + inheritedDirectories)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    private func setNonBlocking(_ handle: FileHandle) throws {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0 else {
            throw CodexProcessError.launchFailed("Unable to inspect Codex pipe: \(String(cString: strerror(errno)))")
        }
        guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw CodexProcessError.launchFailed("Unable to configure Codex pipe: \(String(cString: strerror(errno)))")
        }
    }

    private func readAvailable(from handle: FileHandle) throws -> NonBlockingRead {
        var bytes = [UInt8](repeating: 0, count: 65_536)
        let count = bytes.withUnsafeMutableBytes { rawBuffer -> Int in
            guard let baseAddress = rawBuffer.baseAddress else { return 0 }
            return Darwin.read(handle.fileDescriptor, baseAddress, rawBuffer.count)
        }
        if count > 0 {
            return .data(Data(bytes[0..<count]))
        }
        if count == 0 {
            return .endOfFile
        }
        if errno == EAGAIN || errno == EWOULDBLOCK {
            return .wouldBlock
        }
        throw CodexProcessError.readFailed("Unable to read Codex output: \(String(cString: strerror(errno)))")
    }

    private func drainStandardError(_ handle: FileHandle) {
        while true {
            guard let result = try? readAvailable(from: handle) else { return }
            switch result {
            case .data:
                continue
            case .wouldBlock, .endOfFile:
                return
            }
        }
    }

    private func cleanupResources() {
        guard !resourcesCleanedUp else { return }
        resourcesCleanedUp = true

        process?.terminationHandler = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        for handle in [
            inputPipe?.fileHandleForWriting,
            outputPipe?.fileHandleForReading,
            errorPipe?.fileHandleForReading,
        ].compactMap({ $0 }) {
            try? handle.close()
        }
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
    }
}
