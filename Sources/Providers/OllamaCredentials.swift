import Foundation
import os

/// Credentials and account information for Ollama.
///
/// Discovers identity from the local Ollama daemon (`POST /api/me`), falling back
/// to local SSH public keys (`~/.ollama/id_ed25519.pub`) and configuration files
/// if the daemon is offline.
struct OllamaCredentials: Equatable {
    let id: String?
    let email: String?
    let name: String?
    let plan: String?

    static var defaultOllamaHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ollama")
    }

    static var keyURL: URL {
        defaultOllamaHome.appendingPathComponent("id_ed25519")
    }

    static var defaultEndpoint: URL {
        URL(string: "http://127.0.0.1:11434")!
    }

    private static var cachedAccount: ProviderAccount?
    private static var lastChecked: Date?

    static func forgetCached() {
        cachedAccount = nil
        lastChecked = nil
    }

    /// Identity for the settings sheet and notch card.
    static func account(endpoint: URL = defaultEndpoint) -> ProviderAccount? {
        if let cached = cachedAccount, let last = lastChecked, Date().timeIntervalSince(last) < 60 {
            return cached
        }

        // 1. Try local daemon /api/me synchronously if possible, or use cached
        if let live = fetchLocalAccount(endpoint: endpoint) {
            cachedAccount = live
            lastChecked = Date()
            return live
        }

        // 2. Check if signed in via SSH key or config
        if FileManager.default.fileExists(atPath: keyURL.path) {
            let acct = ProviderAccount(
                label: cachedAccount?.label ?? "Ollama User",
                plan: cachedAccount?.plan ?? "Pro",
                source: "Ollama",
                manageURL: URL(string: "https://ollama.com/settings")
            )
            cachedAccount = acct
            lastChecked = Date()
            return acct
        }

        return cachedAccount
    }

    /// Fetch account details from the local Ollama daemon.
    static func fetchLocalAccount(endpoint: URL = defaultEndpoint, timeout: TimeInterval = 1.0) -> ProviderAccount? {
        let meURL = endpoint.appendingPathComponent("api/me")
        var request = URLRequest(url: meURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout

        let semaphore = DispatchSemaphore(value: 0)
        var result: ProviderAccount?

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard let data,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200
            else { return }

            struct UserResponse: Decodable {
                let id: String?
                let email: String?
                let name: String?
                let plan: String?
            }

            guard let user = try? JSONDecoder().decode(UserResponse.self, from: data) else { return }
            let planDisplay = user.plan.map { $0.capitalized } ?? "Pro"
            let label = user.email ?? user.name ?? "Ollama User"
            result = ProviderAccount(
                label: label,
                plan: planDisplay,
                source: "Ollama",
                manageURL: URL(string: "https://ollama.com/settings")
            )
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 0.2)
        return result
    }

    /// Asynchronously fetch account info for provider refreshes.
    static func load(endpoint: URL = defaultEndpoint, session: URLSession = .shared) async -> OllamaCredentials? {
        let meURL = endpoint.appendingPathComponent("api/me")
        var request = URLRequest(url: meURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 3.0

        if let (data, response) = try? await session.data(for: request),
           let http = response as? HTTPURLResponse,
           http.statusCode == 200 {
            struct UserResponse: Decodable {
                let id: String?
                let email: String?
                let name: String?
                let plan: String?
            }
            if let user = try? JSONDecoder().decode(UserResponse.self, from: data) {
                let creds = OllamaCredentials(
                    id: user.id,
                    email: user.email,
                    name: user.name,
                    plan: user.plan?.capitalized ?? "Pro"
                )
                let acct = ProviderAccount(
                    label: creds.email ?? creds.name ?? "Ollama User",
                    plan: creds.plan ?? "Pro",
                    source: "Ollama",
                    manageURL: URL(string: "https://ollama.com/settings")
                )
                cachedAccount = acct
                lastChecked = Date()
                return creds
            }
        }

        // Fallback if local key exists
        if FileManager.default.fileExists(atPath: keyURL.path) {
            return OllamaCredentials(
                id: nil,
                email: cachedAccount?.label,
                name: nil,
                plan: cachedAccount?.plan ?? "Pro"
            )
        }

        return nil
    }
}
