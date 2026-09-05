import AppKit
import Foundation
import os

/// SuperGrok / Grok, as logged into the Grok CLI or Grok Bot app.
///
/// Authentication is loaded from `~/.grok/auth.json` and refreshed via `auth.x.ai`.
/// Account status is verified against `https://cli-chat-proxy.grok.com/v1/user`.
/// Real-time usage activity (turns today) is counted from local session logs.
actor GrokProvider: UsageProvider {
    nonisolated let id = "grok"
    nonisolated let displayName = "SuperGrok"
    nonisolated let glyph = ProviderGlyph.grok

    private let userEndpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/user")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    nonisolated var signInRoute: SignInRoute {
        .openApp(bundleID: "com.anysphere.sand", name: "Grok")
    }

    nonisolated func forgetCachedCredential() {
        GrokCredentials.forgetCached()
    }

    nonisolated func signOut() async {
        GrokCredentials.forgetCached()
    }

    nonisolated func presentSignIn() {
        if let url = URL(string: "https://grok.com") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated func account() -> ProviderAccount? {
        guard let credentials = try? GrokCredentials.load() else { return nil }
        return ProviderAccount(
            label: credentials.email,
            plan: "SuperGrok",
            source: "Grok",
            manageURL: URL(string: "https://grok.com")
        )
    }

    private struct UserInfoResponse: Decodable {
        let userId: String?
        let email: String?
        let firstName: String?
        let lastName: String?
        let userBlockedReason: String?
        let teamBlockedReasons: [String]?
        let hasGrokCodeAccess: Bool?
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        var credentials = try GrokCredentials.load()

        if credentials.isNearExpiry || credentials.isExpired {
            credentials = try await credentials.refresh(session: session)
        }

        var request = URLRequest(url: userEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 401 {
            GrokCredentials.forgetCached()
            throw UsageProviderError.needsAuth
        }
        if status == 403 {
            throw UsageProviderError.needsAuth
        }
        if status == 429 {
            let retry = (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw UsageProviderError.rateLimited(retryAfter: retry ?? 0)
        }
        guard status == 200 else {
            throw UsageProviderError.badResponse(status: status)
        }

        var block: UsageBlock?
        if let user = try? JSONDecoder().decode(UserInfoResponse.self, from: data) {
            if let reason = user.userBlockedReason, !reason.isEmpty {
                block = UsageBlock(reason: reason, resetsAt: nil)
            } else if let teamReason = user.teamBlockedReasons?.first, !teamReason.isEmpty {
                block = UsageBlock(reason: teamReason, resetsAt: nil)
            }
        }

        let activity = GrokActivity.read()
        let detail = credentials.email.map { "SuperGrok · \($0)" } ?? "SuperGrok"

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .derived,
            status: .ok,
            windows: [
                LimitWindow(
                    id: "requests",
                    label: "Turns today · SuperGrok",
                    used: activity.requestsToday
                )
            ],
            block: block,
            isActive: true,
            accountDetail: detail
        )
    }
}
