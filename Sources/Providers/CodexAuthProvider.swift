import Foundation
import os

/// Models `~/.codex/accounts/registry.json`.
struct CodexAuthRegistry: Decodable {
    let schema_version: Int?
    let active_account_key: String?
    let accounts: [AccountRecord]?

    struct AccountRecord: Decodable {
        let account_key: String
        let email: String
        let alias: String?
        let account_name: String?
        let plan: String?
        let auth_mode: String?
        let last_usage: UsageRecord?
        let last_usage_at: Double?

        struct UsageRecord: Decodable {
            let primary: LimitRecord?
            let secondary: LimitRecord?
            let plan_type: String?

            struct LimitRecord: Decodable {
                let used_percent: Double?
                let window_minutes: Int?
                let resets_at: Double?
            }
        }
    }
}

/// Discovers managed accounts from `codex-auth`.
enum CodexAuthDiscovery {
    static var defaultRegistryURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/accounts/registry.json")
    }

    static func isAvailable(registryURL: URL = defaultRegistryURL) -> Bool {
        FileManager.default.fileExists(atPath: registryURL.path)
    }

    static func providers(registryURL: URL = defaultRegistryURL) -> [CodexAuthAccountProvider] {
        guard let data = try? Data(contentsOf: registryURL),
              let registry = try? JSONDecoder().decode(CodexAuthRegistry.self, from: data),
              let accounts = registry.accounts,
              !accounts.isEmpty
        else { return [] }

        let activeKey = registry.active_account_key

        return accounts.enumerated().map { index, account in
            let slot = index + 1
            let isActive = (account.account_key == activeKey)
            return CodexAuthAccountProvider(
                slot: slot,
                email: account.email,
                alias: account.alias,
                plan: account.plan,
                accountKey: account.account_key,
                isActive: isActive,
                registryURL: registryURL
            )
        }
    }
}

