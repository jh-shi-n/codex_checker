import Foundation
import ServiceManagement

public enum LaunchAtLoginStatus: String, Equatable, Sendable {
    case enabled
    case disabled
    case requiresApproval
    case notFound
}

public enum LaunchAtLoginError: Error, Equatable, Sendable {
    case operationFailed(String)
}

extension LaunchAtLoginError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .operationFailed(message):
            return message
        }
    }
}

/// Narrow backend seam so tests can observe registration calls without
/// mutating the real login-item database.
public protocol LaunchAtLoginBackend: AnyObject, Sendable {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
}

/// Injectable seam for the explicit user action that opens Login Items in
/// System Settings. Startup/status reads never call this method.
public protocol LaunchAtLoginSettingsOpener: AnyObject, Sendable {
    func openLoginItems()
}

/// Production adapter around ServiceManagement's main app login item.
public final class SystemLaunchAtLoginBackend: LaunchAtLoginBackend, @unchecked Sendable {
    private let service: SMAppService

    public init(service: SMAppService = .mainApp) {
        self.service = service
    }

    public var status: LaunchAtLoginStatus {
        switch service.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        case .notRegistered:
            return .disabled
        @unknown default:
            return .notFound
        }
    }

    public func register() throws {
        try service.register()
    }

    public func unregister() throws {
        try service.unregister()
    }
}

/// Production adapter for the Login Items control panel.
public final class SystemLaunchAtLoginSettingsOpener: LaunchAtLoginSettingsOpener, @unchecked Sendable {
    public init() {}

    public func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// User-action-only facade for launch-at-login changes. Reading `status` is
/// side-effect free; registration happens only when `setEnabled(_:)` is called.
@MainActor
public final class LaunchAtLoginService {
    public let backend: any LaunchAtLoginBackend
    public let settingsOpener: any LaunchAtLoginSettingsOpener
    public private(set) var lastError: LaunchAtLoginError?

    public init(
        backend: any LaunchAtLoginBackend = SystemLaunchAtLoginBackend(),
        settingsOpener: any LaunchAtLoginSettingsOpener = SystemLaunchAtLoginSettingsOpener()
    ) {
        self.backend = backend
        self.settingsOpener = settingsOpener
    }

    public var status: LaunchAtLoginStatus {
        backend.status
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool) -> Result<LaunchAtLoginStatus, LaunchAtLoginError> {
        lastError = nil
        let currentStatus = backend.status
        if enabled {
            if currentStatus == .enabled || currentStatus == .requiresApproval {
                return .success(currentStatus)
            }
        } else if currentStatus == .disabled || currentStatus == .notFound {
            return .success(currentStatus)
        }

        do {
            if enabled {
                try backend.register()
            } else {
                try backend.unregister()
            }
            return .success(backend.status)
        } catch {
            // ServiceManagement may throw when registration is awaiting or
            // denied by user approval while the backend status has already
            // moved to requiresApproval. Surface that effective status so the
            // host can use its approval-specific alert and explicit opener.
            if enabled, backend.status == .requiresApproval {
                return .success(.requiresApproval)
            }
            let mapped = LaunchAtLoginError.operationFailed(error.localizedDescription)
            lastError = mapped
            return .failure(mapped)
        }
    }

    /// Opens Login Items only after an explicit user action, typically when
    /// registration reports requiresApproval.
    public func openSystemSettingsLoginItems() {
        settingsOpener.openLoginItems()
    }

    /// Throwing spelling for callers that prefer structured error handling.
    public func setEnabledOrThrow(_ enabled: Bool) throws -> LaunchAtLoginStatus {
        switch setEnabled(enabled) {
        case let .success(status):
            return status
        case let .failure(error):
            throw error
        }
    }
}
