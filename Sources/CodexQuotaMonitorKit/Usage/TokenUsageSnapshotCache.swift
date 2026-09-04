import Foundation

/// An in-memory, account-scoped token snapshot cache. The cache deliberately
/// retains only the stable account ID and the privacy-bounded snapshot; a
/// CODEX_HOME URL is used only for the duration of an explicit refresh.
public actor TokenUsageSnapshotCache {
    private let provider: any TokenUsageProvider
    private let invalidationState: InvalidationState
    private var snapshots: [String: Entry] = [:]

    private struct Entry: Sendable {
        let generation: UInt64
        let snapshot: TokenUsageSnapshot
    }

    public init(provider: any TokenUsageProvider = LocalTokenUsageProvider()) {
        self.provider = provider
        self.invalidationState = InvalidationState()
    }

    /// Returns the cached value without touching the filesystem.
    public func cachedSnapshot(for accountID: String) -> TokenUsageSnapshot? {
        let generation = invalidationState.current()
        guard let entry = snapshots[accountID], entry.generation == generation else {
            return nil
        }
        return entry.snapshot
    }

    /// Compatibility spelling for callers that use a generic snapshot lookup.
    public func snapshot(for accountID: String) -> TokenUsageSnapshot? {
        cachedSnapshot(for: accountID)
    }

    /// Replaces an account's in-memory value. This is useful for hosts that
    /// already own a bounded snapshot and for deterministic cache tests.
    public func replace(_ snapshot: TokenUsageSnapshot, for accountID: String) {
        snapshots[accountID] = Entry(
            generation: invalidationState.current(),
            snapshot: snapshot
        )
    }

    /// Performs the only filesystem operation exposed by the cache. The home
    /// URL is not retained after the provider call returns.
    public func refresh(accountID: String, home: URL) async -> TokenUsageSnapshot {
        let generation = invalidationState.current()
        let snapshot = await provider.snapshot(home: home)
        // A path reconfiguration may happen while the provider is reading.
        // Do not let that pre-change result repopulate the newly invalidated
        // stable slot after the read completes.
        guard invalidationState.current() == generation else {
            return snapshot
        }
        snapshots[accountID] = Entry(
            generation: generation,
            snapshot: snapshot
        )
        return snapshot
    }

    /// Explicit spelling for UI hosts that call the action an update.
    public func update(accountID: String, home: URL) async -> TokenUsageSnapshot {
        await refresh(accountID: accountID, home: home)
    }

    public func remove(accountID: String) {
        snapshots.removeValue(forKey: accountID)
    }

    public func removeAll() {
        snapshots.removeAll()
    }

    /// Synchronously marks every existing entry stale, then schedules the
    /// actor-isolated dictionary cleanup. This is used by the synchronous
    /// lifecycle path before account homes are replaced, so a dashboard opened
    /// immediately afterward cannot observe a prior path's snapshot.
    public nonisolated func invalidateAll() {
        let generation = invalidationState.invalidate()
        Task { await self.removeEntries(olderThan: generation) }
    }

    private func removeEntries(olderThan generation: UInt64) {
        snapshots = snapshots.filter { _, entry in
            entry.generation >= generation
        }
    }
}

private final class InvalidationState: @unchecked Sendable {
    private let queue = DispatchQueue(label: "CodexQuotaMonitor.TokenUsageCacheInvalidation")
    private var generation: UInt64 = 0

    func current() -> UInt64 {
        queue.sync { generation }
    }

    func invalidate() -> UInt64 {
        queue.sync {
            generation &+= 1
            return generation
        }
    }
}
