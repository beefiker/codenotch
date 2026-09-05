import Foundation
import os

/// Models the `sequence.json` file in `~/.claude-swap-backup`.
struct ClaudeSwapSequence: Decodable {
    let activeAccountNumber: Int?
    let sequence: [Int]?
    let accounts: [String: AccountRecord]?

    struct AccountRecord: Decodable {
        let email: String?
        let uuid: String?
        let organizationUuid: String?
        let organizationName: String?
        let added: String?
        let alias: String?
    }
}

/// Models the `cache/usage.json` file in `~/.claude-swap-backup`.
struct ClaudeSwapUsageCache: Decodable {
    let schemaVersion: Int?
    let accounts: [String: AccountUsageRecord]?

    struct AccountUsageRecord: Decodable {
        let email: String?
        let lastGood: LastGood?
        let lastError: String?
        let lastAttemptAt: Double?
        let fetchedAt: Double?

        struct LastGood: Decodable {
            let five_hour: WindowMetric?
            let seven_day: WindowMetric?
            let scoped: [ScopedMetric]?

            struct WindowMetric: Decodable {
                let pct: Double?
                let resets_at: String?
                let countdown: String?
                let clock: String?
            }

            struct ScopedMetric: Decodable {
                let name: String?
                let pct: Double?
                let resets_at: String?
                let countdown: String?
                let clock: String?
            }
        }
    }
}

/// Discovers managed accounts from `claude-swap`.
enum ClaudeSwapDiscovery {
    static var defaultBackupDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude-swap-backup")
    }

    static func isAvailable(backupDir: URL = defaultBackupDirectory) -> Bool {
        let seqURL = backupDir.appendingPathComponent("sequence.json")
        return FileManager.default.fileExists(atPath: seqURL.path)
    }

    static func providers(
        backupDir: URL = defaultBackupDirectory,
        liveOAuthProvider: ClaudeOAuthProvider? = nil
    ) -> [ClaudeSwapAccountProvider] {
        let seqURL = backupDir.appendingPathComponent("sequence.json")
        guard let data = try? Data(contentsOf: seqURL),
              let sequence = try? JSONDecoder().decode(ClaudeSwapSequence.self, from: data),
              let accounts = sequence.accounts,
              !accounts.isEmpty
        else { return [] }

        let activeSlot = sequence.activeAccountNumber
        let slots = (sequence.sequence ?? accounts.keys.compactMap(Int.init)).sorted()

        return slots.compactMap { slot -> ClaudeSwapAccountProvider? in
            guard let record = accounts[String(slot)] else { return nil }
            let email = record.email ?? "account-\(slot)"
            let isActive = (slot == activeSlot)

            return ClaudeSwapAccountProvider(
                slot: slot,
                email: email,
                alias: record.alias,
                orgName: record.organizationName,
                isActive: isActive,
                backupDir: backupDir,
                liveProvider: isActive ? (liveOAuthProvider ?? ClaudeOAuthProvider()) : nil
            )
        }
    }
}

