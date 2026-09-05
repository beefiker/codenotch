import XCTest
@testable import Codenotch

final class GrokTests: XCTestCase {

    func testDecodeValidAuthJSON() throws {
        let json = """
        {
          "https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828": {
            "key": "test_access_token_123",
            "refresh_token": "test_refresh_token_456",
            "expires_at": "2026-09-06T03:08:11.651426Z",
            "email": "user@example.com",
            "user_id": "usr_12345",
            "oidc_issuer": "https://auth.x.ai",
            "oidc_client_id": "b1a00492-073a-47ea-816f-4c329264a828"
          }
        }
        """
        guard let data = json.data(using: .utf8),
              let creds = GrokCredentials.decode(data: data)
        else {
            XCTFail("Failed to decode valid auth.json")
            return
        }

        XCTAssertEqual(creds.accessToken, "test_access_token_123")
        XCTAssertEqual(creds.refreshToken, "test_refresh_token_456")
        XCTAssertEqual(creds.email, "user@example.com")
        XCTAssertEqual(creds.userId, "usr_12345")
        XCTAssertEqual(creds.issuer, "https://auth.x.ai")
        XCTAssertEqual(creds.clientId, "b1a00492-073a-47ea-816f-4c329264a828")
        XCTAssertNotNil(creds.expiresAt)
    }

    func testDecodeIgnoresEmptyEntries() {
        let json = """
        {
          "empty": {},
          "blank_key": { "key": "" }
        }
        """
        let data = json.data(using: .utf8)!
        XCTAssertNil(GrokCredentials.decode(data: data))
    }

    func testDateParsing() {
        let withFraction = "2026-09-06T03:08:11.651426Z"
        let plain = "2026-09-06T03:08:11Z"
        let invalid = "not-a-date"

        XCTAssertNotNil(GrokCredentials.parseDate(withFraction))
        XCTAssertNotNil(GrokCredentials.parseDate(plain))
        XCTAssertNil(GrokCredentials.parseDate(invalid))
    }

    func testExpiryStatus() {
        let past = Date().addingTimeInterval(-100)
        let near = Date().addingTimeInterval(120) // within 300s
        let far = Date().addingTimeInterval(3600)

        let pastCreds = GrokCredentials(
            accessToken: "token", refreshToken: nil, expiresAt: past,
            email: nil, userId: nil, issuer: "iss", clientId: "cid",
            entryKey: "k", authFileURL: URL(fileURLWithPath: "/tmp")
        )
        XCTAssertTrue(pastCreds.isExpired)
        XCTAssertTrue(pastCreds.isNearExpiry)

        let nearCreds = GrokCredentials(
            accessToken: "token", refreshToken: nil, expiresAt: near,
            email: nil, userId: nil, issuer: "iss", clientId: "cid",
            entryKey: "k", authFileURL: URL(fileURLWithPath: "/tmp")
        )
        XCTAssertFalse(nearCreds.isExpired)
        XCTAssertTrue(nearCreds.isNearExpiry)

        let farCreds = GrokCredentials(
            accessToken: "token", refreshToken: nil, expiresAt: far,
            email: nil, userId: nil, issuer: "iss", clientId: "cid",
            entryKey: "k", authFileURL: URL(fileURLWithPath: "/tmp")
        )
        XCTAssertFalse(farCreds.isExpired)
        XCTAssertFalse(farCreds.isNearExpiry)
    }

    func testGlyphOutline() {
        let loops = GlyphOutline.grok
        XCTAssertEqual(loops.count, 2)
        for loop in loops {
            XCTAssertFalse(loop.isEmpty)
            for pt in loop {
                XCTAssertGreaterThanOrEqual(pt.x, 0.0)
                XCTAssertLessThanOrEqual(pt.x, 1.0)
                XCTAssertGreaterThanOrEqual(pt.y, 0.0)
                XCTAssertLessThanOrEqual(pt.y, 1.0)
            }
        }
        XCTAssertEqual(ProviderGlyph.grok.opticalScale, 1.0)
        XCTAssertEqual(ProviderGlyph.grok.rawValue, "grok")
    }

    func testGrokActivityTurnCounting() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok_activity_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let wsDir = tempDir.appendingPathComponent("workspace1")
        let sessionDir = wsDir.appendingPathComponent("session1")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let nowString = formatter.string(from: now)
        let yesterdayString = formatter.string(from: now.addingTimeInterval(-86400 * 2))

        let eventsContent = """
        {"ts":"\(nowString)","type":"turn_started","session_id":"s1","turn_number":0}
        {"ts":"\(nowString)","type":"phase_changed","phase":"streaming_text"}
        {"ts":"\(nowString)","type":"turn_started","session_id":"s1","turn_number":1}
        {"ts":"\(yesterdayString)","type":"turn_started","session_id":"s1","turn_number":2}
        """
        let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
        try eventsContent.write(to: eventsFile, atomically: true, encoding: .utf8)

        let activity = GrokActivity.read(root: tempDir, now: now)
        XCTAssertEqual(activity.requestsToday, 2)
        XCTAssertNotNil(activity.lastRequest)
    }

    func testGrokActivityMonitorRecentEvents() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok_monitor_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let activeURL = tempDir.appendingPathComponent("active_sessions.json")
        try "[]".write(to: activeURL, atomically: true, encoding: .utf8)

        let sessionsRoot = tempDir.appendingPathComponent("sessions")
        let wsDir = sessionsRoot.appendingPathComponent("ws")
        let sessionDir = wsDir.appendingPathComponent("sess-abc")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
        try "{\"ts\":\"2026-09-06T00:00:00Z\",\"type\":\"turn_started\"}\n".write(
            to: eventsFile, atomically: true, encoding: .utf8
        )

        let summaryFile = sessionDir.appendingPathComponent("summary.json")
        let summaryContent = """
        {"info":{"id":"sess-abc"},"session_summary":"Fix bug in code"}
        """
        try summaryContent.write(to: summaryFile, atomically: true, encoding: .utf8)

        let now = Date()
        let sessions = GrokActivityMonitor.read(
            activeSessionsURL: activeURL,
            sessionsRoot: sessionsRoot,
            staleAfter: 45,
            now: now
        )

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.name, "Grok")
        XCTAssertEqual(sessions.first?.detail, "Fix bug in code")
        XCTAssertEqual(sessions.first?.state, .busy)

        // Beyond staleAfter: should be dropped as idle/finished
        let future = now.addingTimeInterval(100)
        let staleSessions = GrokActivityMonitor.read(
            activeSessionsURL: activeURL,
            sessionsRoot: sessionsRoot,
            staleAfter: 45,
            now: future
        )
        XCTAssertTrue(staleSessions.isEmpty)
    }
}
