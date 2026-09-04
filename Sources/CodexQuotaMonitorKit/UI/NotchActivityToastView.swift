import Combine
import SwiftUI

public enum NotchActivityPresentationPhase: String, Equatable, Sendable {
    case idle
    case entering
    case visible
    case exiting
}

public enum NotchActivityPresentationEvent: Equatable, Sendable {
    case entry(id: String, duration: TimeInterval)
    case exit(id: String, duration: TimeInterval)
    case removed(id: String)
}

/// Main-actor state machine for one independent notch-side toast lane. The
/// model keeps the displayed value alive through the exit interval, so panel
/// geometry and the stable SwiftUI host do not shrink until removal completes.
@MainActor
public final class NotchActivityPresentationModel: ObservableObject {
    public static let entryAnimationDuration: TimeInterval = 0.2
    public static let exitAnimationDuration: TimeInterval = 0.25

    @Published public private(set) var displayedToast: SessionActivityToast?
    @Published public private(set) var displayedWidth: CGFloat?
    @Published public private(set) var phase: NotchActivityPresentationPhase
    public private(set) var events: [NotchActivityPresentationEvent] = []
    public var onPresentationChange: (@MainActor () -> Void)?

    private var requestedToast: SessionActivityToast?
    private var requestedWidth: CGFloat?
    private var generation = 0
    private var lifecycleTask: Task<Void, Never>?
    private let sleep: @Sendable (TimeInterval) async -> Void

    public init(
        toast: SessionActivityToast? = nil,
        width: CGFloat? = nil,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.sleep = sleep
        self.requestedToast = toast
        self.requestedWidth = Self.normalizedWidth(width, for: toast)
        self.displayedToast = toast
        self.displayedWidth = Self.normalizedWidth(width, for: toast)
        self.phase = toast == nil ? .idle : .visible
    }

    /// Changes the target value without replacing the host view. A queued
    /// replacement first retires the currently displayed value, then inserts
    /// the new value after the fixed exit duration.
    public func setToast(_ toast: SessionActivityToast?, width: CGFloat? = nil) {
        let normalizedWidth = Self.normalizedWidth(width, for: toast)
        let sameTarget = Self.sameID(requestedToast, toast)
        requestedToast = toast
        requestedWidth = normalizedWidth

        if Self.sameID(displayedToast, toast) {
            if toast == nil {
                lifecycleTask?.cancel()
                generation &+= 1
                phase = .idle
                displayedWidth = nil
                notifyChange()
            } else if phase == .exiting {
                lifecycleTask?.cancel()
                generation &+= 1
                phase = .visible
                displayedWidth = normalizedWidth
                notifyChange()
            } else if displayedWidth != normalizedWidth {
                displayedWidth = normalizedWidth
                notifyChange()
            }
            return
        }

        if sameTarget {
            // The target may already be waiting behind an exit. Changing its
            // width must not restart or duplicate that exit event.
            return
        }

        generation &+= 1
        lifecycleTask?.cancel()
        let token = generation

        guard let displayedToast else {
            guard let toast else {
                phase = .idle
                displayedWidth = nil
                notifyChange()
                return
            }
            beginEntry(toast, width: normalizedWidth, generation: token)
            return
        }

        if phase == .exiting {
            // A rapid target change keeps the same retiring value and starts
            // one fresh generation; stale sleepers can never promote data.
            scheduleExit(for: displayedToast, generation: token)
            notifyChange()
            return
        }

        beginExit(for: displayedToast, generation: token)
    }

    /// Clamps only the currently displayed value's width. It does not alter a
    /// pending replacement's requested width or its lifecycle generation.
    public func setDisplayedWidth(_ width: CGFloat?) {
        guard let displayedToast else { return }
        let normalized = Self.normalizedWidth(width, for: displayedToast)
        guard displayedWidth != normalized else { return }
        displayedWidth = normalized
        notifyChange()
    }

    private func beginEntry(
        _ toast: SessionActivityToast,
        width: CGFloat?,
        generation: Int
    ) {
        displayedToast = toast
        displayedWidth = width
        phase = .entering
        events.append(.entry(id: toast.id, duration: Self.entryAnimationDuration))
        notifyChange()
        scheduleEntry(for: toast, generation: generation)
    }

