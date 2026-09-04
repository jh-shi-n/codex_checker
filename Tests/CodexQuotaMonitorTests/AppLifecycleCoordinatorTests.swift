import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

@MainActor
final class AppLifecycleCoordinatorTests: XCTestCase {
    func testLaunchReadsStatusRendersLoadingAndStartsRefreshInOrder() {
        let probe = LifecycleProbe()
        let coordinator = AppLifecycleCoordinator(actions: makeActions(probe: probe))

        coordinator.launch()

        XCTAssertEqual(probe.events, [
            "activate",
            "renderLoading",
            "startObservers",
            "showPanels",
            "readLaunchStatus",
            "startRefresh",
        ])
        XCTAssertEqual(coordinator.launchAtLoginStatus, .enabled)
        XCTAssertTrue(coordinator.isLaunched)
    }

    func testWakeRelayoutsThenRequestsRefresh() async {
        let probe = LifecycleProbe()
        let coordinator = AppLifecycleCoordinator(actions: makeActions(probe: probe))
        coordinator.launch()
        probe.events.removeAll()

        await coordinator.wake()

        XCTAssertEqual(probe.events, ["relayout", "refreshNow"])
    }

    func testSettingsChangesRestartAndReconfigureThenRefreshAndTerminationCleansUp() async {
        let probe = LifecycleProbe()
        let coordinator = AppLifecycleCoordinator(actions: makeActions(probe: probe))
        coordinator.launch()
        probe.events.removeAll()
        let paths = ["/tmp/c1", "/tmp/c2", "/tmp/c3", "/tmp/c4"]

        coordinator.restartRefresh(intervalMinutes: 10)
        await coordinator.reconfigure(paths: paths)
        coordinator.terminate()
        coordinator.terminate()

        XCTAssertEqual(probe.events, [
            "restartRefresh:10",
            "reconfigurePaths",
            "refreshNow",
            "stopRefresh",
            "hidePanels",
            "stopObservers",
        ])
        XCTAssertFalse(coordinator.isLaunched)
    }

    func testStartupStatusReadIsExplicitlyReadOnly() {
        let probe = LifecycleProbe()
        let coordinator = AppLifecycleCoordinator(actions: makeActions(probe: probe))

        XCTAssertEqual(coordinator.readLaunchAtLoginStatus(), .enabled)
        XCTAssertEqual(probe.readStatusCount, 1)
        XCTAssertEqual(probe.mutationCount, 0)
    }

    func testApplyingIntervalPersistsBeforeExactlyOneRestartCallback() {
        let defaults = UserDefaults(suiteName: "CodexQuotaMonitorTests.\(UUID().uuidString)")!
        let preferences = PreferencesStore(userDefaults: defaults)
        let probe = LifecycleProbe()
        let coordinator = AppLifecycleCoordinator(actions: makeActions(probe: probe))

        coordinator.applyRefreshInterval(minutes: 7) { value in
            preferences.updateRefreshInterval(minutes: value)
            return preferences.refreshIntervalMinutes
        }

        XCTAssertEqual(preferences.refreshIntervalMinutes, 7)
        XCTAssertEqual(defaults.object(forKey: PreferencesStore.Keys.refreshIntervalMinutes) as? Int, 7)
        XCTAssertEqual(PreferencesStore(userDefaults: defaults).refreshIntervalMinutes, 7)
        XCTAssertEqual(probe.events, ["restartRefresh:7"])
    }

    private func makeActions(probe: LifecycleProbe) -> AppLifecycleActions {
        AppLifecycleActions(
            activateAccessory: { probe.record("activate") },
            renderLoading: { probe.record("renderLoading") },
            startObservers: { probe.record("startObservers") },
            showPanels: { probe.record("showPanels") },
            startRefresh: { probe.record("startRefresh") },
            stopRefresh: { probe.record("stopRefresh") },
            hidePanels: { probe.record("hidePanels") },
            stopObservers: { probe.record("stopObservers") },
            relayout: { probe.record("relayout") },
            refreshNow: { probe.record("refreshNow") },
            restartRefresh: { minutes in probe.record("restartRefresh:\(minutes)") },
            reconfigurePaths: { _ in probe.record("reconfigurePaths") },
            readLaunchAtLoginStatus: {
                probe.record("readLaunchStatus")
                probe.readStatusCount += 1
                return .enabled
            }
        )
    }
}

@MainActor
private final class LifecycleProbe {
    var events: [String] = []
    var readStatusCount = 0
    var mutationCount = 0

    func record(_ event: String) {
        events.append(event)
    }
}
