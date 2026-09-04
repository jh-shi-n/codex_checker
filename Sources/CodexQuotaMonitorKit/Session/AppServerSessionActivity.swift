import Foundation

/// Capability result for the installed app-server protocol. The current CLI
/// exposes list/resume and lifecycle notification schemas, but its documented
/// launch/proxy surface does not prove that a separate monitor process can
/// attach to and subscribe to an already-running Codex process.
public enum AppServerActivityCapability: Equatable, Sendable {
    case unavailable(reason: String)

    /// The installed protocol/help result used by the app. Keep this explicit
    /// so an unproven live feed can never silently replace SQLite recovery.
    public static let installedProtocol = AppServerActivityCapability.unavailable(
        reason: "cross-process app-server observation is not capability-proven"
    )

    public var supportsLiveObservation: Bool {
        if case .unavailable = self { return false }
        return true
    }

    public var reason: String {
        switch self {
        case let .unavailable(reason):
            return reason
        }
    }
}

/// Fallback-preserving provider seam for a future capability-proven client.
/// With the installed protocol this provider always delegates to the bounded
/// SQLite projection and never pretends that a second app-server process is a
/// live observer of another process.
public struct AppServerSessionActivityProvider: SessionActivityProvider, Sendable {
    public let capability: AppServerActivityCapability

    private let fallback: any SessionActivityProvider
    private let liveSnapshot: (@Sendable (String, URL) async -> SessionActivitySnapshot?)?

    public init(
        fallback: any SessionActivityProvider,
        capability: AppServerActivityCapability = .installedProtocol,
        liveSnapshot: (@Sendable (String, URL) async -> SessionActivitySnapshot?)? = nil
    ) {
        self.fallback = fallback
        self.capability = capability
        self.liveSnapshot = liveSnapshot
    }

    public func snapshot(accountID: String, home: URL) async -> SessionActivitySnapshot {
        guard capability.supportsLiveObservation,
              let liveSnapshot,
              let live = await liveSnapshot(accountID, home),
              live.accountID == accountID else {
            return await fallback.snapshot(accountID: accountID, home: home)
        }
        return live
    }
}

/// Public lifecycle metadata reducer for a future attached app-server stream.
/// It reads only stable protocol fields: thread title/role/nickname/status,
/// recency, plan-step status/text, and an item type mapped to a fixed category.
/// All other fields—including IDs beyond internal relation keys—are ignored.
public struct AppServerActivityEventReducer: Sendable {
    public let accountID: String

    private var records: [String: Record] = [:]
    private var activeOperationItemIDs: [String: String] = [:]

    public init(accountID: String) {
        self.accountID = accountID
    }

    public mutating func reduce(_ message: CodexMessage) {
        guard let method = message.method,
              let params = message.params?.objectValue else { return }

        switch method {
        case "thread/started":
            reduceThreadStarted(params)
        case "thread/status/changed":
            reduceThreadStatusChanged(params)
        case "thread/archived", "thread/deleted":
            markInactive(threadID: string(params["threadId"]))
        case "turn/started":
            updateRecord(threadID: string(params["threadId"])) { record in
                record.status = .working
                record.isActive = true
            }
        case "turn/completed":
            reduceTurnCompleted(params)
        case "turn/plan/updated":
            reducePlanUpdate(params)
        case "item/started":
            reduceItemStarted(params)
        case "item/completed":
            reduceItemCompleted(params)
        default:
            // Reasoning, transcript, prompt, message, command-output, patch,
            // and unknown notifications are intentionally ignored wholesale.
            return
        }
    }

    public func snapshot() -> SessionActivitySnapshot {
        let roots = records.values.filter { $0.parentThreadID == nil }
        guard !roots.isEmpty else {
            return .empty(accountID: accountID, source: .liveAppServer)
        }

        let sessions = SessionActivityMainSession.ordered(roots.map { root in
            let descendants = descendantRecords(of: root.id)
            let agents = descendants.map { record in
                SessionActivityAgent(
                    threadID: record.id,
                    parentThreadID: record.parentThreadID,
                    taskName: record.title ?? "Agent",
                    status: record.status,
                    displayName: record.displayName
                )
            }
            let status = effectiveRootStatus(root: root, descendants: descendants)
            return SessionActivityMainSession(
                threadID: root.id,
                source: .liveAppServer,
                taskName: root.title ?? "Codex session",
                status: status,
                agents: agents,
                isActive: root.isActive || descendants.contains(where: \.isActive),
                planStep: root.planStep,
                activeOperation: root.activeOperation,
                lastActivityAt: root.lastActivityAt
            )
        })

        let first = sessions[0]
        return SessionActivitySnapshot(
            accountID: accountID,
            state: .available,
            source: .liveAppServer,
            sessionID: first.threadID,
            status: first.status,
            agents: first.agents,
            sessions: sessions
        )
    }

    private mutating func reduceThreadStarted(_ params: [String: CodexJSONValue]) {
        guard let thread = params["thread"]?.objectValue,
              let id = string(thread["id"]) else { return }

        let status = mapThreadStatus(thread["status"])
        let previous = records[id]
        records[id] = Record(
            id: id,
            parentThreadID: string(thread["parentThreadId"]),
            title: SessionActivityMetadataSanitizer.text(string(thread["name"]))
                ?? previous?.title,
            displayName: SessionActivityMetadataSanitizer.text(string(thread["agentNickname"]))
                ?? SessionActivityMetadataSanitizer.text(string(thread["agentRole"]))
                ?? previous?.displayName
                ?? "Agent",
            status: status.status,
            isActive: status.isActive,
            planStep: previous?.planStep,
            activeOperation: previous?.activeOperation,
            lastActivityAt: date(thread["recencyAt"]) ?? date(thread["updatedAt"])
                ?? previous?.lastActivityAt
        )
    }

