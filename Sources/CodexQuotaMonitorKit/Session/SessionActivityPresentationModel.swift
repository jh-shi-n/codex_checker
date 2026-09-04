import Foundation
import Combine

/// A session row retained by the presentation layer while its root is
/// departing. The raw thread ID is used only as an internal identity key.
public struct SessionActivityPresentationItem: Identifiable, Equatable, Sendable {
    public let session: SessionActivityMainSession
    public let isDeparting: Bool

    public var id: String { session.threadID }
    public var opacity: Double { isDeparting ? 0.45 : 1 }
    public var source: SessionActivitySource { session.source }
    public var taskName: String { session.taskName }
    public var title: String { session.title }
    public var status: SessionActivityStatus { session.status }
    public var agents: [SessionActivityAgent] { session.agents }
    public var planStep: String? { session.planStep }
    public var activeOperation: String? { session.activeOperation }
    public var lastActivityAt: Date? { session.lastActivityAt }

    public init(session: SessionActivityMainSession, isDeparting: Bool = false) {
        self.session = session
        self.isDeparting = isDeparting
    }
}

public typealias PresentedSessionActivity = SessionActivityPresentationItem
public typealias SessionActivityPresentationState = SessionActivityPresentationModel

/// Main-actor lifecycle state for local activity rows.
///
/// A missing or explicitly inactive root is retained at reduced opacity and
/// removed exactly five seconds later. A fresh active snapshot for the same
/// root cancels the pending removal and restores full opacity.
@MainActor
public final class SessionActivityPresentationModel: ObservableObject {
    public static let departureDuration: TimeInterval = 5

    @Published public private(set) var sessions: [SessionActivityPresentationItem] = []

    private let sleep: @Sendable (TimeInterval) async -> Void
    private var removalTasks: [String: Task<Void, Never>] = [:]
    private var removalGenerations: [String: Int] = [:]

    public init(
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.sleep = sleep
    }

    public var items: [SessionActivityPresentationItem] { sessions }
    public var presentedSessions: [SessionActivityPresentationItem] { sessions }

    public static func orderedSessions(
        _ sessions: [SessionActivityMainSession]
    ) -> [SessionActivityMainSession] {
        SessionActivityMainSession.ordered(sessions)
    }

    public func apply(_ snapshot: SessionActivitySnapshot) {
        update(snapshot: snapshot)
    }

    public func update(snapshot: SessionActivitySnapshot) {
        switch snapshot.state {
        case .unavailable:
            // A failed read is not evidence of termination. Keep the last
            // known rows and wait for a readable snapshot.
            return
        case .empty, .available:
            update(sessions: snapshot.sessions)
        }
    }

    public func update(sessions incoming: [SessionActivityMainSession]) {
        var uniqueIncoming: [SessionActivityMainSession] = []
        var incomingIDs: Set<String> = []
        for session in incoming where incomingIDs.insert(session.threadID).inserted {
            uniqueIncoming.append(session)
        }
        let incomingByID = Dictionary(
            uniqueIncoming.map { ($0.threadID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var updated: [SessionActivityPresentationItem] = []
        var seenIDs: Set<String> = []

        for current in sessions where seenIDs.insert(current.id).inserted {
            let id = current.id
            if let replacement = incomingByID[id], replacement.isActive {
                cancelRemoval(for: id)
                updated.append(SessionActivityPresentationItem(session: replacement))
            } else if let replacement = incomingByID[id] {
                updated.append(SessionActivityPresentationItem(session: replacement, isDeparting: true))
                scheduleRemoval(for: replacement)
            } else {
                updated.append(SessionActivityPresentationItem(session: current.session, isDeparting: true))
                scheduleRemoval(for: current.session)
            }
        }

        for session in uniqueIncoming where seenIDs.insert(session.id).inserted {
            if session.isActive {
                cancelRemoval(for: session.id)
                updated.append(SessionActivityPresentationItem(session: session))
            } else {
                updated.append(SessionActivityPresentationItem(session: session, isDeparting: true))
                scheduleRemoval(for: session)
            }
        }

        self.sessions = updated.sorted { lhs, rhs in
            let ordered = Self.orderedSessions([lhs.session, rhs.session])
            guard let first = ordered.first else { return false }
            if first.threadID != lhs.session.threadID {
                return false
            }
            return lhs.session.threadID != rhs.session.threadID
        }
    }

    public func reset() {
        for task in removalTasks.values { task.cancel() }
        removalTasks.removeAll()
        removalGenerations.removeAll()
        sessions.removeAll()
    }

    private func scheduleRemoval(for session: SessionActivityMainSession) {
        let id = session.threadID
        guard removalTasks[id] == nil else { return }
        let generation = (removalGenerations[id] ?? 0) + 1
        removalGenerations[id] = generation
        let sleep = self.sleep
        removalTasks[id] = Task { [weak self] in
            await sleep(Self.departureDuration)
            guard !Task.isCancelled else { return }
            self?.finishRemoval(id: id, generation: generation)
        }
    }

    private func cancelRemoval(for id: String) {
        removalTasks[id]?.cancel()
        removalTasks[id] = nil
        removalGenerations[id, default: 0] += 1
    }

    private func finishRemoval(id: String, generation: Int) {
        guard removalGenerations[id] == generation else { return }
        removalTasks[id] = nil
        sessions.removeAll { $0.id == id && $0.isDeparting }
    }
}
