import XCTest
@testable import CodexQuotaMonitorKit

@MainActor
final class QuotaPresentationTests: XCTestCase {
    func testSessionIDFormattingShortensDisplayButPreservesFullCopyValue() {
        let snapshot = SessionActivitySnapshot(
            accountID: "C1",
            state: .available,
            source: .localActivity,
            sessionID: "019fe59b123456",
            status: .working,
            agents: []
        )

        XCTAssertEqual(CLIActivitySection.shortSessionID(snapshot.sessionID), "019fe59b...")
        XCTAssertEqual(CLIActivitySection.copyValue(for: snapshot), "019fe59b123456")
        XCTAssertEqual(CLIActivitySection.shortSessionID(nil), "—")
    }

    func testSessionActivityCopiesCoverLoadingEmptyUnavailableAndStatus() {
        XCTAssertEqual(CLIActivitySection.loadingText, "Loading session activity…")
        XCTAssertEqual(CLIActivitySection.emptyText, "No recent Codex activity")
        XCTAssertEqual(CLIActivitySection.unavailableText, "Session status unavailable")
        XCTAssertEqual(CLIActivitySection.activityRefreshInterval, 5)
        XCTAssertEqual(CLIActivitySection.cardListMaxHeight, 440)
        XCTAssertEqual(CLIActivitySection.statusText(.working), "Working")
        XCTAssertEqual(CLIActivitySection.statusText(.waiting), "Waiting")
        XCTAssertEqual(CLIActivitySection.statusText(.completed), "Completed")
        XCTAssertEqual(CLIActivitySection.statusText(.stopped), "Stopped")
        XCTAssertEqual(CLIActivitySection.statusText(.error), "Error")
        XCTAssertEqual(CLIActivitySection.statusText(.unknown), "Unknown")

        guard let inactive = SessionActivityStatus(rawValue: "inactive") else {
            XCTFail("inactive status should be normalized")
            return
        }
        XCTAssertEqual(CLIActivitySection.statusText(inactive), "Inactive")
    }

    func testAccountDetailPopoverUsesPracticalFixedContentSizeAndBoundedActivityCards() {
        XCTAssertEqual(
            AccountDetailView.popoverContentSize,
            CGSize(width: 640, height: 760)
        )
        XCTAssertEqual(CLIActivitySection.cardListMaxHeight, 440)
    }

