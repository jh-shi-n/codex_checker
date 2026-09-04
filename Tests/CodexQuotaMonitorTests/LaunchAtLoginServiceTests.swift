import XCTest
@testable import CodexQuotaMonitorKit

@MainActor
final class LaunchAtLoginServiceTests: XCTestCase {
    func testBackendSuccessUpdatesReadableStatus() {
        let backend = FakeLaunchBackend(status: .disabled)
        let service = LaunchAtLoginService(backend: backend)

        let result = service.setEnabled(true)

        XCTAssertEqual(result, .success(.enabled))
        XCTAssertEqual(service.status, .enabled)
        XCTAssertEqual(backend.registerCount, 1)
        XCTAssertEqual(backend.unregisterCount, 0)
    }

    func testAlreadyEnabledRegistrationIsIdempotent() {
        let backend = FakeLaunchBackend(status: .enabled)
        let service = LaunchAtLoginService(backend: backend)

        XCTAssertEqual(service.setEnabled(true), .success(.enabled))
        XCTAssertEqual(backend.registerCount, 0)
    }

    func testAlreadyDisabledUnregistrationIsIdempotent() {
        let backend = FakeLaunchBackend(status: .disabled)
        let service = LaunchAtLoginService(backend: backend)

        XCTAssertEqual(service.setEnabled(false), .success(.disabled))
        XCTAssertEqual(backend.unregisterCount, 0)
    }

    func testBackendFailureIsMappedWithoutChangingStatus() {
        let backend = FakeLaunchBackend(status: .disabled, registerError: FakeLaunchError.denied)
        let service = LaunchAtLoginService(backend: backend)

        let result = service.setEnabled(true)

        guard case let .failure(error) = result else {
            return XCTFail("Expected a mapped launch-at-login failure")
        }
        XCTAssertEqual(error, .operationFailed("denied"))
        XCTAssertEqual(service.status, .disabled)
        XCTAssertEqual(backend.registerCount, 1)
    }

    func testDisableUsesBackendAndExposesRequiresApprovalStatus() {
        let backend = FakeLaunchBackend(status: .enabled)
        let service = LaunchAtLoginService(backend: backend)

        XCTAssertEqual(service.setEnabled(false), .success(.disabled))
        XCTAssertEqual(backend.unregisterCount, 1)

        backend.currentStatus = .requiresApproval
        XCTAssertEqual(service.status, .requiresApproval)
    }

    func testRequiresApprovalCanOpenLoginItemsThroughInjectedOpener() {
        let backend = FakeLaunchBackend(status: .requiresApproval)
        let opener = FakeLaunchItemsOpener()
        let service = LaunchAtLoginService(backend: backend, settingsOpener: opener)

        XCTAssertEqual(service.setEnabled(true), .success(.requiresApproval))
        XCTAssertEqual(backend.registerCount, 0)
        service.openSystemSettingsLoginItems()
        XCTAssertEqual(opener.openCount, 1)
    }

    func testRegisterFailureRereadsUpdatedRequiresApprovalAndKeepsOpenerExplicit() {
        let backend = FakeLaunchBackend(
            status: .disabled,
            registerError: FakeLaunchError.denied,
            statusAfterRegisterError: .requiresApproval
        )
        let opener = FakeLaunchItemsOpener()
        let service = LaunchAtLoginService(backend: backend, settingsOpener: opener)

        XCTAssertEqual(service.setEnabled(true), .success(.requiresApproval))
        XCTAssertEqual(service.status, .requiresApproval)
        XCTAssertGreaterThanOrEqual(backend.statusReadCount, 2)
        XCTAssertEqual(opener.openCount, 0)

        service.openSystemSettingsLoginItems()
        XCTAssertEqual(opener.openCount, 1)
    }

    func testUnregisterFailureWithRequiresApprovalStatusRemainsGenericError() {
        let backend = FakeLaunchBackend(
            status: .enabled,
            unregisterError: FakeLaunchError.denied,
            statusAfterUnregisterError: .requiresApproval
        )
        let service = LaunchAtLoginService(backend: backend)

        XCTAssertEqual(service.setEnabled(false), .failure(.operationFailed("denied")))
        XCTAssertEqual(service.status, .requiresApproval)
    }

    func testNotFoundDisableIsDistinguishedWithoutUnregistering() {
        let backend = FakeLaunchBackend(status: .notFound)
        let service = LaunchAtLoginService(backend: backend)

        XCTAssertEqual(service.setEnabled(false), .success(.notFound))
        XCTAssertEqual(backend.unregisterCount, 0)
        XCTAssertEqual(service.status, .notFound)
    }

    func testNotFoundEnableRegistersAndReturnsEnabled() {
        let backend = FakeLaunchBackend(status: .notFound)
        let service = LaunchAtLoginService(backend: backend)

        XCTAssertEqual(service.setEnabled(true), .success(.enabled))
        XCTAssertEqual(backend.registerCount, 1)
        XCTAssertEqual(service.status, .enabled)
    }

    func testNotFoundEnableReturnsRequiresApprovalWhenRegistrationReportsIt() {
        let backend = FakeLaunchBackend(
            status: .notFound,
            statusAfterRegister: .requiresApproval
        )
        let service = LaunchAtLoginService(backend: backend)

        XCTAssertEqual(service.setEnabled(true), .success(.requiresApproval))
        XCTAssertEqual(backend.registerCount, 1)
        XCTAssertEqual(service.status, .requiresApproval)
    }
}

private enum FakeLaunchError: Error, LocalizedError {
    case denied

    var errorDescription: String? { "denied" }
}

private final class FakeLaunchBackend: LaunchAtLoginBackend, @unchecked Sendable {
    var currentStatus: LaunchAtLoginStatus
    let registerError: Error?
    let unregisterError: Error?
    let statusAfterRegisterError: LaunchAtLoginStatus?
    let statusAfterUnregisterError: LaunchAtLoginStatus?
    let statusAfterRegister: LaunchAtLoginStatus?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var statusReadCount = 0

    init(
        status: LaunchAtLoginStatus,
        registerError: Error? = nil,
        unregisterError: Error? = nil,
        statusAfterRegisterError: LaunchAtLoginStatus? = nil,
        statusAfterUnregisterError: LaunchAtLoginStatus? = nil,
        statusAfterRegister: LaunchAtLoginStatus? = nil
    ) {
        self.currentStatus = status
        self.registerError = registerError
        self.unregisterError = unregisterError
        self.statusAfterRegisterError = statusAfterRegisterError
        self.statusAfterUnregisterError = statusAfterUnregisterError
        self.statusAfterRegister = statusAfterRegister
    }

    var status: LaunchAtLoginStatus {
        statusReadCount += 1
        return currentStatus
    }

    func register() throws {
        registerCount += 1
        if let registerError {
            if let statusAfterRegisterError {
                currentStatus = statusAfterRegisterError
            }
            throw registerError
        }
        currentStatus = statusAfterRegister ?? .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError {
            if let statusAfterUnregisterError {
                currentStatus = statusAfterUnregisterError
            }
            throw unregisterError
        }
        currentStatus = .disabled
    }
}

private final class FakeLaunchItemsOpener: LaunchAtLoginSettingsOpener, @unchecked Sendable {
    private(set) var openCount = 0

    func openLoginItems() {
        openCount += 1
    }
}
