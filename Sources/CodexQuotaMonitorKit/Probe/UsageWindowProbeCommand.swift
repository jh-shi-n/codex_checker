import Foundation

/// Fully materialized command input for the process runner. Account paths are
/// kept here only long enough to configure the child process; they are never
/// copied into `UsageWindowProbeResult` or `UsageWindowProbeState`.
public struct UsageWindowProbeCommand: Equatable, Sendable {
    public let executableURL: URL
    public let configuredAccountHome: URL
    public let arguments: [String]
    public let environmentOverrides: [String: String]
    /// Deliberately nil: the probe must not run in a project working directory.
    public let currentDirectoryURL: URL?
    public let metadata: UsageWindowProbeCommandMetadata

    public init(
        executableURL: URL,
        configuredAccountHome: URL,
        arguments: [String],
        environmentOverrides: [String: String],
        currentDirectoryURL: URL? = nil,
        metadata: UsageWindowProbeCommandMetadata = .default
    ) {
        self.executableURL = executableURL.standardizedFileURL
        self.configuredAccountHome = configuredAccountHome.standardizedFileURL
        self.arguments = arguments
        self.environmentOverrides = environmentOverrides
        self.currentDirectoryURL = currentDirectoryURL
        self.metadata = metadata
    }

    public var executable: URL { executableURL }
    public var environment: [String: String] { environmentOverrides }
    public var modelIdentifier: String { metadata.modelIdentifier }
    public var displayName: String { metadata.displayName }
}

/// Builds the one minimal, read-only Codex request used by the UI's manual
/// usage-window check.
public struct UsageWindowProbeCommandBuilder: Sendable {
    public static let executableName = "codex"
    public static let modelIdentifier = "gpt-5.6-luna"
    public static let displayName = "Luna Light"
    public static let minimalPrompt = "print 1"

    public let metadata: UsageWindowProbeCommandMetadata

    public init(metadata: UsageWindowProbeCommandMetadata = .default) {
        self.metadata = metadata
    }

    /// Creates the exact process contract. The executable URL is supplied by
    /// an injected locator, while the selected account home is retained for
    /// the live runner's authentication-link setup.
    public func build(
        executable: URL,
        configuredAccountHome: URL
    ) -> UsageWindowProbeCommand {
        UsageWindowProbeCommand(
            executableURL: executable,
            configuredAccountHome: configuredAccountHome,
            arguments: Self.arguments,
            environmentOverrides: [
                "CODEX_HOME": configuredAccountHome.standardizedFileURL.path,
            ],
            currentDirectoryURL: nil,
            metadata: metadata
        )
    }

    public func build(
        executable: URL,
        home: URL
    ) -> UsageWindowProbeCommand {
        build(executable: executable, configuredAccountHome: home)
    }

    public func makeCommand(
        executable: URL,
        configuredAccountHome: URL
    ) -> UsageWindowProbeCommand {
        build(executable: executable, configuredAccountHome: configuredAccountHome)
    }

    public func makeCommand(
        executable: URL,
        home: URL
    ) -> UsageWindowProbeCommand {
        build(executable: executable, configuredAccountHome: home)
    }

    public static let arguments: [String] = [
        "exec",
        "--ephemeral",
        "--skip-git-repo-check",
        "--ignore-rules",
        "--ignore-user-config",
        "--sandbox",
        "read-only",
        "--model",
        modelIdentifier,
        "-c",
        "model_reasoning_effort=\"low\"",
        "--json",
        minimalPrompt,
    ]
}
