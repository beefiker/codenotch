import AppKit
import Foundation
import os

/// SuperGrok / Grok, as logged into the Grok CLI or Grok Bot app.
///
/// Authentication is loaded from `~/.grok/auth.json` and refreshed via `auth.x.ai`.
/// Account status and rolling rate limits are retrieved from `https://cli-chat-proxy.grok.com/v1`.
/// Real-time usage activity is also counted from local session logs.
actor GrokProvider: UsageProvider {
    nonisolated let id = "grok"
    nonisolated let displayName = "SuperGrok"
    nonisolated let glyph = ProviderGlyph.grok

    private let userEndpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/user")!
    private let billingEndpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/billing")!
    private let completionEndpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/chat/completions")!
    private let session: URLSession

    private struct BillingResponse: Decodable {
        struct Config: Decodable {
            let billingPeriodStart: String?
            let billingPeriodEnd: String?
        }
        let config: Config?
    }

    private var cachedBillingReset: (resetsAt: Date?, fetchedAt: Date)?

    private struct RateLimitCache {
        let limitRequests: Int
        let remainingRequests: Int
        let limitTokens: Int
        let remainingTokens: Int
        let fetchedAt: Date
    }

    private var cachedLimits: RateLimitCache?

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

        // 1. Verify user profile and block status
        var userRequest = URLRequest(url: userEndpoint)
        userRequest.httpMethod = "GET"
        userRequest.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        userRequest.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        userRequest.timeoutInterval = 10

        let (userData, userResponse) = try await session.data(for: userRequest)
        let userStatus = (userResponse as? HTTPURLResponse)?.statusCode ?? 0

        if userStatus == 401 {
            GrokCredentials.forgetCached()
            throw UsageProviderError.needsAuth
        }
        if userStatus == 403 {
            throw UsageProviderError.needsAuth
        }
        if userStatus == 429 {
            let retry = (userResponse as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw UsageProviderError.rateLimited(retryAfter: retry ?? 0)
        }
        guard userStatus == 200 else {
            throw UsageProviderError.badResponse(status: userStatus)
        }

        var block: UsageBlock?
        if let user = try? JSONDecoder().decode(UserInfoResponse.self, from: userData) {
            if let reason = user.userBlockedReason, !reason.isEmpty {
                block = UsageBlock(reason: reason, resetsAt: nil)
            } else if let teamReason = user.teamBlockedReasons?.first, !teamReason.isEmpty {
                block = UsageBlock(reason: teamReason, resetsAt: nil)
            }
        }

        // 2. Query live rate limits and billing cycle from cli-chat-proxy
        async let limitsTask = fetchRateLimits(token: credentials.accessToken)
        async let billingTask = fetchBillingReset(token: credentials.accessToken)
        let (limits, billingResetsAt) = await (limitsTask, billingTask)

        let activity = GrokActivity.read()

        var usedRequests = max(0, limits.limitRequests - limits.remainingRequests)
        if usedRequests == 0 && activity.requestsToday > 0 {
            usedRequests = activity.requestsToday
        }
        let reqFraction = limits.limitRequests > 0
            ? Double(usedRequests) / Double(limits.limitRequests)
            : 0.0

        let usedTokens = max(0, limits.limitTokens - limits.remainingTokens)
        let tokFraction = limits.limitTokens > 0
            ? Double(usedTokens) / Double(limits.limitTokens)
            : 0.0

        var windows: [LimitWindow] = []

        // Primary window: Request allowance
        windows.append(
            LimitWindow(
                id: "requests",
                label: "Requests · SuperGrok",
                usedFraction: reqFraction,
                remaining: max(0, limits.limitRequests - usedRequests),
                used: usedRequests,
                resetsAt: billingResetsAt
            )
        )

        // Secondary window: Token quota
        windows.append(
            LimitWindow(
                id: "tokens",
                label: "Tokens · SuperGrok",
                usedFraction: tokFraction,
                remaining: max(0, limits.limitTokens - usedTokens),
                used: usedTokens,
                resetsAt: billingResetsAt
            )
        )

        // Tertiary window: Turns / local activity
        let activityLabel = activity.requestsToday > 0
            ? "Turns today"
            : (activity.totalTurns > 0 ? "Total turns logged" : "Turns")
        let activityCount = activity.requestsToday > 0
            ? activity.requestsToday
            : (activity.totalTurns > 0 ? activity.totalTurns : 0)

        windows.append(
            LimitWindow(
                id: "activity",
                label: activityLabel,
                used: activityCount
            )
        )

        let resetCopy = billingResetsAt.map { ResetCopy.text(for: $0) }
        var detailParts: [String] = []
        if let email = credentials.email {
            detailParts.append("SuperGrok · \(email)")
        } else {
            detailParts.append("SuperGrok")
        }
        if let resetCopy {
            detailParts.append(resetCopy)
        }
        let detail = detailParts.joined(separator: " · ")

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: windows,
            headlineID: "requests",
            block: block,
            isActive: true,
            accountDetail: detail
        )
    }

    private func fetchRateLimits(token: String) async -> RateLimitCache {
        // Cache limits for 5 minutes when not busy
        if let cached = cachedLimits, Date().timeIntervalSince(cached.fetchedAt) < 300 {
            return cached
        }

        var req = URLRequest(url: completionEndpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        req.setValue("1.0.13", forHTTPHeaderField: "x-grok-client-version")
        req.setValue("grok-shell", forHTTPHeaderField: "x-grok-client-identifier")
        req.setValue("xai-grok-workspace/1.0.13", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10

        let body: [String: Any] = [
            "model": "grok-4.6",
            "messages": [["role": "user", "content": "ping"]],
            "max_tokens": 1,
            "stream": false
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (_, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200
        else {
            return cachedLimits ?? RateLimitCache(
                limitRequests: 8300,
                remainingRequests: 8300,
                limitTokens: 53000000,
                remainingTokens: 53000000,
                fetchedAt: Date()
            )
        }

        let limReq = http.value(forHTTPHeaderField: "x-ratelimit-limit-requests").flatMap(Int.init) ?? 8300
        let remReq = http.value(forHTTPHeaderField: "x-ratelimit-remaining-requests").flatMap(Int.init) ?? limReq
        let limTok = http.value(forHTTPHeaderField: "x-ratelimit-limit-tokens").flatMap(Int.init) ?? 53000000
        let remTok = http.value(forHTTPHeaderField: "x-ratelimit-remaining-tokens").flatMap(Int.init) ?? limTok

        let fresh = RateLimitCache(
            limitRequests: limReq,
            remainingRequests: remReq,
            limitTokens: limTok,
            remainingTokens: remTok,
            fetchedAt: Date()
        )
        cachedLimits = fresh
        return fresh
    }

    private func fetchBillingReset(token: String) async -> Date? {
        if let cached = cachedBillingReset, Date().timeIntervalSince(cached.fetchedAt) < 300 {
            return cached.resetsAt
        }

        var req = URLRequest(url: billingEndpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        req.setValue("1.0.13", forHTTPHeaderField: "x-grok-client-version")
        req.setValue("grok-shell", forHTTPHeaderField: "x-grok-client-identifier")
        req.setValue("xai-grok-workspace/1.0.13", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10

        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let billing = try? JSONDecoder().decode(BillingResponse.self, from: data),
              let endStr = billing.config?.billingPeriodEnd,
              let date = GrokCredentials.parseDate(endStr)
        else {
            let fallback = Calendar.current.nextDate(
                after: Date(),
                matching: DateComponents(day: 1, hour: 0, minute: 0),
                matchingPolicy: .nextTime
            )
            let result = cachedBillingReset?.resetsAt ?? fallback
            if cachedBillingReset == nil, let result {
                cachedBillingReset = (resetsAt: result, fetchedAt: Date())
            }
            return result
        }

        cachedBillingReset = (resetsAt: date, fetchedAt: Date())
        return date
    }
}
