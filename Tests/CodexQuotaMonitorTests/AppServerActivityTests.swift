import XCTest
@testable import CodexQuotaMonitorKit

@MainActor
final class AppServerActivityTests: XCTestCase {
    func testCapabilityProbeRefusesUnprovenCrossProcessObservation() {
        let capability = AppServerActivityCapability.installedProtocol

        XCTAssertFalse(capability.supportsLiveObservation)
        XCTAssertTrue(capability.reason.contains("cross-process"))
    }

    func testUnavailableAppServerProviderKeepsSQLiteFallback() async {
        let fallback = StaticSessionActivityProvider(
            snapshotValue: SessionActivitySnapshot(
                accountID: "C1",
                state: .available,
                sessions: [
                    SessionActivityMainSession(
                        threadID: "root",
                        source: .localActivity,
                        taskName: "Fallback session",
                        status: .working,
                        agents: []
                    ),
                ]
            )
        )
        let provider = AppServerSessionActivityProvider(
            fallback: fallback,
            capability: .installedProtocol
        )

        let snapshot = await provider.snapshot(
            accountID: "C1",
            home: URL(fileURLWithPath: "/unused")
        )

        XCTAssertEqual(snapshot.sessions.map(\.taskName), ["Fallback session"])
        XCTAssertEqual(provider.capability, .installedProtocol)
    }

    func testReducerUsesOnlySafePublicLifecycleMetadata() {
        var reducer = AppServerActivityEventReducer(accountID: "C1")
        reducer.reduce(CodexMessage(
            method: "thread/started",
            params: .object([
                "thread": .object([
                    "id": .string("root"),
                    "name": .string("Settings window fix"),
                    "preview": .string("the user prompt must never appear"),
                    "path": .string("/private/secret-rollout"),
                    "status": .object(["type": .string("active"), "activeFlags": .array([])]),
                    "recencyAt": .number(2_000_000),
                ]),
            ])
        ))
        reducer.reduce(CodexMessage(
            method: "turn/plan/updated",
            params: .object([
                "threadId": .string("root"),
                "turnId": .string("turn"),
                "explanation": .string("reasoning summary must not appear"),
                "plan": .array([
                    .object([
                        "status": .string("inProgress"),
                        "step": .string("Verify settings behavior"),
                    ]),
                ]),
            ])
        ))
        reducer.reduce(CodexMessage(
            method: "item/started",
            params: .object([
                "threadId": .string("root"),
                "turnId": .string("turn"),
                "item": .object([
                    "id": .string("item"),
                    "type": .string("commandExecution"),
                    "command": .string("cat /private/secret"),
                    "aggregatedOutput": .string("command output must not appear"),
                ]),
            ])
        ))

        let snapshot = reducer.snapshot()
        let session = snapshot.sessions[0]
        XCTAssertEqual(session.title, "Settings window fix")
        XCTAssertEqual(session.planStep, "Verify settings behavior")
        XCTAssertEqual(session.activeOperation, "Command")
        XCTAssertFalse(session.title.contains("prompt"))
        XCTAssertFalse(session.title.contains("private"))
        XCTAssertFalse(session.planStep?.contains("reasoning") == true)
        XCTAssertFalse(session.activeOperation?.contains("secret") == true)
    }

    func testActiveDescendantOverridesKnownTerminalRootStatus() {
        for (activeFlags, expectedStatus) in [
            ([], SessionActivityStatus.working),
            (["waitingOnUserInput"], SessionActivityStatus.waiting),
        ] as [([String], SessionActivityStatus)] {
            var reducer = AppServerActivityEventReducer(accountID: "C1")
            reducer.reduce(CodexMessage(
                method: "thread/started",
                params: .object([
                    "thread": .object([
                        "id": .string("root"),
                        "name": .string("Main session"),
                        "status": .object(["type": .string("idle")]),
                    ]),
                ])
            ))
            reducer.reduce(CodexMessage(
                method: "thread/started",
                params: .object([
                    "thread": .object([
                        "id": .string("child"),
                        "parentThreadId": .string("root"),
                        "name": .string("Subagent task"),
                        "status": .object([
                            "type": .string("active"),
                            "activeFlags": .array(activeFlags.map(CodexJSONValue.string)),
                        ]),
                    ]),
                ])
            ))

            let session = reducer.snapshot().sessions.first
            XCTAssertEqual(session?.status, expectedStatus)
            XCTAssertEqual(session?.isActive, true)
        }
    }

    func testCardsSortWorkingThenWaitingThenMostRecentAndKeepInactiveAgents() {
        let sessions = [
            SessionActivityMainSession(
                threadID: "waiting",
                source: .localActivity,
                taskName: "Waiting",
                status: .waiting,
                agents: [],
                isActive: true,
                lastActivityAt: Date(timeIntervalSince1970: 2_000_100)
            ),
            SessionActivityMainSession(
                threadID: "working",
                source: .localActivity,
                taskName: "Working",
                status: .working,
                agents: [
                    SessionActivityAgent(
                        threadID: "done-agent",
                        parentThreadID: "working",
                        taskName: "Completed subtask",
                        status: .completed,
                        displayName: "Worker"
                    ),
                ],
                isActive: true,
                lastActivityAt: Date(timeIntervalSince1970: 1_000)
            ),
            SessionActivityMainSession(
                threadID: "recent-complete",
                source: .localActivity,
                taskName: "Recent",
                status: .completed,
                agents: [],
                isActive: true,
                lastActivityAt: Date(timeIntervalSince1970: 2_000_200)
            ),
        ]

        let ordered = SessionActivityPresentationModel.orderedSessions(sessions)

        XCTAssertEqual(ordered.map(\.threadID), ["working", "waiting", "recent-complete"])
        XCTAssertEqual(ordered[0].agents.map(\.displayName), ["Worker"])
    }

    func testActivitySectionIsBadgeFreeAndBoundsCardList() {
        XCTAssertNil(SessionActivitySource.cli.badgeText)
        XCTAssertNil(SessionActivitySource.codexApp.badgeText)
        XCTAssertGreaterThan(CLIActivitySection.cardListMaxHeight, 0)
        XCTAssertEqual(CLIActivitySection.cardListAxis, .vertical)
    }
}

private struct StaticSessionActivityProvider: SessionActivityProvider {
    let snapshotValue: SessionActivitySnapshot

    func snapshot(accountID: String, home: URL) async -> SessionActivitySnapshot {
        snapshotValue
    }
}