    private mutating func reduceThreadStatusChanged(_ params: [String: CodexJSONValue]) {
        let threadID = string(params["threadId"])
        let mapped = mapThreadStatus(params["status"])
        updateRecord(threadID: threadID) { record in
            record.status = mapped.status
            record.isActive = mapped.isActive
        }
    }

    private mutating func reduceTurnCompleted(_ params: [String: CodexJSONValue]) {
        let threadID = string(params["threadId"])
        let turnStatus = params["turn"]?.objectValue?["status"].flatMap(string)
        let status: SessionActivityStatus
        switch turnStatus {
        case "failed":
            status = .error
        case "interrupted":
            status = .stopped
        case "inProgress":
            status = .working
        default:
            status = .completed
        }
        updateRecord(threadID: threadID) { record in
            record.status = status
            record.isActive = status.isOpen
        }
    }

    private mutating func reducePlanUpdate(_ params: [String: CodexJSONValue]) {
        guard let threadID = string(params["threadId"]),
              let plan = params["plan"]?.arrayValue else { return }

        let preferred = plan.compactMap { step -> (String, String)? in
            guard let object = step.objectValue,
                  let status = string(object["status"]),
                  let text = SessionActivityMetadataSanitizer.text(string(object["step"])) else {
                return nil
            }
            return (status, text)
        }
        let selected = preferred.first(where: { $0.0 == "inProgress" })
            ?? preferred.first(where: { $0.0 == "pending" })
            ?? preferred.first(where: { $0.0 == "completed" })

        updateRecord(threadID: threadID) { record in
            record.planStep = selected?.1
        }
    }

    private mutating func reduceItemStarted(_ params: [String: CodexJSONValue]) {
        guard let threadID = string(params["threadId"]),
              let item = params["item"]?.objectValue,
              let itemID = string(item["id"]),
              let category = SessionActivityOperationCategory.normalize(raw: string(item["type"])) else {
            return
        }
        activeOperationItemIDs[itemID] = threadID
        updateRecord(threadID: threadID) { record in
            record.activeOperation = category
            record.isActive = true
            if record.status == .unknown || record.status == .completed {
                record.status = .working
            }
        }
    }

    private mutating func reduceItemCompleted(_ params: [String: CodexJSONValue]) {
        guard let item = params["item"]?.objectValue,
              let itemID = string(item["id"]),
              let threadID = activeOperationItemIDs.removeValue(forKey: itemID) else {
            return
        }
        updateRecord(threadID: threadID) { record in
            record.activeOperation = nil
        }
    }

    private mutating func markInactive(threadID: String?) {
        updateRecord(threadID: threadID) { record in
            record.isActive = false
            if record.status == .working || record.status == .waiting {
                record.status = .completed
            }
        }
    }

    private mutating func updateRecord(
        threadID: String?,
        update: (inout Record) -> Void
    ) {
        guard let threadID else { return }
        var record = records[threadID] ?? Record(
            id: threadID,
            parentThreadID: nil,
            title: nil,
            displayName: "Agent",
            status: .unknown,
            isActive: true,
            planStep: nil,
            activeOperation: nil,
            lastActivityAt: nil
        )
        update(&record)
        records[threadID] = record
    }

    private func descendantRecords(of rootID: String) -> [Record] {
        var queue = [rootID]
        var visited: Set<String> = [rootID]
        var descendants: [Record] = []

        while !queue.isEmpty {
            let parentID = queue.removeFirst()
            let children = records.values
                .filter { $0.parentThreadID == parentID && !visited.contains($0.id) }
                .sorted { $0.id < $1.id }
            for child in children {
                visited.insert(child.id)
                descendants.append(child)
                queue.append(child.id)
            }
        }
        return descendants
    }

    private func effectiveRootStatus(root: Record, descendants: [Record]) -> SessionActivityStatus {
        if root.status == .working || descendants.contains(where: { $0.status == .working }) {
            return .working
        }
        if root.status == .waiting || descendants.contains(where: { $0.status == .waiting }) {
            return .waiting
        }
        return root.status
    }

    private func mapThreadStatus(_ value: CodexJSONValue?) -> (status: SessionActivityStatus, isActive: Bool) {
        guard let object = value?.objectValue,
              let type = string(object["type"]) else {
            return (.unknown, true)
        }
        switch type {
        case "active":
            let flags = object["activeFlags"]?.arrayValue?.compactMap(string) ?? []
            return (flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput")
                    ? .waiting : .working, true)
        case "systemError":
            return (.error, false)
        case "idle":
            return (.completed, false)
        case "notLoaded":
            return (.unknown, false)
        default:
            return (.unknown, true)
        }
    }

    private func string(_ value: CodexJSONValue?) -> String? {
        value?.stringValue
    }

    private func date(_ value: CodexJSONValue?) -> Date? {
        guard let seconds = value?.numberValue, seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private struct Record: Sendable {
        let id: String
        let parentThreadID: String?
        var title: String?
        var displayName: String
        var status: SessionActivityStatus
        var isActive: Bool
        var planStep: String?
        var activeOperation: String?
        var lastActivityAt: Date?
    }
}

public typealias CodexAppServerActivityReducer = AppServerActivityEventReducer
public typealias LiveSessionActivityProvider = AppServerSessionActivityProvider
