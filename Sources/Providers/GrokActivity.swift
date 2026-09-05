import Foundation

/// How much Grok has actually been used, counted from its own session transcripts.
///
/// SuperGrok / Grok Build CLI and Grok Bot log each turn into `~/.grok/sessions/<workspace>/<session>/events.jsonl`.
/// When xAI does not publish a percentage rate limit directly, counting turns today provides
/// an accurate, transparent local metric.
struct GrokActivity: Equatable {
    let requestsToday: Int
    let lastRequest: Date?

    static var defaultSessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/sessions")
    }

    private struct EventHead: Decodable {
        let ts: String
        let type: String
    }

    static func read(root: URL = defaultSessionsRoot, now: Date = Date()) -> GrokActivity {
        let manager = FileManager.default
        var today = 0
        var latest: Date?
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        guard let workspaces = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else {
            return GrokActivity(requestsToday: 0, lastRequest: nil)
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
                let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
                guard let attrs = try? manager.attributesOfItem(atPath: eventsFile.path),
                      let modified = attrs[.modificationDate] as? Date
                else { continue }

                // Optimization: skip files not modified within the last 48 hours
                if now.timeIntervalSince(modified) > 48 * 3600 {
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

        return GrokActivity(requestsToday: today, lastRequest: latest)
    }

    static func parseDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