    func testDashboardPopoverPreferredSizeClampsToVisibleScreen() {
        XCTAssertEqual(
            TransientPopoverSizingPolicy.preferredContentSize,
            CGSize(width: 640, height: 760)
        )
        XCTAssertEqual(
            TransientPopoverSizingPolicy.clampedContentSize(
                visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 620)
            ),
            CGSize(width: 500, height: 620)
        )
    }

    func testContributionIntensityUsesRelativeNonzeroDistributionAndExplicitNoData() {
        XCTAssertTrue(TokenContributionGrid.notLoadedMessage.contains("업데이트"))
        let distribution: [Int64] = [0, 10, 20, 30, 40]
        XCTAssertEqual(
            TokenContributionGrid.intensity(for: 0, distribution: distribution),
            .none
        )
        XCTAssertEqual(
            TokenContributionGrid.intensity(for: 10, distribution: distribution),
            .low
        )
        XCTAssertEqual(
            TokenContributionGrid.intensity(for: 40, distribution: distribution),
            .veryHigh
        )
        XCTAssertTrue(
            TokenContributionGrid.isNoData(
                TokenUsageDailyPoint(date: Date(), totals: .zero, sessionCount: 0)
            )
        )
    }

    func testDashboardNumberAndResetDeltaFormattingStayBounded() {
        XCTAssertEqual(AccountDashboardFormatting.numberText(128_020), "128,020")
        XCTAssertEqual(AccountDashboardFormatting.abbreviatedNumber(1_200), "1.2K")
        XCTAssertEqual(AccountDashboardFormatting.abbreviatedNumber(10_000), "10K")

        let before = Date(timeIntervalSince1970: 1_700_000_000)
        let after = before.addingTimeInterval(-60)
        let delta = AccountDashboardFormatting.resetDeltaText(before: before, after: after)
        XCTAssertTrue(delta.contains("→"))
        XCTAssertTrue(delta.contains("▼1분"))
    }

    func testDashboardDefaultUsageAndProbeNeverClaimData() async {
        let account = AccountState(id: "C1", status: .notConfigured)
        let cacheMiss = await AccountDashboardDefaults.emptyTokenUsageLookup(account.id)
        XCTAssertNil(cacheMiss)
        let snapshot = await AccountDashboardDefaults.unavailableTokenUsageRefresh(account)
        XCTAssertEqual(snapshot.availability, .unavailable)
        XCTAssertEqual(snapshot.dailyPoints.count, TokenUsageSnapshot.historyDayCount)

        let result = await AccountDetailView.defaultProbeRunner(account)
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.failureCategory, .notConfigured)
        XCTAssertNil(result.primaryResetBefore)
        XCTAssertNil(result.primaryResetAfter)
    }

    func testProbeRunnerPropagatesCompositeResetObservation() async {
        let before = Date(timeIntervalSince1970: 1_700_000_000)
        let after = before.addingTimeInterval(-60)
        let boundedResult = UsageWindowProbeResult(
            accountID: "C2",
            status: .success,
            startedAt: before,
            completedAt: after,
            usage: UsageWindowProbeTokenUsage(
                inputTokens: 96_240,
                outputTokens: 31_780,
                totalTokens: 128_020
            )
        )
        let expected = UsageWindowProbePresentationResult(
            result: boundedResult,
            primaryResetBefore: before,
            primaryResetAfter: after
        )
        let runner: UsageWindowProbeRunner = { _ in expected }

        let actual = await runner(AccountState(id: "C2", status: .normal))
        XCTAssertEqual(actual.result, boundedResult)
        XCTAssertEqual(actual.primaryResetBefore, before)
        XCTAssertEqual(actual.primaryResetAfter, after)
    }

    func testDashboardProbeActionRequiresConfiguredIdleAccount() {
        XCTAssertTrue(
            AccountDashboardActionState.canRunProbe(
                account: AccountState(id: "C1", status: .normal),
                isRunning: false
            )
        )
        XCTAssertFalse(
            AccountDashboardActionState.canRunProbe(
                account: AccountState(id: "C1", status: .normal),
                isRunning: true
            )
        )
        XCTAssertFalse(
            AccountDashboardActionState.canRunProbe(
                account: AccountState(id: "C1", status: .notConfigured),
                isRunning: false
            )
        )
    }

    func testPopoverSizingPolicyClampsToFinitePositiveVisibleBounds() {
        let clamped = TransientPopoverSizingPolicy.clampedContentSize(
            preferred: CGSize(width: CGFloat.infinity, height: CGFloat.nan),
            visibleFrame: CGRect(x: 0, y: 0, width: 320, height: 250)
        )

        XCTAssertEqual(clamped, CGSize(width: 320, height: 250))
        XCTAssertTrue(clamped.width.isFinite)
        XCTAssertTrue(clamped.height.isFinite)
        XCTAssertGreaterThan(clamped.width, 0)
        XCTAssertGreaterThan(clamped.height, 0)

        let fallback = TransientPopoverSizingPolicy.clampedContentSize(
            preferred: CGSize(width: -1, height: 0),
            visibleFrame: CGRect(x: 0, y: 0, width: CGFloat.nan, height: CGFloat.infinity)
        )

        XCTAssertEqual(fallback, CGSize(width: 640, height: 760))
    }

    func testMainActiveFallbackAndStatusMappingsRemainVisible() {
        XCTAssertEqual(SessionActivityStatus.map(raw: "running"), .working)
        XCTAssertEqual(SessionActivityStatus.map(raw: "waiting_on_user_input"), .waiting)
        XCTAssertEqual(SessionActivityStatus.map(raw: "completed"), .completed)

        let activeUnknown = SessionActivityMainSession(
            threadID: "active",
            source: .cli,
            taskName: "Active session",
            status: .unknown,
            agents: [],
            isActive: true
        )
        let inactiveUnknown = SessionActivityMainSession(
            threadID: "inactive",
            source: .cli,
            taskName: "Inactive session",
            status: .unknown,
            agents: [],
            isActive: false
        )

        XCTAssertEqual(
            CLIActivitySection.mainStatusText(for: SessionActivityPresentationItem(session: activeUnknown)),
            "Working"
        )
        XCTAssertEqual(
            CLIActivitySection.mainStatusText(for: SessionActivityPresentationItem(session: inactiveUnknown)),
            "Unknown"
        )

        guard let inactiveStatus = SessionActivityStatus(rawValue: "inactive") else {
            XCTFail("inactive status should be normalized")
            return
        }
        let inactive = SessionActivityMainSession(
            threadID: "inactive-descendants",
            source: .cli,
            taskName: "Stale descendants",
            status: inactiveStatus,
            agents: [
                SessionActivityAgent(
                    threadID: "stale-agent",
                    parentThreadID: "inactive-descendants",
                    taskName: "Stale task",
                    status: inactiveStatus
                ),
            ],
            isActive: true
        )
        XCTAssertEqual(
            CLIActivitySection.mainStatusText(for: SessionActivityPresentationItem(session: inactive)),
            "Inactive"
        )
    }

    func testSessionRowLabelDistinguishesLastKnownFromCurrentActivity() {
        XCTAssertEqual(
            CLIActivitySection.sessionRowLabel(for: .localActivity),
            "Current session"
        )
        XCTAssertEqual(
            CLIActivitySection.sessionRowLabel(for: .lastKnown),
            "Last-known session"
        )
    }

    func testShimmerIsWorkingOnlyAndDisabledForReduceMotion() {
        XCTAssertTrue(ShimmerText.shouldAnimate(status: .working, reduceMotion: false))
        XCTAssertFalse(ShimmerText.shouldAnimate(status: .waiting, reduceMotion: false))
        XCTAssertFalse(ShimmerText.shouldAnimate(status: .working, reduceMotion: true))
        XCTAssertEqual(ShimmerText.animationDuration, 1.5)
    }

    func testSessionActivityLoaderCanReturnInjectedFakeSnapshot() async {
        let account = AccountState(id: "C2", status: .normal)
        let expected = SessionActivitySnapshot(
            accountID: "C2",
            state: .available,
            source: .localActivity,
            sessionID: "fake-session",
            status: .working,
            agents: [
                SessionActivityAgent(
                    threadID: "internal-id",
                    parentThreadID: nil,
                    taskName: "Settings window fix",
                    status: .working
                ),
            ]
        )

        let actual = await CLIActivitySection.loadSnapshot(
            account: account,
            loader: { _ in expected }
        )

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(CLIActivitySection.displayName(for: expected.agents[0]), "Settings window fix")
    }

    func testActivityRefreshLoopLoadsSequentialSnapshotsUntilInjectedSleeperStops() async {
        let recorder = ActivityRefreshRecorder(
            snapshots: [
                .empty(accountID: "C1"),
                SessionActivitySnapshot(
                    accountID: "C1",
                    state: .available,
                    source: .localActivity,
                    sessionID: "root",
                    status: .working,
                    agents: []
                ),
            ]
        )

        await CLIActivitySection.refreshSnapshots(
            account: AccountState(id: "C1", status: .normal),
            interval: 2,
            loader: { _ in await recorder.nextSnapshot() },
            sleep: { interval in
                await recorder.recordSleep(interval)
                if await recorder.sleepCount > 1 {
                    throw CancellationError()
                }
            },
            onSnapshot: { snapshot in
                await recorder.recordDelivered(snapshot)
            }
        )

        let loadedCount = await recorder.loadedCount
        let deliveredCount = await recorder.deliveredCount
        let sleepIntervals = await recorder.sleepIntervals
        let maxConcurrentLoads = await recorder.maxConcurrentLoads
        XCTAssertEqual(loadedCount, 2)
        XCTAssertEqual(deliveredCount, 2)
        XCTAssertEqual(sleepIntervals, [2, 2])
        XCTAssertEqual(maxConcurrentLoads, 1)
    }

    func testRetainedRowsWinOverEmptyAndUnavailableCopies() {
        let active = SessionActivityMainSession(
            threadID: "root",
            source: .cli,
            taskName: "Main task",
            status: .working,
            agents: []
        )
        let empty = SessionActivitySnapshot.empty(accountID: "C1")
        let unavailable = SessionActivitySnapshot.unavailable(accountID: "C1")

        XCTAssertTrue(CLIActivitySection.shouldRenderRetainedSessions(snapshot: empty, retainedSessionCount: 1))
        XCTAssertTrue(CLIActivitySection.shouldRenderRetainedSessions(snapshot: unavailable, retainedSessionCount: 1))
        XCTAssertFalse(CLIActivitySection.shouldRenderRetainedSessions(snapshot: empty, retainedSessionCount: 0))
        XCTAssertEqual(
            CLIActivitySection.mainStatusText(
                for: SessionActivityPresentationItem(session: active)
            ),
            "Working"
        )
    }

    func testDuplicateIncomingRootIDsRenderExactlyOneDeterministicItem() {
        let model = SessionActivityPresentationModel()
        let first = makeMainSession(id: "duplicate-root", taskName: "First task")
        let second = makeMainSession(id: "duplicate-root", taskName: "Second task")

        model.update(sessions: [first, second])

        XCTAssertEqual(model.sessions.map(\.id), ["duplicate-root"])
        XCTAssertEqual(model.sessions.first?.taskName, "First task")
    }

    func testDepartingRootDimsImmediatelyAndSchedulesExactlyFiveSecondRemoval() async {
        let gate = PresentationSleepGate()
        let model = SessionActivityPresentationModel(
            sleep: { seconds in await gate.sleep(seconds) }
        )
        let active = makeMainSession(id: "root", taskName: "Main task")

        model.update(sessions: [active])
        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertFalse(model.sessions[0].isDeparting)

        model.update(sessions: [])
        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertTrue(model.sessions[0].isDeparting)
        XCTAssertEqual(model.sessions[0].opacity, 0.45)

        await gate.waitUntilEntered()
        let requestedDurations = await gate.requestedDurations
        XCTAssertEqual(requestedDurations, [5])

        await gate.release()
        await waitForPresentationRemoval(model)
        XCTAssertTrue(model.sessions.isEmpty)
    }

    func testReappearingRootCancelsPendingRemovalAndRestoresOpacity() async {
        let gate = PresentationSleepGate()
        let model = SessionActivityPresentationModel(
            sleep: { seconds in await gate.sleep(seconds) }
        )
        let active = makeMainSession(id: "root", taskName: "Main task")

        model.update(sessions: [active])
        model.update(sessions: [])
        await gate.waitUntilEntered()

        model.update(sessions: [active])
        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertFalse(model.sessions[0].isDeparting)
        XCTAssertEqual(model.sessions[0].opacity, 1)

        await gate.release()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.sessions.map(\.id), ["root"])
    }

    private func makeMainSession(id: String, taskName: String) -> SessionActivityMainSession {
        SessionActivityMainSession(
            threadID: id,
            source: .cli,
            taskName: taskName,
            status: .working,
            agents: []
        )
    }

    private func waitForPresentationRemoval(
        _ model: SessionActivityPresentationModel
    ) async {
        for _ in 0..<50 {
            if model.sessions.isEmpty { return }
            await Task.yield()
        }
    }

    func testQuotaLevelBoundariesUseRemainingPercentage() {
        let cases: [(Double, QuotaLevel, String)] = [
            (0, .critical, "#FF3B30"),
            (1, .critical, "#FF3B30"),
            (9, .critical, "#FF3B30"),
            (10, .low, "#FF5E57"),
            (29, .low, "#FF5E57"),
            (30, .attention, "#FFB800"),
            (59, .attention, "#FFB800"),
            (60, .normal, "#30D158"),
            (99, .normal, "#30D158"),
            (100, .normal, "#30D158"),
        ]

        for (remaining, expectedLevel, expectedHex) in cases {
            XCTAssertEqual(QuotaColors.level(for: remaining), expectedLevel, "remaining \(remaining)")
            XCTAssertEqual(QuotaColors.color(for: remaining).hex, expectedHex, "remaining \(remaining)")
        }
    }

    func testQuotaPercentagesAreClampedBeforeSemanticClassification() {
        XCTAssertEqual(QuotaColors.level(for: -10), .critical)
        XCTAssertEqual(QuotaColors.level(for: 140), .normal)
        XCTAssertEqual(QuotaColors.clampedPercent(-1), 0)
        XCTAssertEqual(QuotaColors.clampedPercent(101), 100)
    }

    func testNonFinitePercentagesFollowTheExplicitZeroCriticalPolicy() {
        for value in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(QuotaColors.clampedPercent(value), 0)
            XCTAssertEqual(QuotaColors.level(for: value), .critical)
            XCTAssertEqual(QuotaColors.color(for: value).hex, "#FF3B30")
        }

        let account = AccountState(
            id: "C1",
            remainingPercent: .nan,
            status: .normal
        )
        XCTAssertEqual(QuotaDonutState(account: account), .value(0))
    }

    func testAdaptiveTrackColorsRemainExactForBothAppearances() {
        XCTAssertEqual(QuotaColors.trackColor(for: .dark).hex, "#2C2C2E")
        XCTAssertEqual(QuotaColors.trackColor(for: .light).hex, "#E5E5EA")
    }

    func testDonutCenterTextUsesWhiteOnDarkNotchBackground() {
        XCTAssertEqual(QuotaDonutMetrics.centerTextColor(for: .dark).hex, "#FFFFFF")
        XCTAssertEqual(QuotaDonutMetrics.centerTextColor(for: .light).hex, "#000000")
    }

    func testDonutDiameterFollowsMenuBarHeightWithinTwentyToTwentyTwoPoints() {
        XCTAssertEqual(QuotaDonutMetrics.diameter(forMenuBarHeight: 18), 20)
        XCTAssertEqual(QuotaDonutMetrics.diameter(forMenuBarHeight: 24), 22)
        XCTAssertEqual(QuotaDonutMetrics.diameter(forMenuBarHeight: 40), 22)
        XCTAssertEqual(QuotaDonutMetrics.ringWidth, 3.5)
    }

    func testAccountStatusSymbolsAreStableForNonNormalStates() {
        XCTAssertEqual(QuotaDonutState.loading.centerSymbol, nil)
        XCTAssertEqual(QuotaDonutState.loginRequired.centerSymbol, "!")
        XCTAssertEqual(QuotaDonutState.error.centerSymbol, "×")
    }

    func testUnconfiguredAccountHasExplicitNotConfiguredPresentationWithoutQuota() {
        let state = QuotaDonutState(account: AccountState(id: "C1", remainingPercent: 84, status: .notConfigured))

        XCTAssertEqual(state, .notConfigured)
        XCTAssertNil(state.percent)
        XCTAssertNil(state.centerSymbol)
        XCTAssertFalse(state.showsErrorRing)
        XCTAssertEqual(AccountDetailView.statusText(for: .notConfigured), "Not configured")
    }

    func testTimeoutKeepsRemainingValueAndUsesOnlyCriticalRingPresentation() {
        let account = AccountState(
            id: "C1",
            remainingPercent: 84,
            status: .timeout,
            errorMessage: "Codex request timed out"
        )

        let state = QuotaDonutState(account: account)

        XCTAssertEqual(state, .timedOut(84))
        XCTAssertEqual(state.percent, 84)
        XCTAssertNil(state.centerSymbol)
        XCTAssertEqual(state.ringColor, QuotaColors.critical)
        XCTAssertTrue(state.showsErrorRing)
    }

    func testRecoverableErrorKeepsRemainingValueAndTurnsOnlyTheRingRed() {
        let account = AccountState(
            id: "C1",
            remainingPercent: 84,
            status: .error,
            errorMessage: "Codex app-server exited unexpectedly"
        )

        let state = QuotaDonutState(account: account)

        XCTAssertEqual(state, .transientError(84))
        XCTAssertEqual(state.percent, 84)
        XCTAssertNil(state.centerSymbol)
        XCTAssertEqual(state.ringColor, QuotaColors.critical)
        XCTAssertTrue(state.showsErrorRing)
    }

    func testDefinitiveAccountStatesDoNotReuseQuotaValuesInTheDonut() {
        for status in [AccountStatus.loginRequired, .codexNotFound] {
            let account = AccountState(id: "C1", remainingPercent: 84, status: status)
            let state = QuotaDonutState(account: account)

            XCTAssertNil(state.percent)
            XCTAssertFalse(state == .transientError(84))
        }
    }

    func testLoadingAnimationStateStartsOnceAndResetsOnNormalTransition() {
        var state = QuotaLoadingAnimationState()
        XCTAssertEqual(state.transition(isLoading: false), .none)
        XCTAssertEqual(state.transition(isLoading: true), .start)
        XCTAssertEqual(state.transition(isLoading: true), .none)
        XCTAssertEqual(state.startCount, 1)
        XCTAssertEqual(state.transition(isLoading: false), .stop)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.transition(isLoading: true), .start)
        XCTAssertEqual(state.startCount, 2)
    }

    func testClusterFootprintHasNoImplicitPadding() {
        XCTAssertEqual(
            QuotaClusterMetrics.footprint(itemCount: 2, diameter: 22, spacing: 5),
            CGSize(width: 49, height: 22)
        )
        XCTAssertEqual(SettingsView.refreshIntervalOptions, [1, 5, 10, 30])
        XCTAssertEqual(SettingsView.minimumRefreshIntervalMinutes, 1)
        XCTAssertEqual(SettingsView.maximumRefreshIntervalMinutes, 1_440)
        XCTAssertEqual(SettingsView.accountPathCount, 4)
    }

    func testRefreshIntervalDraftDoesNotCommitEmptyTextAndCanonicalizesValues() {
        var draft = SettingsView.RefreshIntervalDraft(value: 5)
        draft.replace(text: "")
        XCTAssertNil(draft.commit())

        draft.replace(text: "7")
        XCTAssertEqual(draft.commit(), 7)
        XCTAssertEqual(draft.text, "7")

        draft.replace(text: "1441")
        XCTAssertEqual(draft.commit(), 1_440)
        XCTAssertEqual(draft.text, "1440")

        draft.replace(text: "0")
        XCTAssertEqual(draft.commit(), 5)
        XCTAssertEqual(draft.text, "5")
    }

    func testRefreshIntervalDraftDoesNotCommitPartialOrNonNumericText() {
        var draft = SettingsView.RefreshIntervalDraft(value: 5)

        for partial in ["-", "1x", "   ", ""] {
            draft.replace(text: partial)
            XCTAssertNil(draft.commit(), "partial input (partial.debugDescription) must remain a draft")
            XCTAssertEqual(draft.text, partial)
        }
    }

    func testAccountLabelsAreOptInAcrossCompactPresentationAndSettingsBindings() {
        let account = AccountState(
            id: "C1",
            remainingPercent: 80,
            status: .normal
        )

        let compactDonut = QuotaDonutView(account: account)
        XCTAssertFalse(compactDonut.showAccountLabels)

        let labeledDonut = QuotaDonutView(account: account, showAccountLabels: true)
        XCTAssertTrue(labeledDonut.showAccountLabels)

        let compactCluster = QuotaClusterView(accounts: [account], side: .left)
        XCTAssertFalse(compactCluster.showAccountLabels)

        let labeledCluster = QuotaClusterView(
            accounts: [account],
            side: .left,
            showAccountLabels: true
        )
        XCTAssertTrue(labeledCluster.showAccountLabels)

        let settings = SettingsView(
            refreshIntervalMinutes: .constant(5),
            accountPaths: .constant(["", "", "", ""]),
            launchAtLogin: .constant(false),
            showAccountLabels: .constant(true)
        )
        XCTAssertTrue(settings.showAccountLabels)
    }

    func testCompactValueTextUsesDigitsOnlyForEveryBoundaryWidth() {
        let cases: [(Double, String)] = [
            (0, "0"),
            (9, "9"),
            (99, "99"),
            (100, "100")
        ]

        for (value, expected) in cases {
            let text = QuotaDonutMetrics.compactValueText(value)
            XCTAssertEqual(text, expected, "compact value (value)")
            XCTAssertFalse(text.contains("%"))
        }
    }

    func testSettingsContentContractKeepsRefreshAndLaunchControlsNamed() {
        XCTAssertEqual(SettingsView.refreshSectionTitle, "Refresh")
        XCTAssertEqual(SettingsView.launchAtLoginLabel, "Launch at login")
        XCTAssertEqual(SettingsView.refreshIntervalOptions, [1, 5, 10, 30])
    }

    func testSettingsPresentationFallsBackOnlyWhenActionIsUnhandledAndReusesFallback() {
        XCTAssertEqual(
            SettingsWindowPresentationPolicy.route(actionHandled: true, hasFallbackWindow: false),
            .focusSettingsScene
        )
        XCTAssertEqual(
            SettingsWindowPresentationPolicy.route(actionHandled: false, hasFallbackWindow: false),
            .createFallback
        )
        XCTAssertEqual(
            SettingsWindowPresentationPolicy.route(actionHandled: false, hasFallbackWindow: true),
            .focusExistingFallback
        )
        XCTAssertEqual(
            SettingsWindowPresentationPolicy.route(actionHandled: true, hasFallbackWindow: true),
            .focusExistingFallback
        )
    }

    func testLogicalAccountSpacingIsEightPointsAndAddsOnlyThreeToTwoAccountWidth() {
        XCTAssertEqual(QuotaDonutMetrics.accountSpacing, 8)

        let layout = NotchGeometry.layout(
            screenFrame: CGRect(x: 0, y: 0, width: 1_800, height: 1_169),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 1_131, width: 850, height: 38),
            auxiliaryTopRightArea: CGRect(x: 950, y: 1_131, width: 850, height: 38)
        )
        let fivePointContent = layout.contentFrame(side: .left, itemCount: 2, diameter: 22, spacing: 5)
        let logicalContent = layout.contentFrame(side: .left, itemCount: 2, diameter: 22)
        let fivePointPanel = layout.panelFrame(side: .left, itemCount: 2, diameter: 22, spacing: 5)
        let logicalPanel = layout.panelFrame(side: .left, itemCount: 2, diameter: 22)

        XCTAssertEqual(logicalContent.width - fivePointContent.width, 3, accuracy: 0.0001)
        XCTAssertEqual(logicalPanel.width - fivePointPanel.width, 3, accuracy: 0.0001)
        XCTAssertEqual(logicalPanel.width - logicalContent.width, QuotaClusterMetrics.notchBridgeWidth, accuracy: 0.0001)
    }

    func testEightPointSpacingStillContainsBothRingsInNarrowAreas() {
        let layout = NotchGeometry.layout(
            screenFrame: CGRect(x: 0, y: 0, width: 300, height: 900),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 876, width: 50, height: 24),
            auxiliaryTopRightArea: CGRect(x: 250, y: 876, width: 50, height: 24)
        )

        for side in [NotchSide.left, .right] {
            let area = side == .left ? layout.leftArea : layout.rightArea
            let diameter = layout.resolvedDiameter(side: side, itemCount: 2, diameter: 22)
            let content = layout.contentFrame(side: side, itemCount: 2, diameter: 22)
            let items = layout.itemFrames(side: side, itemCount: 2, diameter: 22)
            let inset = QuotaClusterMetrics.visualInset(forDiameter: diameter)

            XCTAssertLessThan(diameter, 22)
            XCTAssertEqual(items.count, 2)
            XCTAssertTrue(area.contains(content))
            XCTAssertTrue(items.allSatisfy {
                area.contains($0.insetBy(dx: -inset, dy: -inset))
            })
        }
    }

    func testNotchActivityToastUsesSafeTwoLineCopyAndShortSessionID() {
        let transition = SessionActivityTransition(
            accountID: "C4",
            side: .right,
            sessionID: "019fe59b123456",
            agentLabel: "Worker",
            taskName: "Settings window fix",
            status: .working
        )
        let toast = SessionActivityToast(
            content: .transition(transition),
            durationSeconds: 5
        )

        let copy = NotchActivityToastCopy.make(for: toast)
        XCTAssertEqual(copy.firstLine, "C4 · Session 019fe59b...")
        XCTAssertEqual(copy.secondLine, "Worker · Settings window fix · Working")
        XCTAssertEqual(copy.lines.count, 2)
        XCTAssertFalse(copy.lines.joined(separator: " ").contains(transition.sessionID!))
    }

    func testNotchActivityToastUsesFallbacksAndCountOnlyOverflowCopy() {
        let transition = SessionActivityTransition(
            accountID: "C1",
            side: .left,
            sessionID: nil,
            agentLabel: nil,
            taskName: nil,
            status: .unknown
        )
        let fallback = NotchActivityToastCopy.make(
            for: SessionActivityToast(content: .transition(transition), durationSeconds: 5)
        )
        XCTAssertEqual(fallback.firstLine, "C1")
        XCTAssertEqual(fallback.secondLine, "Agent · Unknown")

        let overflow = NotchActivityToastCopy.make(
            for: SessionActivityToast(content: .overflow(count: 3), durationSeconds: 5)
        )
        XCTAssertEqual(overflow.lines, ["3 more activity updates"])
        XCTAssertFalse(overflow.lines.joined(separator: " ").contains("Session"))
        XCTAssertFalse(overflow.lines.joined(separator: " ").contains("Worker"))
    }

    func testNotchActivityToastAnimationPolicyUsesFixedDurationsAndReduceMotionFade() {
        XCTAssertEqual(NotchActivityToastView.entryAnimationDuration, 0.2)
        XCTAssertEqual(NotchActivityToastView.exitAnimationDuration, 0.25)
        XCTAssertEqual(
            NotchActivityToastPresentation.animationDuration(isPresented: true),
            0.2
        )
        XCTAssertEqual(
            NotchActivityToastPresentation.animationDuration(isPresented: false),
            0.25
        )
        XCTAssertTrue(NotchActivityToastPresentation.usesSlide(reduceMotion: false))
        XCTAssertFalse(NotchActivityToastPresentation.usesSlide(reduceMotion: true))
        XCTAssertTrue(
            NotchActivityToastPresentation.shouldShimmer(status: .working, reduceMotion: false)
        )
        XCTAssertFalse(
            NotchActivityToastPresentation.shouldShimmer(status: .working, reduceMotion: true)
        )
        XCTAssertFalse(
            NotchActivityToastPresentation.shouldShimmer(status: .completed, reduceMotion: false)
        )
    }

    func testNotchActivityToastWidthIsFiniteAndOverflowRemainsCompact() {
        let transition = SessionActivityTransition(
            accountID: "C2",
            side: .left,
            sessionID: "short-session",
            agentLabel: "Agent",
            taskName: "A bounded task",
            status: .working
        )
        let regular = SessionActivityToast(content: .transition(transition), durationSeconds: 5)
        let overflow = SessionActivityToast(content: .overflow(count: 4), durationSeconds: 5)

        XCTAssertGreaterThan(NotchActivityToastMetrics.requiredWidth(for: regular), 0)
        XCTAssertLessThan(
            NotchActivityToastMetrics.requiredWidth(for: overflow),
            NotchActivityToastMetrics.requiredWidth(for: regular)
        )
        XCTAssertTrue(
            NotchActivityToastMetrics.requiredWidth(for: regular).isFinite
                && NotchActivityToastMetrics.requiredWidth(for: overflow).isFinite
        )
    }

    func testActivityToastPresentationLifecycleUsesEntryExitAndFinalRemovalOrdering() async {
        let clock = ManualPresentationSleeper()
        let model = NotchActivityPresentationModel(sleep: { duration in
            await clock.sleep(duration)
        })
        let first = makeActivityToast(
            accountID: "C1",
            side: .left,
            sessionID: "first",
            taskName: "First"
        )
        let second = makeActivityToast(
            accountID: "C1",
            side: .left,
            sessionID: "second",
            taskName: "Second"
        )

        model.setToast(first, width: 80)
        XCTAssertEqual(model.displayedToast?.id, first.id)
        XCTAssertEqual(model.phase, .entering)
        XCTAssertEqual(
            model.events,
            [.entry(id: first.id, duration: NotchActivityToastView.entryAnimationDuration)]
        )

        await yieldToPresentationTask()
        XCTAssertEqual(model.phase, .entering)
        await clock.releaseNext()
        await yieldToPresentationTask()
        XCTAssertEqual(model.phase, .visible)

        model.setToast(second, width: 96)
        XCTAssertEqual(model.displayedToast?.id, first.id)
        XCTAssertEqual(model.displayedWidth, 80)
        XCTAssertEqual(model.phase, .exiting)
        XCTAssertEqual(
            model.events,
            [
                .entry(id: first.id, duration: 0.2),
                .exit(id: first.id, duration: 0.25),
            ]
        )

        await yieldToPresentationTask()
        XCTAssertEqual(model.displayedToast?.id, first.id)
        XCTAssertEqual(model.phase, .exiting)

        await clock.releaseNext()
        await yieldToPresentationTask()
        XCTAssertEqual(model.displayedToast?.id, second.id)
        XCTAssertEqual(model.displayedWidth, 96)
        XCTAssertEqual(model.phase, .entering)
        XCTAssertEqual(
            model.events,
            [
                .entry(id: first.id, duration: 0.2),
                .exit(id: first.id, duration: 0.25),
                .entry(id: second.id, duration: 0.2),
            ]
        )

        await clock.releaseNext()
        await yieldToPresentationTask()
        XCTAssertEqual(model.phase, .visible)

        model.setToast(nil)
        XCTAssertEqual(model.displayedToast?.id, second.id)
        XCTAssertEqual(model.displayedWidth, 96)
        XCTAssertEqual(model.phase, .exiting)
        await yieldToPresentationTask()
        await clock.releaseNext()
        await yieldToPresentationTask()
        XCTAssertNil(model.displayedToast)
        XCTAssertNil(model.displayedWidth)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(
            model.events.last,
            .removed(id: second.id)
        )
    }

    func testActivityToastPresentationGenerationDropsRapidStaleTargets() async {
        let model = NotchActivityPresentationModel(sleep: { _ in })
        let first = makeActivityToast(
            accountID: "C2",
            side: .right,
            sessionID: "first",
            taskName: "First"
        )
        let stale = makeActivityToast(
            accountID: "C2",
            side: .right,
            sessionID: "stale",
            taskName: "Stale"
        )
        let final = makeActivityToast(
            accountID: "C2",
            side: .right,
            sessionID: "final",
            taskName: "Final"
        )

        model.setToast(first)
        model.setToast(stale)
        model.setToast(final)
        await yieldToPresentationTask()
        XCTAssertEqual(model.displayedToast?.id, final.id)
        XCTAssertFalse(model.events.contains { event in
            if case let .entry(id, _) = event { return id == stale.id }
            return false
        })
    }

    private func makeActivityToast(
        accountID: String,
        side: AccountPosition,
        sessionID: String,
        taskName: String
    ) -> SessionActivityToast {
        SessionActivityToast(
            content: .transition(
                SessionActivityTransition(
                    accountID: accountID,
                    side: side,
                    sessionID: sessionID,
                    agentLabel: "Worker",
                    taskName: taskName,
                    status: .working
                )
            ),
            durationSeconds: 5
        )
    }

    private func yieldToPresentationTask() async {
        for _ in 0..<4 {
            await Task.yield()
        }
    }
}

