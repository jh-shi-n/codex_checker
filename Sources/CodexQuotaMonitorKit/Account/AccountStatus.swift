import Foundation

/// The presentation state of one independently refreshed Codex account.
public enum AccountStatus: String, Codable, Equatable, Sendable {
    case notConfigured
    case normal
    case loading
    case loginRequired
    case codexNotFound
    case timeout
    case error
}
