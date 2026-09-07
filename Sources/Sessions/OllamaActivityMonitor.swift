import AppKit
import Combine
import Foundation

/// Monitors live activity from Ollama inference requests.
///
/// Queries `http://127.0.0.1:11434/api/ps` to detect active models in memory,
/// and checks `server.log` recent modifications to illuminate the activity arc in the notch.
@MainActor
final class OllamaActivityMonitor: ObservableObject, AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    private let endpoint: URL
    private let logURL: URL
    private let interval: TimeInterval
    private let staleAfter: TimeInterval
    private var timer: Timer?

    init(
        endpoint: URL = OllamaCredentials.defaultEndpoint,
        logURL: URL = OllamaUsage.defaultLogURL,
        interval: TimeInterval = 2,
        staleAfter: TimeInterval = 6
    ) {
        self.endpoint = endpoint
        self.logURL = logURL
        self.interval = interval
        self.staleAfter = staleAfter
    }

    func start() {
        rescan()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func rescan() {
        // Fast file-check first
        let logModified = (try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.modificationDate] as? Date
        let isRecentlyActive = logModified.map { Date().timeIntervalSince($0) <= staleAfter } ?? false

        // Check running models from /api/ps asynchronously
        Task { [weak self] in
            guard let self else { return }
            let models = await self.fetchRunningModels()
            let found = self.buildSessions(models: models, isLogActive: isRecentlyActive)
            if self.sessions != found {
                self.sessions = found
            }
        }
    }

    private func fetchRunningModels() async -> [String] {
        let psURL = endpoint.appendingPathComponent("api/ps")
        var request = URLRequest(url: psURL)
        request.timeoutInterval = 1.0

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200
        else { return [] }

        struct PsResponse: Decodable {
            struct ModelEntry: Decodable {
                let name: String?
                let model: String?
            }
            let models: [ModelEntry]?
        }

        guard let decoded = try? JSONDecoder().decode(PsResponse.self, from: data),
              let models = decoded.models
        else { return [] }

        return models.compactMap { $0.name ?? $0.model }
    }

    private func buildSessions(models: [String], isLogActive: Bool) -> [AgentSession] {
        if !models.isEmpty {
            return models.map { name in
                AgentSession(
                    id: "ollama.\(name)",
                    name: name,
                    detail: "Generating",
                    state: .busy,
                    waitingFor: nil,
                    since: Date()
                )
            }
        }

        if isLogActive {
            return [
                AgentSession(
                    id: "ollama.active",
                    name: "Ollama",
                    detail: "Working",
                    state: .busy,
                    waitingFor: nil,
                    since: Date()
                )
            ]
        }

        return []
    }
}
