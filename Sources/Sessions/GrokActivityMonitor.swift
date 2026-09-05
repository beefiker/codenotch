import Combine
import Foundation

/// Notices when Grok (CLI or Grok Bot) is actively running turns.
///
/// Grok tracks active sessions in `~/.grok/active_sessions.json` and writes real-time
/// turn events into `~/.grok/sessions/<workspace>/<session>/events.jsonl`.
@MainActor
final class GrokActivityMonitor: AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    private let activeSessionsURL: URL
    private let sessionsRoot: URL
    private let interval: TimeInterval
    private let staleAfter: TimeInterval
    private var timer: Timer?

    nonisolated static var defaultActiveSessionsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/active_sessions.json")
    }

    nonisolated static var defaultSessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/sessions")
    }

    init(
        activeSessionsURL: URL = defaultActiveSessionsURL,
        sessionsRoot: URL = defaultSessionsRoot,
        interval: TimeInterval = 2,
        staleAfter: TimeInterval = 45
    ) {
        self.activeSessionsURL = activeSessionsURL
        self.sessionsRoot = sessionsRoot
        self.interval = interval
        self.staleAfter = staleAfter
    }

    func start() {
        stop()
        poll()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let found = Self.read(
            activeSessionsURL: activeSessionsURL,
            sessionsRoot: sessionsRoot,
            staleAfter: staleAfter
        )
        guard found != sessions else { return }
        sessions = found
    }

    private struct ActiveSessionEntry: Decodable {
        let session_id: String
        let pid: Int32?
        let cwd: String?
        let opened_at: String?
    }

    private struct SessionSummary: Decodable {
        let session_summary: String?
        let generated_title: String?
    }

    nonisolated static func read(
        activeSessionsURL: URL = defaultActiveSessionsURL,
        sessionsRoot: URL = defaultSessionsRoot,
        staleAfter: TimeInterval = 45,
        now: Date = Date()
    ) -> [AgentSession] {
        let manager = FileManager.default

        // 1. Check active_sessions.json first
        if let data = try? Data(contentsOf: activeSessionsURL),
           let entries = try? JSONDecoder().decode([ActiveSessionEntry].self, from: data),
           !entries.isEmpty {
            for entry in entries {
                let openedAt = entry.opened_at.flatMap(GrokActivity.parseDate)
                if let pid = entry.pid {
                    guard ProcessLiveness.isAlive(pid: pid, startedAt: openedAt) else {
                        continue
                    }
                }
                return [
                    AgentSession(
                        id: "grok.\(entry.session_id)",
                        name: "Grok",
                        detail: entry.cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent } ?? "Working",
                        state: .busy,
                        waitingFor: nil,
                        since: openedAt ?? now
                    )
                ]
            }
        }

        // 2. Check the newest events.jsonl or updates.jsonl across recent sessions
        guard let workspaces = try? manager.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: nil
        ) else { return [] }

        var newest: (sessionDir: URL, modified: Date)?

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

                if newest == nil || modified > newest!.modified {
                    newest = (sessionDir, modified)
                }
            }
        }

        guard let newest, now.timeIntervalSince(newest.modified) <= staleAfter else {
            return []
        }

        var title: String?
        let summaryFile = newest.sessionDir.appendingPathComponent("summary.json")
        if let data = try? Data(contentsOf: summaryFile),
           let summary = try? JSONDecoder().decode(SessionSummary.self, from: data) {
            title = summary.session_summary ?? summary.generated_title
        }

        let sessionID = newest.sessionDir.lastPathComponent
        return [
            AgentSession(
                id: "grok.\(sessionID)",
                name: "Grok",
                detail: title ?? "Working",
                state: .busy,
                waitingFor: nil,
                since: newest.modified
            )
        ]
    }
}
