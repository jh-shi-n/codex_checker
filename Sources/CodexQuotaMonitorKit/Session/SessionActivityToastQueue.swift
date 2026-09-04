import Combine
import Foundation

/// One displayable activity message. A summary contains only a count and no
/// discarded transition data, so overflow never retains private payloads.
public struct SessionActivityToast: Equatable, Identifiable, Sendable {
    public enum Content: Equatable, Sendable {
        case transition(SessionActivityTransition)
        case overflow(count: Int)

        public static func summary(count: Int) -> Content {
            .overflow(count: count)
        }
    }

    public let content: Content
    public let durationSeconds: Int

    public init(content: Content, durationSeconds: Int) {
        self.content = content
        self.durationSeconds = PreferencesStore.normalizedActivityNotificationDurationSeconds(
            durationSeconds
        )
    }

    public var id: String {
        switch content {
        case let .transition(transition):
            return "transition:\(transition.id)"
        case let .overflow(count):
            return "overflow:\(count)"
        }
    }

    public var transition: SessionActivityTransition? {
        guard case let .transition(transition) = content else { return nil }
        return transition
    }

    public var isOverflowSummary: Bool {
        if case .overflow = content { return true }
        return false
    }

    public var isSummary: Bool { isOverflowSummary }

    public var overflowCount: Int? {
        guard case let .overflow(count) = content else { return nil }
        return count
    }

    public var summaryCount: Int? { overflowCount }

    public var duration: TimeInterval {
        TimeInterval(durationSeconds)
    }

    public var displayText: String {
        switch content {
        case let .transition(transition):
            return transition.taskName
                ?? transition.agentLabel
                ?? "\(transition.accountID) activity"
        case let .overflow(count):
            return "\(count) more activity updates"
        }
    }
}

/// Main-actor queue with one independent FIFO lane for each notch side.
/// Current messages are held for the configured duration; entry/exit animation
/// remains a responsibility of the presentation layer.
@MainActor
public final class SessionActivityToastQueue: ObservableObject {
    public static let maximumPendingCount = 3

    @Published public private(set) var currentLeft: SessionActivityToast?
    @Published public private(set) var currentRight: SessionActivityToast?
    @Published public private(set) var pendingLeft: [SessionActivityToast] = []
    @Published public private(set) var pendingRight: [SessionActivityToast] = []

    public private(set) var durationSeconds: Int

    private let sleep: @Sendable (TimeInterval) async -> Void
    private var leftTask: Task<Void, Never>?
    private var rightTask: Task<Void, Never>?
    private var leftGeneration = 0
    private var rightGeneration = 0

    public init(
        durationSeconds: Int = PreferencesStore.defaultActivityNotificationDurationSeconds,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.durationSeconds = PreferencesStore.normalizedActivityNotificationDurationSeconds(
            durationSeconds
        )
        self.sleep = sleep
    }

    /// Updates the duration used by newly enqueued messages. A current
    /// message keeps its own fixed duration metadata.
    public func updateDuration(seconds: Int) {
        durationSeconds = PreferencesStore.normalizedActivityNotificationDurationSeconds(seconds)
    }

    public func enqueue(_ transition: SessionActivityTransition) {
        let toast = SessionActivityToast(
            content: .transition(transition),
            durationSeconds: durationSeconds
        )
        switch transition.side {
        case .left:
            enqueue(toast, side: .left)
        case .right:
            enqueue(toast, side: .right)
        }
    }

    /// Cancels both lane tasks and clears all visible/pending messages. Task
    /// generations fence a late non-cooperative sleeper completion.
    public func cancel() {
        leftGeneration += 1
        rightGeneration += 1
        leftTask?.cancel()
        rightTask?.cancel()
        leftTask = nil
        rightTask = nil
        currentLeft = nil
        currentRight = nil
        pendingLeft.removeAll()
        pendingRight.removeAll()
    }

    public func cancelAll() {
        cancel()
    }

    deinit {
        leftTask?.cancel()
        rightTask?.cancel()
    }

    private func enqueue(_ toast: SessionActivityToast, side: AccountPosition) {
        if isDuplicate(toast, side: side) { return }

        switch side {
        case .left:
            guard currentLeft != nil else {
                currentLeft = toast
                start(side: .left)
                return
            }
            append(toast, to: .left)
        case .right:
            guard currentRight != nil else {
                currentRight = toast
                start(side: .right)
                return
            }
            append(toast, to: .right)
        }
    }

    private func isDuplicate(_ toast: SessionActivityToast, side: AccountPosition) -> Bool {
        switch side {
        case .left:
            return currentLeft.map { $0.content == toast.content } == true
                || pendingLeft.contains { $0.content == toast.content }
        case .right:
            return currentRight.map { $0.content == toast.content } == true
                || pendingRight.contains { $0.content == toast.content }
        }
    }

    private func append(_ toast: SessionActivityToast, to side: AccountPosition) {
        switch side {
        case .left:
            append(toast, pending: &pendingLeft)
        case .right:
            append(toast, pending: &pendingRight)
        }
    }

    private func append(_ toast: SessionActivityToast, pending: inout [SessionActivityToast]) {
        guard pending.count >= Self.maximumPendingCount else {
            pending.append(toast)
            return
        }

        if let summaryIndex = pending.lastIndex(where: { $0.isOverflowSummary }),
           let count = pending[summaryIndex].overflowCount {
            let capturedDuration = pending[summaryIndex].durationSeconds
            pending[summaryIndex] = SessionActivityToast(
                content: .overflow(count: count + 1),
                durationSeconds: capturedDuration
            )
        } else {
            pending[pending.count - 1] = SessionActivityToast(
                content: .overflow(count: 1),
                durationSeconds: durationSeconds
            )
        }
    }

    private func start(side: AccountPosition) {
        switch side {
        case .left:
            leftGeneration += 1
            let generation = leftGeneration
            let duration = TimeInterval(currentLeft?.durationSeconds ?? durationSeconds)
            let sleeper = sleep
            leftTask = Task { [weak self] in
                await sleeper(duration)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.finish(side: .left, generation: generation)
            }
        case .right:
            rightGeneration += 1
            let generation = rightGeneration
            let duration = TimeInterval(currentRight?.durationSeconds ?? durationSeconds)
            let sleeper = sleep
            rightTask = Task { [weak self] in
                await sleeper(duration)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.finish(side: .right, generation: generation)
            }
        }
    }

    private func finish(side: AccountPosition, generation: Int) {
        switch side {
        case .left:
            guard generation == leftGeneration else { return }
            leftTask = nil
            currentLeft = nil
            guard !pendingLeft.isEmpty else { return }
            currentLeft = pendingLeft.removeFirst()
            start(side: .left)
        case .right:
            guard generation == rightGeneration else { return }
            rightTask = nil
            currentRight = nil
            guard !pendingRight.isEmpty else { return }
            currentRight = pendingRight.removeFirst()
            start(side: .right)
        }
    }
}
