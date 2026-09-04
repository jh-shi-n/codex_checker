import CodexQuotaMonitorKit

@MainActor
final class SessionActivityToastDeliveryGate {
    private let queue: SessionActivityToastQueue
    private var isActive = true
    private var isStopped = false
    private var generation = 0

    init(queue: SessionActivityToastQueue) {
        self.queue = queue
    }

    func deliver(_ transition: SessionActivityTransition) {
        guard isActive else { return }
        queue.enqueue(transition)
    }

    func pause() -> Int {
        generation += 1
        isActive = false
        queue.cancel()
        return generation
    }

    func resume(generation: Int) {
        guard self.generation == generation, !isStopped else { return }
        isActive = true
    }

    func stop() {
        generation += 1
        isActive = false
        isStopped = true
        queue.cancel()
    }
}
