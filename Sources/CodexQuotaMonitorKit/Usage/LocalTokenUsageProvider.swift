import Foundation

/// Reads only token counters from rollout JSONL files below one configured
/// CODEX_HOME. Authentication, configuration, databases, prompts, messages,
/// tool content, and file contents are never returned by this type.
public struct LocalTokenUsageProvider: TokenUsageProvider, Sendable {
    /// Maximum number of rollout files examined for one snapshot. Candidates
    /// are ordered by their sessions-directory date before this cap applies.
    public static let defaultMaximumFileCount = 512
    /// Maximum UTF-8 bytes accepted for one JSONL line. Oversized lines are
    /// discarded without attempting to parse or retain their content.
    public static let defaultMaximumLineBytes = 1_048_576

    public let calendar: Calendar
    public let maxFileCount: Int
    public let maxLineBytes: Int

    public static let defaultMaxFileCount = defaultMaximumFileCount
    public static let defaultMaxLineBytes = defaultMaximumLineBytes

    private let now: @Sendable () -> Date
    private let aggregator: TokenUsageAggregator

    public init(
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = { Date() },
        maxFileCount: Int = LocalTokenUsageProvider.defaultMaximumFileCount,
        maxLineBytes: Int = LocalTokenUsageProvider.defaultMaximumLineBytes
    ) {
        self.calendar = calendar
        self.maxFileCount = max(0, maxFileCount)
        self.maxLineBytes = max(1, maxLineBytes)
        self.now = now
        self.aggregator = TokenUsageAggregator(calendar: calendar)
    }

    public func snapshot(home: URL) async -> TokenUsageSnapshot {
        let generatedAt = now()
        guard home.isFileURL else {
            return aggregator.emptySnapshot(
                generatedAt: generatedAt,
                availability: .unavailable,
                error: .invalidHome
            )
        }

        let sessionsURL = home.standardizedFileURL.appendingPathComponent(
            "sessions",
            isDirectory: true
        )
        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: sessionsURL.path, isDirectory: &isDirectory) else {
            // A newly configured CODEX_HOME has no sessions directory yet.
            return aggregator.emptySnapshot(generatedAt: generatedAt)
        }
        guard isDirectory.boolValue,
              fileManager.isReadableFile(atPath: sessionsURL.path) else {
            return aggregator.emptySnapshot(
                generatedAt: generatedAt,
                availability: .unavailable,
                error: .sessionsDirectoryUnavailable
            )
        }

        let candidates = rolloutCandidates(
            in: sessionsURL,
            referenceDate: generatedAt,
            fileManager: fileManager
        )
        var sessions: [TokenUsageSessionUsage] = []
        sessions.reserveCapacity(candidates.count)
        for candidate in candidates {
            if let parsed = parseRollout(candidate, fileManager: fileManager) {
                sessions.append(TokenUsageSessionUsage(date: parsed.date, totals: parsed.totals))
            }
        }

