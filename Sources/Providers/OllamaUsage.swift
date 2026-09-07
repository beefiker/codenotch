import Foundation

/// Calculates Ollama subscription usage and limit windows from server logs and daemon state.
///
/// Ollama Pro cloud subscriptions enforce a 5-hour session window and a 7-day weekly quota.
/// Reads recent turns from `~/.ollama/logs/server.log` to track usage across rolling windows.
enum OllamaUsage {
    static var defaultLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ollama/logs/server.log")
    }

    /// Default allowance for Ollama Pro subscription tiers
    static let defaultSessionLimit = 50
    static let defaultWeeklyLimit = 500

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy/MM/dd - HH:mm:ss"
        f.timeZone = .current
        return f
    }()

    struct RequestRecord {
        let timestamp: Date
        let statusCode: Int
        let method: String
        let path: String
    }

    /// Read the tail of the server log to parse recent requests.
    static func recentRequests(from logURL: URL = defaultLogURL, tailBytes: Int = 128 * 1024) -> [RequestRecord] {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return [] }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        return parseRequests(from: text)
    }

    /// Parse requests from log text.
    static func parseRequests(from text: String) -> [RequestRecord] {
        var records: [RequestRecord] = []
        let lines = text.split(separator: "\n")

        for line in lines {
            // Match: [GIN] 2026/08/25 - 03:52:31 | 200 | ... | POST "/api/chat"
            guard line.contains("[GIN]") else { continue }
            let parts = line.split(separator: "|")
            guard parts.count >= 5 else { continue }

            // Date is inside parts[0] after [GIN]
            let datePart = parts[0].replacingOccurrences(of: "[GIN]", with: "").trimmingCharacters(in: .whitespaces)
            guard let date = dateFormatter.date(from: datePart) else { continue }

            let status = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 200
            let callPart = parts[4].trimmingCharacters(in: .whitespaces)
            let callTokens = callPart.split(separator: " ")
            let method = callTokens.first.map(String.init) ?? "POST"
            let rawPath = callTokens.dropFirst().joined(separator: " ")
            let path = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))

            // Only count model inference calls (chat, generate, completions, messages)
            let isGeneration = path.contains("/chat") || path.contains("/generate")
                || path.contains("/completions") || path.contains("/messages")
            guard isGeneration else { continue }

            records.append(RequestRecord(
                timestamp: date,
                statusCode: status,
                method: method,
                path: path
            ))
        }
        return records
    }

    /// Compute session and weekly limit windows from request history.
    static func windows(
        requests: [RequestRecord],
        now: Date = Date(),
        sessionLimit: Int = defaultSessionLimit,
        weeklyLimit: Int = defaultWeeklyLimit
    ) -> (windows: [LimitWindow], block: UsageBlock?) {
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let sevenDaysAgo = now.addingTimeInterval(-7 * 86400)

        let sessionRequests = requests.filter { $0.timestamp >= fiveHoursAgo && $0.timestamp <= now }
        let weeklyRequests = requests.filter { $0.timestamp >= sevenDaysAgo && $0.timestamp <= now }

        let sessionCount = sessionRequests.count
        let weeklyCount = weeklyRequests.count

        // Rolling resets
        let sessionResetsAt: Date? = sessionRequests.first.map { $0.timestamp.addingTimeInterval(5 * 3600) }
        let weeklyResetsAt: Date? = weeklyRequests.first.map { $0.timestamp.addingTimeInterval(7 * 86400) }

        let sessionFraction = Double(sessionCount) / Double(sessionLimit)
        let weeklyFraction = Double(weeklyCount) / Double(weeklyLimit)

        let sessionWindow = LimitWindow(
            id: "session",
            label: "5-hour session",
            usedFraction: min(1.0, sessionFraction),
            remaining: max(0, sessionLimit - sessionCount),
            used: sessionCount,
            resetsAt: sessionResetsAt
        )

        let weeklyWindow = LimitWindow(
            id: "weekly",
            label: "Weekly quota",
            usedFraction: min(1.0, weeklyFraction),
            remaining: max(0, weeklyLimit - weeklyCount),
            used: weeklyCount,
            resetsAt: weeklyResetsAt
        )

        // Check for 429 rate limits in recent window
        var block: UsageBlock?
        if let last429 = sessionRequests.last(where: { $0.statusCode == 429 }) {
            let blockReset = sessionResetsAt ?? now.addingTimeInterval(60 * 15)
            block = UsageBlock(reason: "Ollama rate limit reached", resetsAt: blockReset)
        }

        return ([sessionWindow, weeklyWindow], block)
    }
}