/// A provider representing an individual Codex account managed by `codex-auth`.
actor CodexAuthAccountProvider: UsageProvider {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let glyph = ProviderGlyph.openai

    nonisolated let slot: Int
    nonisolated let email: String
    nonisolated let alias: String?
    nonisolated let plan: String?
    nonisolated let accountKey: String
    nonisolated let isActive: Bool
    nonisolated let registryURL: URL

    init(
        slot: Int,
        email: String,
        alias: String? = nil,
        plan: String? = nil,
        accountKey: String,
        isActive: Bool = false,
        registryURL: URL = CodexAuthDiscovery.defaultRegistryURL
    ) {
        self.slot = slot
        self.email = email
        self.alias = alias
        self.plan = plan
        self.accountKey = accountKey
        self.isActive = isActive
        self.registryURL = registryURL

        self.id = "codex-auth-\(email)"

        let shortName: String
        if let alias, !alias.isEmpty {
            shortName = alias
        } else if let user = email.split(separator: "@").first, !user.isEmpty {
            shortName = String(user)
        } else {
            shortName = "#\(slot)"
        }
        self.displayName = "Codex (\(shortName))"
    }

    nonisolated func account() -> ProviderAccount? {
        let planTitle = (plan ?? "ChatGPT").capitalized
        return ProviderAccount(
            label: email,
            plan: isActive ? "\(planTitle) · Active" : planTitle,
            source: "codex-auth",
            manageURL: URL(string: "https://chatgpt.com/#settings/Account")
        )
    }

    nonisolated var signInRoute: SignInRoute {
        .command(
            title: "Switch to this account",
            explanation: "Switch active Codex account to \(email) via codex-auth."
        )
    }

    nonisolated func presentSignIn() {
        guard let exe = CLIBridge.codexAuthExecutable() else {
            Log.usage.error("codex-auth executable not found")
            return
        }
        Task {
            _ = await CLIBridge.run(executable: exe, arguments: ["switch", email])
        }
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        // If active, attempt live reading from the Codex app server
        if isActive, let live = await liveReading(), !live.windows.isEmpty {
            let planTitle = (plan ?? "ChatGPT").capitalized
            return ProviderSnapshot(
                id: id,
                displayName: displayName,
                glyph: glyph,
                fidelity: .official,
                status: .ok,
                windows: live.windows,
                headlineID: "primary",
                block: live.block,
                accountBadge: "\(slot)",
                isActive: true,
                accountDetail: "\(email) · \(planTitle) · Active"
            )
        }

        // Read usage from ~/.codex/accounts/registry.json
        guard let data = try? Data(contentsOf: registryURL),
              let registry = try? JSONDecoder().decode(CodexAuthRegistry.self, from: data),
              let record = registry.accounts?.first(where: { $0.email == self.email || $0.account_key == self.accountKey })
        else {
            return ProviderSnapshot(
                id: id,
                displayName: displayName,
                glyph: glyph,
                fidelity: .official,
                status: .stale(since: .distantPast),
                windows: [],
                headlineID: "primary",
                accountBadge: "\(slot)",
                isActive: isActive,
                accountDetail: "\(email)"
            )
        }

        var windows: [LimitWindow] = []
        var block: UsageBlock? = nil

        if let usage = record.last_usage {
            if let primary = usage.primary, let usedPct = primary.used_percent {
                let minutes = primary.window_minutes ?? 300
                let label: String
                if minutes == 300 {
                    label = "5-hour session"
                } else if minutes >= 10080 {
                    label = "Weekly"
                } else {
                    label = "\(minutes / 60)-hour session"
                }

                let resetsAt = primary.resets_at.map { Date(timeIntervalSince1970: $0) }
                let fraction = usedPct / 100.0
                windows.append(LimitWindow(
                    id: "primary",
                    label: label,
                    usedFraction: fraction,
                    resetsAt: resetsAt
                ))

                if fraction >= 1.0 {
                    block = UsageBlock(reason: "Limit reached", resetsAt: resetsAt)
                }
            }

            if let secondary = usage.secondary, let usedPct = secondary.used_percent {
                let minutes = secondary.window_minutes ?? 10080
                let label = minutes >= 10080 ? "Weekly" : "\(minutes / 60)-hour session"
                let resetsAt = secondary.resets_at.map { Date(timeIntervalSince1970: $0) }
                windows.append(LimitWindow(
                    id: "secondary",
                    label: label,
                    usedFraction: usedPct / 100.0,
                    resetsAt: resetsAt
                ))
            }
        }

        let recordedAt = record.last_usage_at.map { Date(timeIntervalSince1970: $0) }
        let status: ProviderStatus = Self.status(recordedAt: recordedAt)
        let planTitle = (record.plan ?? self.plan ?? "ChatGPT").capitalized
        let detail = "\(email) · \(planTitle)\(isActive ? " · Active" : "")"

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: status,
            windows: windows,
            headlineID: "primary",
            block: block,
            accountBadge: "\(slot)",
            isActive: isActive,
            accountDetail: detail
        )
    }

    private func liveReading() async -> (windows: [LimitWindow], block: UsageBlock?)? {
        guard let executable = CodexBridge.executable() else { return nil }
        let answer = await Task.detached(priority: .utility) { () -> Data? in
            do {
                return try CodexBridge.rateLimits(executable: executable)
            } catch {
                return nil
            }
        }.value
        guard let answer else { return nil }
        let windows = CodexBridge.windows(in: answer)
        guard !windows.isEmpty else { return nil }
        let block = CodexBridge.block(in: answer)
        return (windows, block)
    }

    static func status(recordedAt: Date?, now: Date = Date()) -> ProviderStatus {
        guard let recordedAt else { return .stale(since: .distantPast) }
        return now.timeIntervalSince(recordedAt) <= 15 * 60 ? .ok : .stale(since: recordedAt)
    }
}