    private func beginExit(
        for toast: SessionActivityToast,
        generation: Int
    ) {
        phase = .exiting
        events.append(.exit(id: toast.id, duration: Self.exitAnimationDuration))
        notifyChange()
        scheduleExit(for: toast, generation: generation)
    }

    private func scheduleEntry(
        for toast: SessionActivityToast,
        generation: Int
    ) {
        let sleeper = sleep
        lifecycleTask = Task { @MainActor [weak self] in
            await sleeper(Self.entryAnimationDuration)
            guard !Task.isCancelled, let self else { return }
            guard self.generation == generation,
                  self.phase == .entering,
                  Self.sameID(self.displayedToast, toast)
            else { return }
            self.phase = .visible
            self.lifecycleTask = nil
            self.notifyChange()
        }
    }

    private func scheduleExit(
        for toast: SessionActivityToast,
        generation: Int
    ) {
        let sleeper = sleep
        lifecycleTask = Task { @MainActor [weak self] in
            await sleeper(Self.exitAnimationDuration)
            guard !Task.isCancelled, let self else { return }
            guard self.generation == generation,
                  self.phase == .exiting,
                  Self.sameID(self.displayedToast, toast)
            else { return }

            guard let replacement = self.requestedToast else {
                self.displayedToast = nil
                self.displayedWidth = nil
                self.phase = .idle
                self.lifecycleTask = nil
                self.events.append(.removed(id: toast.id))
                self.notifyChange()
                return
            }

            self.displayedToast = replacement
            self.displayedWidth = self.requestedWidth
            self.phase = .entering
            self.events.append(
                .entry(id: replacement.id, duration: Self.entryAnimationDuration)
            )
            self.notifyChange()
            self.scheduleEntry(for: replacement, generation: generation)
        }
    }

    private func notifyChange() {
        onPresentationChange?()
    }

    private static func sameID(
        _ lhs: SessionActivityToast?,
        _ rhs: SessionActivityToast?
    ) -> Bool {
        lhs?.id == rhs?.id
    }

    private static func normalizedWidth(
        _ width: CGFloat?,
        for toast: SessionActivityToast?
    ) -> CGFloat? {
        guard let toast else { return nil }
        guard let width else { return NotchActivityToastMetrics.requiredWidth(for: toast) }
        guard width.isFinite else { return 0 }
        return max(0, width)
    }

    deinit {
        lifecycleTask?.cancel()
    }
}

/// Sanitized copy used by the compact, notch-adjacent activity toast. The
/// model intentionally exposes only the short session identifier and the
/// privacy-filtered transition labels supplied by the session monitor.
public struct NotchActivityToastCopy: Equatable, Sendable {
    public let firstLine: String
    public let secondLine: String?

    public var lines: [String] {
        if let secondLine {
            return [firstLine, secondLine]
        }
        return [firstLine]
    }

    public init(firstLine: String, secondLine: String? = nil) {
        self.firstLine = firstLine
        self.secondLine = secondLine
    }

    public static func make(for toast: SessionActivityToast) -> NotchActivityToastCopy {
        if let transition = toast.transition {
            let account = normalized(transition.accountID, fallback: "Account") ?? "Account"
            let firstLine: String
            if let sessionID = transition.sessionID,
               !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                firstLine = "\(account) · Session \(shortSessionID(sessionID))"
            } else {
                firstLine = account
            }

            let agent = normalized(transition.agentLabel, fallback: "Agent") ?? "Agent"
            let task = normalized(transition.taskName, fallback: nil)
            let status = statusText(transition.status)
            let secondLine = [agent, task, status]
                .compactMap { $0 }
                .joined(separator: " · ")
            return NotchActivityToastCopy(firstLine: firstLine, secondLine: secondLine)
        }

