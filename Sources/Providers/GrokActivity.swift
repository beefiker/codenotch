import Foundation

/// How much Grok has actually been used, counted from its own session transcripts.
///
/// SuperGrok / Grok Build CLI and Grok Bot log each turn into `~/.grok/sessions/<workspace>/<session>/events.jsonl`
/// and write session-level statistics to `summary.json`.
struct GrokActivity: Equatable {
    let requestsToday: Int
    let totalTurns: Int
    let lastRequest: Date?

    static var defaultSessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/sessions")
    }

    private struct EventHead: Decodable {
        let ts: String
        let type: String
    }

    private struct SessionSummaryHead: Decodable {
        let num_messages: Int?
        let num_chat_messages: Int?
        let last_active_at: String?
        let updated_at: String?
    }

    static func read(root: URL = defaultSessionsRoot, now: Date = Date()) -> GrokActivity {
        let manager = FileManager.default
        var today = 0
        var total = 0
        var latest: Date?
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        guard let workspaces = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else {
            return GrokActivity(requestsToday: 0, totalTurns: 0, lastRequest: nil)
        }

        for workspace in workspaces {
            var isDir: ObjCBool = false
            guard manager.fileExists(atPath: workspace.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            guard let sessionDirs = try? manager.contentsOfDirectory(
                at: workspace, includingPropertiesForKeys: nil
            ) else { continue }

            for sessionDir in sessionDirs {
                // Read summary.json for total turns and latest activity
                let summaryFile = sessionDir.appendingPathComponent("summary.json")
                if let summaryData = try? Data(contentsOf: summaryFile),
                   let summary = try? JSONDecoder().decode(SessionSummaryHead.self, from: summaryData) {
                    let count = summary.num_messages ?? summary.num_chat_messages ?? 0
                    total += count
                    if let actStr = summary.last_active_at ?? summary.updated_at,
                       let actDate = parseDate(actStr) {
                        if latest == nil || actDate > latest! {
                            latest = actDate
                        }
                    }
                }

                // Check events.jsonl for today's turns
                let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
                guard let attrs = try? manager.attributesOfItem(atPath: eventsFile.path),
                      let modified = attrs[.modificationDate] as? Date
                else { continue }

                // Only parse lines if modified within 36 hours
                if now.timeIntervalSince(modified) > 36 * 3600 {
                    continue
                }

                guard let text = try? String(contentsOf: eventsFile, encoding: .utf8) else { continue }

                for line in text.split(separator: "\n") {
                    guard line.contains("\"turn_started\""),
                          let data = line.data(using: .utf8),
                          let event = try? JSONDecoder().decode(EventHead.self, from: data),
                          event.type == "turn_started",
                          let at = parseDate(event.ts)
                    else { continue }

                    if latest == nil || at > latest! { latest = at }
                    if calendar.isDate(at, inSameDayAs: now) { today += 1 }
                }
            }
        }

        return GrokActivity(requestsToday: today, totalTurns: total, lastRequest: latest)
    }

    private static let withFractionFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseDate(_ text: String) -> Date? {
        if let date = withFractionFormatter.date(from: text) { return date }
        return plainFormatter.date(from: text)
    }
}