/// A provider representing an individual Claude account managed by `claude-swap`.
actor ClaudeSwapAccountProvider: UsageProvider {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let glyph = ProviderGlyph.claude

    nonisolated let slot: Int
    nonisolated let email: String
    nonisolated let alias: String?
    nonisolated let orgName: String?
    nonisolated let isActive: Bool
    nonisolated let backupDir: URL
    private let liveProvider: ClaudeOAuthProvider?

    init(
        slot: Int,
        email: String,
        alias: String? = nil,
        orgName: String? = nil,
        isActive: Bool = false,
        backupDir: URL = ClaudeSwapDiscovery.defaultBackupDirectory,
        liveProvider: ClaudeOAuthProvider? = nil
    ) {
        self.slot = slot
        self.email = email
        self.alias = alias
        self.orgName = orgName
        self.isActive = isActive
        self.backupDir = backupDir
        self.liveProvider = liveProvider

        self.id = "claude-swap-\(slot)"

        let shortName: String
        if let alias, !alias.isEmpty {
            shortName = alias
        } else if let user = email.split(separator: "@").first, !user.isEmpty {
            shortName = String(user)
        } else {
            shortName = "#\(slot)"
        }
        self.displayName = "Claude (\(shortName))"
    }

    nonisolated func account() -> ProviderAccount? {
        ProviderAccount(
            label: email,
            plan: isActive ? "Active" : "Slot \(slot)",
            source: "claude-swap",
            manageURL: URL(string: "https://claude.ai/settings/usage")
        )
    }

    nonisolated var signInRoute: SignInRoute {
        .command(
            title: "Switch to Slot \(slot)",
            explanation: "Switch active Claude account to \(email) (Slot \(slot)) via claude-swap."
        )
    }

    nonisolated func presentSignIn() {
        guard let exe = CLIBridge.claudeSwapExecutable() else {
            Log.usage.error("claude-swap executable not found")
            return
        }
        Task {
            _ = await CLIBridge.run(executable: exe, arguments: ["switch", String(slot)])
        }
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        // If active, try the live Claude OAuth endpoint first
        if isActive, let liveProvider {
            do {
                var live = try await liveProvider.fetchSnapshot()
                return ProviderSnapshot(
                    id: id,
                    displayName: displayName,
                    glyph: glyph,
                    fidelity: live.fidelity,
                    status: live.status,
                    windows: live.windows,
                    headlineID: "session",
                    block: live.block,
                    accountBadge: "\(slot)",
                    isActive: true,
                    accountDetail: "\(email) · Active"
                )
            } catch {
                Log.usage.notice("claude-swap slot \(self.slot) active live fetch failed, falling back to cache: \(error)")
            }
        }

        // Read usage from ~/.claude-swap-backup/cache/usage.json
        let usageURL = backupDir.appendingPathComponent("cache/usage.json")
        guard let data = try? Data(contentsOf: usageURL),
              let cache = try? JSONDecoder().decode(ClaudeSwapUsageCache.self, from: data),
              let accountUsage = cache.accounts?[String(slot)]
        else {
            return ProviderSnapshot(
                id: id,
                displayName: displayName,
                glyph: glyph,
                fidelity: .derived,
                status: .stale(since: .distantPast),
                windows: [],
                headlineID: "session",
                accountBadge: "\(slot)",
                isActive: isActive,
                accountDetail: "\(email) · \(isActive ? "Active" : "Slot \(slot)")"
            )
        }

        if let lastGood = accountUsage.lastGood {
            var windows: [LimitWindow] = []

            if let fiveHour = lastGood.five_hour, let pct = fiveHour.pct {
                windows.append(LimitWindow(
                    id: "session",
                    label: "Current session",
                    usedFraction: pct / 100.0,
                    resetsAt: fiveHour.resets_at.flatMap(Self.parseDate)
                ))
            }

            if let sevenDay = lastGood.seven_day, let pct = sevenDay.pct {
                windows.append(LimitWindow(
                    id: "all-models",
                    label: "Weekly (all models)",
                    usedFraction: pct / 100.0,
                    resetsAt: sevenDay.resets_at.flatMap(Self.parseDate)
                ))
            }

            if let scoped = lastGood.scoped {
                for item in scoped {
                    if let name = item.name, let pct = item.pct {
                        windows.append(LimitWindow(
                            id: "scoped-\(name)",
                            label: name,
                            usedFraction: pct / 100.0,
                            resetsAt: item.resets_at.flatMap(Self.parseDate)
                        ))
                    }
                }
            }

            let fetchedAt = accountUsage.fetchedAt.map { Date(timeIntervalSince1970: $0) } ?? Date()
            let status: ProviderStatus = Date().timeIntervalSince(fetchedAt) > 5 * 60
                ? .stale(since: fetchedAt)
                : .ok

            return ProviderSnapshot(
                id: id,
                displayName: displayName,
                glyph: glyph,
                fidelity: .official,
                status: status,
                windows: windows,
                headlineID: "session",
                accountBadge: "\(slot)",
                isActive: isActive,
                accountDetail: "\(email) · \(isActive ? "Active" : "Slot \(slot)")"
            )
        }

        // If no lastGood, inspect lastError
        let status: ProviderStatus
        if let err = accountUsage.lastError, err.contains("invalid_grant") || err.contains("relogin") {
            status = .needsAuth
        } else if let err = accountUsage.lastError {
            status = .error(err)
        } else {
            status = .needsAuth
        }

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .derived,
            status: status,
            windows: [],
            headlineID: "session",
            accountBadge: "\(slot)",
            isActive: isActive,
            accountDetail: "\(email) · \(isActive ? "Active" : "Slot \(slot)")"
        )
    }

    private static let isoFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterStandard: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseDate(_ string: String) -> Date? {
        isoFormatterWithFractionalSeconds.date(from: string) ?? isoFormatterStandard.date(from: string)
    }
}