        return aggregator.aggregate(sessions: sessions, generatedAt: generatedAt)
    }

    private struct RolloutCandidate {
        let url: URL
        let directoryDate: Date?
    }

    private struct ParsedRollout {
        let date: Date
        let totals: TokenUsageTotals
    }

    private func rolloutCandidates(
        in sessionsURL: URL,
        referenceDate: Date,
        fileManager: FileManager
    ) -> [RolloutCandidate] {
        guard maxFileCount > 0,
              let enumerator = fileManager.enumerator(
                  at: sessionsURL,
                  includingPropertiesForKeys: [.isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        let today = calendar.startOfDay(for: referenceDate)
        let firstDay = calendar.date(
            byAdding: .day,
            value: -(TokenUsageSnapshot.historyDayCount - 1),
            to: today
        ) ?? today
        var candidates: [RolloutCandidate] = []

        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }

            let directoryDate = dateFromSessionsDirectory(
                for: url,
                sessionsURL: sessionsURL
            )
            if let directoryDate {
                let day = calendar.startOfDay(for: directoryDate)
                guard day >= firstDay, day <= today else { continue }
            }
            candidates.append(RolloutCandidate(url: url, directoryDate: directoryDate))
        }

        candidates.sort { lhs, rhs in
            let lhsDate = lhs.directoryDate ?? .distantPast
            let rhsDate = rhs.directoryDate ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            // This ordering is internal only; no path is exposed in a model.
            return lhs.url.path < rhs.url.path
        }
        return Array(candidates.prefix(maxFileCount))
    }

    private func parseRollout(
        _ candidate: RolloutCandidate,
        fileManager: FileManager
    ) -> ParsedRollout? {
        guard fileManager.isReadableFile(atPath: candidate.url.path) else { return nil }
        var safeDate: Date?
        var highestTotals: TokenUsageTotals?
        var sawTokenUsage = false

        let didRead = readJSONLines(at: candidate.url) { line in
            guard let object = try? JSONSerialization.jsonObject(
                with: Data(line),
                options: [.fragmentsAllowed]
            ), let root = object as? [String: Any] else {
                return
            }

            if safeDate == nil {
                safeDate = timestamp(in: root)
            }
            guard isTokenCountEvent(root),
                  let totals = tokenTotals(in: root) else {
                return
            }

            sawTokenUsage = true
            // Token-count events are cumulative. Keep the highest coherent
            // total (equal totals use the latest line) rather than summing
            // every event in the rollout.
            if highestTotals == nil || totals.totalTokens >= highestTotals!.totalTokens {
                highestTotals = totals
            }
        }
        guard didRead else {
            return nil
        }

        guard sawTokenUsage,
              let highestTotals,
              let date = safeDate ?? candidate.directoryDate else {
            return nil
        }
        return ParsedRollout(date: date, totals: highestTotals)
    }

    /// Streams one file and retains at most `maxLineBytes` bytes for a line.
    /// The callback receives only successfully bounded JSON data.
    private func readJSONLines(
        at url: URL,
        _ callback: ([UInt8]) -> Void
    ) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        let chunkSize = 64 * 1024
        var line = Data()
        line.reserveCapacity(min(maxLineBytes, chunkSize))
        var discardingOversizedLine = false

        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: chunkSize)
            } catch {
                return false
            }
            guard let chunk, !chunk.isEmpty else { break }

            for byte in chunk {
                if byte == 0x0A { // LF
                    if !discardingOversizedLine {
                        callback(trimCarriageReturn(from: line))
                    }
                    line.removeAll(keepingCapacity: true)
                    discardingOversizedLine = false
                } else if !discardingOversizedLine {
                    if line.count < maxLineBytes {
                        line.append(byte)
                    } else {
                        line.removeAll(keepingCapacity: true)
                        discardingOversizedLine = true
                    }
                }
            }
        }

        if !discardingOversizedLine, !line.isEmpty {
            callback(trimCarriageReturn(from: line))
        }
        return true
    }

    private func trimCarriageReturn(from data: Data) -> [UInt8] {
        var bytes = Array(data)
        if bytes.last == 0x0D { bytes.removeLast() }
        return bytes
    }

    private func isTokenCountEvent(_ root: [String: Any]) -> Bool {
        if normalizedType(root["type"]) == "token_count" {
            return true
        }
        if normalizedType(root["type"]) == "event_msg",
           let payload = root["payload"] as? [String: Any],
           normalizedType(payload["type"]) == "token_count" {
            return true
        }
        if let event = root["event_msg"] as? [String: Any],
           normalizedType(event["type"]) == "token_count" {
            return true
        }
        return false
    }

    /// Reads usage dictionaries only from known token-count containers. In
    /// particular, this never recursively walks prompt/message/content data.
    private func tokenTotals(in root: [String: Any]) -> TokenUsageTotals? {
        var containers: [[String: Any]] = [root]
        if let payload = root["payload"] as? [String: Any] { containers.append(payload) }
        if let event = root["event_msg"] as? [String: Any] { containers.append(event) }

        var usageDictionaries: [[String: Any]] = []
        for container in containers {
            appendUsageDictionaries(from: container, into: &usageDictionaries)
            if let info = container["info"] as? [String: Any] {
                appendUsageDictionaries(from: info, into: &usageDictionaries)
                // Some compatible token-count payloads put the counters
                // directly under `info` instead of under `total_token_usage`.
                usageDictionaries.append(info)
            }
        }

        for usage in usageDictionaries {
            let input = numericCounter(in: usage, keys: [
                "input_tokens", "inputTokens", "prompt_tokens", "prompt"
            ])
            let output = numericCounter(in: usage, keys: [
                "output_tokens", "outputTokens", "completion_tokens", "completion"
            ])
            guard input != nil || output != nil else { continue }
            return TokenUsageTotals(inputTokens: input ?? 0, outputTokens: output ?? 0)
        }
        return nil
    }

    private func appendUsageDictionaries(
        from container: [String: Any],
        into result: inout [[String: Any]]
    ) {
        for key in [
            "total_token_usage", "totalTokenUsage", "usage", "token_usage", "tokenUsage"
        ] {
            if let dictionary = container[key] as? [String: Any] {
                result.append(dictionary)
            }
        }
    }

    private func numericCounter(
        in dictionary: [String: Any],
        keys: [String]
    ) -> Int64? {
        for key in keys {
            if let value = dictionary[key], let number = nonNegativeInt64(value) {
                return number
            }
        }
        return nil
    }

    private func nonNegativeInt64(_ value: Any) -> Int64? {
        if value is Bool { return nil }
        guard let number = value as? NSNumber else { return nil }
        let type = String(cString: number.objCType)
        if type == "c" || type == "B" { return nil }

        let doubleValue = number.doubleValue
        guard doubleValue.isFinite else { return nil }
        if doubleValue <= 0 { return 0 }
        if doubleValue >= Double(Int64.max) { return Int64.max }
        return Int64(doubleValue.rounded(.towardZero))
    }

    private func timestamp(in root: [String: Any]) -> Date? {
        let keys = ["timestamp", "created_at", "createdAt", "event_timestamp", "eventTimestamp"]
        for key in keys {
            if let date = parseDate(root[key]) { return date }
        }
        if let payload = root["payload"] as? [String: Any] {
            for key in keys {
                if let date = parseDate(payload[key]) { return date }
            }
        }
        return nil
    }

    private func parseDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, !(value is Bool) {
            let raw = number.doubleValue
            guard raw.isFinite else { return nil }
            let seconds = abs(raw) > 100_000_000_000 ? raw / 1_000 : raw
            return Date(timeIntervalSince1970: seconds)
        }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private func dateFromSessionsDirectory(for url: URL, sessionsURL: URL) -> Date? {
        let base = sessionsURL.standardizedFileURL.pathComponents
        let directory = url.deletingLastPathComponent().standardizedFileURL.pathComponents
        guard directory.count >= base.count,
              Array(directory.prefix(base.count)) == base else {
            return nil
        }
        let relative = Array(directory.dropFirst(base.count))

        if relative.count >= 3 {
            for index in stride(from: relative.count - 3, through: 0, by: -1) {
                if let date = makeDate(
                    year: relative[index],
                    month: relative[index + 1],
                    day: relative[index + 2]
                ) {
                    return date
                }
            }
        }

        for component in relative.reversed() {
            let pieces = component.split { character in
                character == "-" || character == "_" || character == "."
            }
            if pieces.count == 3,
               let date = makeDate(year: String(pieces[0]), month: String(pieces[1]), day: String(pieces[2])) {
                return date
            }
        }
        return nil
    }

    private func makeDate(year: String, month: String, day: String) -> Date? {
        guard year.count == 4,
              let yearValue = Int(year),
              let monthValue = Int(month),
              let dayValue = Int(day),
              (1...12).contains(monthValue),
              (1...31).contains(dayValue) else {
            return nil
        }
        var components = DateComponents()
        components.year = yearValue
        components.month = monthValue
        components.day = dayValue
        guard let date = calendar.date(from: components) else { return nil }
        let normalized = calendar.startOfDay(for: date)
        // Reject e.g. February 31, which Calendar normalizes into March.
        let check = calendar.dateComponents([.year, .month, .day], from: normalized)
        guard check.year == yearValue,
              check.month == monthValue,
              check.day == dayValue else {
            return nil
        }
        return normalized
    }

    private func normalizedType(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        return string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
    }
}
