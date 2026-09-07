import Foundation
import os

/// Ollama usage provider for local and cloud models with session and weekly quotas.
actor OllamaProvider: UsageProvider {
    nonisolated let id = "ollama"
    nonisolated let displayName = "Ollama"
    nonisolated let glyph = ProviderGlyph.ollama

    private let endpoint: URL
    private let logURL: URL
    private let session: URLSession

    init(
        endpoint: URL = OllamaCredentials.defaultEndpoint,
        logURL: URL = OllamaUsage.defaultLogURL,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.logURL = logURL
        self.session = session
    }

    nonisolated var signInRoute: SignInRoute {
        .command(
            title: "Run 'ollama signin'",
            explanation: "Run 'ollama signin' in Terminal to connect to your Ollama subscription"
        )
    }

    nonisolated func forgetCachedCredential() {
        OllamaCredentials.forgetCached()
    }

    nonisolated func account() -> ProviderAccount? {
        OllamaCredentials.account(endpoint: endpoint)
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        // 1. Verify credentials / daemon status
        let creds = await OllamaCredentials.load(endpoint: endpoint, session: session)
        guard creds != nil || FileManager.default.fileExists(atPath: OllamaCredentials.keyURL.path) else {
            throw UsageProviderError.needsAuth
        }

        // 2. Read recent request logs for rolling quota calculation
        let requests = OllamaUsage.recentRequests(from: logURL)
        let (windows, block) = OllamaUsage.windows(requests: requests)

        let accountLabel = creds?.email ?? creds?.name ?? "Ollama"
        let plan = creds?.plan ?? "Pro"
        let accountDetail = "\(accountLabel) · \(plan)"

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: creds != nil ? .official : .derived,
            status: .ok,
            windows: windows,
            headlineID: "session",
            block: block,
            accountDetail: accountDetail
        )
    }
}