private actor PresentationSleepGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var requestedDurations: [TimeInterval] = []

    func sleep(_ duration: TimeInterval) async {
        requestedDurations.append(duration)
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitUntilEntered() async {
        for _ in 0..<100 {
            if !continuations.isEmpty { return }
            await Task.yield()
        }
    }

    func release() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private actor ManualPresentationSleeper {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func sleep(_ duration: TimeInterval) async {
        _ = duration
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func releaseNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}

private actor ActivityRefreshRecorder {
    private var snapshots: [SessionActivitySnapshot]
    private var loaded = 0
    private var delivered = 0
    private var concurrentLoads = 0
    private(set) var maxConcurrentLoads = 0
    private(set) var sleepIntervals: [TimeInterval] = []

    init(snapshots: [SessionActivitySnapshot]) {
        self.snapshots = snapshots
    }

    func nextSnapshot() -> SessionActivitySnapshot {
        loaded += 1
        concurrentLoads += 1
        maxConcurrentLoads = max(maxConcurrentLoads, concurrentLoads)
        defer { concurrentLoads -= 1 }
        return snapshots.isEmpty ? .unavailable(accountID: "C1") : snapshots.removeFirst()
    }

    func recordSleep(_ interval: TimeInterval) {
        sleepIntervals.append(interval)
    }

    func recordDelivered(_ snapshot: SessionActivitySnapshot) {
        _ = snapshot
        delivered += 1
    }

    var sleepCount: Int { sleepIntervals.count }
    var loadedCount: Int { loaded }
    var deliveredCount: Int { delivered }
}
