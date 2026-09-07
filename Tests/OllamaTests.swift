import XCTest
@testable import Codenotch

final class OllamaTests: XCTestCase {

    func testLogRequestParsing() {
        let logText = """
        [GIN] 2026/08/25 - 03:52:31 | 200 | 31.299752125s | 127.0.0.1 | POST "/api/generate"
        [GIN] 2026/08/25 - 03:53:00 | 200 | 12.794620875s | 127.0.0.1 | POST "/api/chat"
        [GIN] 2026/08/25 - 03:53:10 | 200 |    5.252083ms | 127.0.0.1 | GET "/api/tags"
        [GIN] 2026/08/25 - 03:54:00 | 429 |  100.000000ms | 127.0.0.1 | POST "/api/chat"
        """

        let requests = OllamaUsage.parseRequests(from: logText)
        XCTAssertEqual(requests.count, 3, "GET /api/tags should be filtered out")
        XCTAssertEqual(requests[0].path, "/api/generate")
        XCTAssertEqual(requests[0].statusCode, 200)
        XCTAssertEqual(requests[1].path, "/api/chat")
        XCTAssertEqual(requests[2].statusCode, 429)
    }

    func testLimitWindowsCalculation() {
        let now = Date()
        let oneHourAgo = now.addingTimeInterval(-3600)
        let twoDaysAgo = now.addingTimeInterval(-2 * 86400)
        let tenDaysAgo = now.addingTimeInterval(-10 * 86400)

        let requests = [
            OllamaUsage.RequestRecord(timestamp: oneHourAgo, statusCode: 200, method: "POST", path: "/api/chat"),
            OllamaUsage.RequestRecord(timestamp: twoDaysAgo, statusCode: 200, method: "POST", path: "/api/chat"),
            OllamaUsage.RequestRecord(timestamp: tenDaysAgo, statusCode: 200, method: "POST", path: "/api/chat")
        ]

        let (windows, block) = OllamaUsage.windows(requests: requests, now: now, sessionLimit: 10, weeklyLimit: 20)
        XCTAssertEqual(windows.count, 2)
        XCTAssertNil(block)

        let session = windows.first { $0.id == "session" }
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.used, 1, "Only request within 5 hours counts toward session")
        XCTAssertEqual(session?.usedFraction, 0.1)
        XCTAssertEqual(session?.remaining, 9)
        XCTAssertEqual(session?.resetsAt, oneHourAgo.addingTimeInterval(5 * 3600))

        let weekly = windows.first { $0.id == "weekly" }
        XCTAssertNotNil(weekly)
        XCTAssertEqual(weekly?.used, 2, "Requests within 7 days count toward weekly (1 hour ago + 2 days ago)")
        XCTAssertEqual(weekly?.usedFraction, 0.1)
        XCTAssertEqual(weekly?.remaining, 18)
    }

    func testRateLimitBlockDetected() {
        let now = Date()
        let thirtyMinutesAgo = now.addingTimeInterval(-1800)
        let requests = [
            OllamaUsage.RequestRecord(timestamp: thirtyMinutesAgo, statusCode: 429, method: "POST", path: "/api/chat")
        ]

        let (_, block) = OllamaUsage.windows(requests: requests, now: now)
        XCTAssertNotNil(block)
        XCTAssertEqual(block?.reason, "Ollama rate limit reached")
    }

    func testHeadlineSelection() {
        let sessionWindow = LimitWindow(id: "session", label: "5-hour session", usedFraction: 0.25)
        let weeklyWindow = LimitWindow(id: "weekly", label: "7-day weekly", usedFraction: 0.42)
        let snapshot = ProviderSnapshot(
            id: "ollama",
            displayName: "Ollama",
            glyph: .ollama,
            fidelity: .official,
            status: .ok,
            windows: [sessionWindow, weeklyWindow],
            headlineID: "session"
        )

        XCTAssertNotNil(snapshot.headline)
        XCTAssertEqual(snapshot.headline?.id, "session")
        XCTAssertEqual(snapshot.usedFraction, 0.25)
        XCTAssertEqual(snapshot.headlineText, "25%")
    }

    func testUsageArchivePreservesAccountState() {
        // Guardrail: multi-account isActive flag and badges must survive serialization
        let suiteName = "testUsageArchiveOllama"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let archive = UsageArchive(defaults: defaults)

        let snapshot = ProviderSnapshot(
            id: "ollama",
            displayName: "Ollama",
            glyph: .ollama,
            fidelity: .official,
            status: .ok,
            windows: [LimitWindow(id: "session", label: "Session", usedFraction: 0.25)],
            headlineID: "session",
            accountBadge: "Pro",
            isActive: true,
            accountDetail: "user@example.com · Pro"
        )

        let fetchDate = Date()
        archive.save(["ollama": (snapshot, fetchDate)])

        let loaded = archive.load()
        let loadedSnapshot = loaded["ollama"]?.snapshot

        XCTAssertNotNil(loadedSnapshot)
        XCTAssertEqual(loadedSnapshot?.isActive, true, "isActive must be preserved across archive saves")
        XCTAssertEqual(loadedSnapshot?.accountBadge, "Pro")
        XCTAssertEqual(loadedSnapshot?.accountDetail, "user@example.com · Pro")
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testOllamaGlyphOutline() {
        XCTAssertEqual(ProviderGlyph.ollama.assetName, "glyph-ollama")
        XCTAssertFalse(ProviderGlyph.ollama.outline.isEmpty)
        XCTAssertEqual(ProviderGlyph.ollama.opticalScale, 0.96)
    }
}