        let count = max(0, toast.overflowCount ?? 0)
        return NotchActivityToastCopy(firstLine: "\(count) more activity updates")
    }

    private static func shortSessionID(_ sessionID: String) -> String {
        let prefix = String(sessionID.prefix(8))
        return sessionID.count > prefix.count ? "\(prefix)..." : prefix
    }

    private static func statusText(_ status: SessionActivityStatus) -> String {
        switch status {
        case .working: return "Working"
        case .waiting: return "Waiting"
        case .inactive: return "Inactive"
        case .completed: return "Completed"
        case .stopped: return "Stopped"
        case .error: return "Error"
        case .unknown: return "Unknown"
        }
    }

    private static func normalized(_ value: String?, fallback: String?) -> String? {
        guard let value else { return fallback }
        let cleaned = value
            .unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return fallback }
        return String(cleaned.prefix(80))
    }
}

/// Pure presentation policy shared by tests and the SwiftUI transition.
public enum NotchActivityToastPresentation {
    public static let entryAnimationDuration: TimeInterval = 0.2
    public static let exitAnimationDuration: TimeInterval = 0.25

    public static func usesSlide(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    public static func shouldShimmer(
        status: SessionActivityStatus,
        reduceMotion: Bool
    ) -> Bool {
        status == .working && !reduceMotion
    }

    public static func animationDuration(isPresented: Bool) -> TimeInterval {
        isPresented ? entryAnimationDuration : exitAnimationDuration
    }
}

/// Deterministic width estimate for the compact toast. The panel manager uses
/// this same value for pure frame expansion, so SwiftUI content and the
/// transparent NSPanel keep one source of truth. AppKit text measurement is
/// deliberately avoided here to keep geometry tests value-only.
public enum NotchActivityToastMetrics {
    public static let horizontalPadding: CGFloat = 16
    public static let characterAdvance: CGFloat = 6.2
    public static let minimumWidth: CGFloat = 72

    public static func requiredWidth(for toast: SessionActivityToast?) -> CGFloat {
        guard let toast else { return 0 }
        let copy = NotchActivityToastCopy.make(for: toast)
        let longestLine = copy.lines.map(\.count).max() ?? 0
        let estimated = CGFloat(longestLine) * characterAdvance + horizontalPadding
        guard estimated.isFinite else { return minimumWidth }
        return max(minimumWidth, estimated)
    }
}

/// Outward-growing activity copy. The host supplies an optional current toast;
/// the queue and AppDelegate remain responsible for choosing that value and
/// its lifetime.
public struct NotchActivityToastView: View {
    public static let entryAnimationDuration = NotchActivityToastPresentation.entryAnimationDuration
    public static let exitAnimationDuration = NotchActivityToastPresentation.exitAnimationDuration

    public let toast: SessionActivityToast
    public let side: NotchSide
    public let width: CGFloat?
    public let isExiting: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        toast: SessionActivityToast,
        side: NotchSide,
        width: CGFloat? = nil,
        isExiting: Bool = false
    ) {
        self.toast = toast
        self.side = side
        self.width = width
        self.isExiting = isExiting
    }

    public var body: some View {
        let copy = NotchActivityToastCopy.make(for: toast)
        let status = toast.transition?.status ?? .unknown
        let resolvedWidth = width.map { max(0, $0) }
            ?? NotchActivityToastMetrics.requiredWidth(for: toast)
        let transition: AnyTransition = NotchActivityToastPresentation.usesSlide(
            reduceMotion: reduceMotion
        )
            ? .move(edge: side == .left ? .leading : .trailing).combined(with: .opacity)
            : .opacity

        VStack(
            alignment: side == .left ? .leading : .trailing,
            spacing: 1
        ) {
            Text(copy.firstLine)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .truncationMode(.tail)

            if let secondLine = copy.secondLine {
                ShimmerText(secondLine, status: status)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .truncationMode(.tail)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(width: resolvedWidth)
        .frame(maxHeight: .infinity, alignment: .center)
        .contentShape(Rectangle())
        .allowsHitTesting(false)
        .opacity(isExiting ? 0 : 1)
        .offset(
            x: isExiting && !reduceMotion
                ? (side == .left ? -8 : 8)
                : 0
        )
        .transition(transition)
        .animation(
            .easeOut(
                duration: NotchActivityToastPresentation.animationDuration(
                    isPresented: !isExiting
                )
            ),
            value: isExiting
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(copy.lines.joined(separator: ", "))
    }
}
