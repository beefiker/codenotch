import XCTest
@testable import Codenotch

final class MultiAccountProviderTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codenotch-multi-account-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - ClaudeSwapDiscovery Tests

    func testClaudeSwapDiscoveryParsesAccounts() throws {
        let sequenceJSON = """
        {
          "activeAccountNumber": 2,
          "sequence": [1, 2],
          "accounts": {
            "1": {
              "email": "labdev15@labradorlabs.ai",
              "organizationName": "Labrador Labs",
              "alias": "dev15"
            },
            "2": {
              "email": "labdev08@labradorlabs.ai",
              "organizationName": "Labrador Labs",
              "alias": "dev08"
            }
          }
        }
        """
        try sequenceJSON.write(
            to: tempDir.appendingPathComponent("sequence.json"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertTrue(ClaudeSwapDiscovery.isAvailable(backupDir: tempDir))

        let providers = ClaudeSwapDiscovery.providers(backupDir: tempDir)
        XCTAssertEqual(providers.count, 2)

        let p1 = providers[0]
        XCTAssertEqual(p1.id, "claude-swap-1")
        XCTAssertEqual(p1.displayName, "Claude (dev15)")
        XCTAssertEqual(p1.slot, 1)
        XCTAssertEqual(p1.email, "labdev15@labradorlabs.ai")
        XCTAssertFalse(p1.isActive)

        let p2 = providers[1]
        XCTAssertEqual(p2.id, "claude-swap-2")
        XCTAssertEqual(p2.displayName, "Claude (dev08)")
        XCTAssertEqual(p2.slot, 2)
        XCTAssertEqual(p2.email, "labdev08@labradorlabs.ai")
        XCTAssertTrue(p2.isActive)
    }

    func testClaudeSwapCachedSnapshotReadsUsage() async throws {
        let sequenceJSON = """
        {
          "activeAccountNumber": 2,
          "sequence": [1],
          "accounts": {
            "1": {
              "email": "user@example.com",
              "organizationName": "Team"
            }
          }
        }
        """
        try sequenceJSON.write(
            to: tempDir.appendingPathComponent("sequence.json"),
            atomically: true,
            encoding: .utf8
        )

        let cacheDir = tempDir.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let usageJSON = """
        {
          "schemaVersion": 1,
          "accounts": {
            "1": {
              "email": "user@example.com",
              "fetchedAt": \(Date().timeIntervalSince1970),
              "lastGood": {
                "five_hour": {
                  "pct": 34.5,
                  "resets_at": "2026-09-06T12:00:00Z"
                },
                "seven_day": {
                  "pct": 12.0,
                  "resets_at": "2026-09-10T12:00:00Z"
                }
              }
            }
          }
        }
        """
        try usageJSON.write(
            to: cacheDir.appendingPathComponent("usage.json"),
            atomically: true,
            encoding: .utf8
        )

        let providers = ClaudeSwapDiscovery.providers(backupDir: tempDir)
        XCTAssertEqual(providers.count, 1)

        let snapshot = try await providers[0].fetchSnapshot()
        XCTAssertEqual(snapshot.id, "claude-swap-1")
        XCTAssertEqual(snapshot.accountBadge, "1")
        XCTAssertFalse(snapshot.isActive)
        XCTAssertEqual(snapshot.windows.count, 2)

        let sessionWindow = snapshot.windows.first { $0.id == "session" }
        XCTAssertNotNil(sessionWindow)
        XCTAssertEqual(sessionWindow?.usedFraction ?? 0, 0.345, accuracy: 0.001)

        let weeklyWindow = snapshot.windows.first { $0.id == "all-models" }
        XCTAssertNotNil(weeklyWindow)
        XCTAssertEqual(weeklyWindow?.usedFraction ?? 0, 0.12, accuracy: 0.001)
    }

    func testClaudeSwapSignInRouteIsCommand() throws {
        let provider = ClaudeSwapAccountProvider(
            slot: 3,
            email: "engineer@example.com",
            alias: "eng",
            isActive: false,
            backupDir: tempDir
        )

        guard case let .command(title, explanation) = provider.signInRoute else {
            return XCTFail("Expected .command route")
        }
        XCTAssertEqual(title, "Switch to Slot 3")
        XCTAssertTrue(explanation.contains("Slot 3"))
        XCTAssertTrue(explanation.contains("engineer@example.com"))
    }

    // MARK: - CodexAuthDiscovery Tests

    func testCodexAuthDiscoveryParsesAccounts() throws {
        let registryJSON = """
        {
          "schema_version": 1,
          "active_account_key": "acc_02",
          "accounts": [
            {
              "account_key": "acc_01",
              "email": "beefiker@gmail.com",
              "alias": "01",
              "plan": "free"
            },
            {
              "account_key": "acc_02",
              "email": "indobeefiker@gmail.com",
              "alias": "02",
              "plan": "plus"
            },
            {
              "account_key": "acc_03",
              "email": "jaeyeong.bee@gmail.com",
              "alias": "03",
              "plan": "pro"
            }
          ]
        }
        """
        let registryURL = tempDir.appendingPathComponent("registry.json")
        try registryJSON.write(to: registryURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(CodexAuthDiscovery.isAvailable(registryURL: registryURL))

        let providers = CodexAuthDiscovery.providers(registryURL: registryURL)
        XCTAssertEqual(providers.count, 3)

        XCTAssertEqual(providers[0].slot, 1)
        XCTAssertEqual(providers[0].email, "beefiker@gmail.com")
        XCTAssertEqual(providers[0].displayName, "Codex (01)")
        XCTAssertFalse(providers[0].isActive)

        XCTAssertEqual(providers[1].slot, 2)
        XCTAssertEqual(providers[1].email, "indobeefiker@gmail.com")
        XCTAssertEqual(providers[1].displayName, "Codex (02)")
        XCTAssertTrue(providers[1].isActive)

        XCTAssertEqual(providers[2].slot, 3)
        XCTAssertEqual(providers[2].email, "jaeyeong.bee@gmail.com")
        XCTAssertEqual(providers[2].displayName, "Codex (03)")
        XCTAssertFalse(providers[2].isActive)
    }

    func testCodexAuthSnapshotReadsRegistryUsage() async throws {
        let now = Date().timeIntervalSince1970
        let resetTime = now + 7200
        let registryJSON = """
        {
          "schema_version": 1,
          "active_account_key": "acc_02",
          "accounts": [
            {
              "account_key": "acc_01",
              "email": "dev@example.com",
              "plan": "pro",
              "last_usage_at": \(now),
              "last_usage": {
                "primary": {
                  "used_percent": 68.0,
                  "window_minutes": 300,
                  "resets_at": \(resetTime)
                },
                "secondary": {
                  "used_percent": 15.0,
                  "window_minutes": 10080,
                  "resets_at": \(resetTime + 86400)
                }
              }
            }
          ]
        }
        """
        let registryURL = tempDir.appendingPathComponent("registry.json")
        try registryJSON.write(to: registryURL, atomically: true, encoding: .utf8)

        let provider = CodexAuthAccountProvider(
            slot: 1,
            email: "dev@example.com",
            alias: "dev",
            plan: "pro",
            accountKey: "acc_01",
            isActive: false,
            registryURL: registryURL
        )

        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.id, "codex-auth-dev@example.com")
        XCTAssertEqual(snapshot.accountBadge, "1")
        XCTAssertFalse(snapshot.isActive)
        XCTAssertEqual(snapshot.windows.count, 2)

        let primary = snapshot.windows.first { $0.id == "primary" }
        XCTAssertNotNil(primary)
        XCTAssertEqual(primary?.label, "5-hour session")
        XCTAssertEqual(primary?.usedFraction ?? 0, 0.68, accuracy: 0.001)

        let secondary = snapshot.windows.first { $0.id == "secondary" }
        XCTAssertNotNil(secondary)
        XCTAssertEqual(secondary?.label, "Weekly")
        XCTAssertEqual(secondary?.usedFraction ?? 0, 0.15, accuracy: 0.001)
    }

    func testCodexAuthSignInRouteIsCommand() throws {
        let provider = CodexAuthAccountProvider(
            slot: 2,
            email: "indobeefiker@gmail.com",
            accountKey: "acc_02",
            registryURL: tempDir.appendingPathComponent("registry.json")
        )

        guard case let .command(title, explanation) = provider.signInRoute else {
            return XCTFail("Expected .command route")
        }
        XCTAssertEqual(title, "Switch to this account")
        XCTAssertTrue(explanation.contains("indobeefiker@gmail.com"))
    }

    // MARK: - NotchViewModel Multi-Account Routing

    @MainActor
    func testMultiAccountSessionRouting() {
        let model = NotchViewModel()
        let activeSession = AgentSession(
            id: "claude.123",
            name: "Work",
            detail: "Terminal",
            state: .busy,
            waitingFor: nil,
            since: Date()
        )
        model.sessions = ["claude": [activeSession]]

        model.snapshots = [
            ProviderSnapshot(
                id: "claude-swap-1",
                displayName: "Claude (slot1)",
                glyph: .claude,
                fidelity: .official,
                status: .ok,
                windows: [],
                accountBadge: "1",
                isActive: false
            ),
            ProviderSnapshot(
                id: "claude-swap-2",
                displayName: "Claude (slot2)",
                glyph: .claude,
                fidelity: .official,
                status: .ok,
                windows: [],
                accountBadge: "2",
                isActive: true
            )
        ]

        let activity1 = model.activity(for: "claude-swap-1")
        XCTAssertTrue(activity1?.sessions.isEmpty ?? true, "Inactive account should not steal session")

        let activity2 = model.activity(for: "claude-swap-2")
        XCTAssertEqual(activity2?.sessions.count, 1)
        XCTAssertEqual(activity2?.sessions.first?.id, "claude.123")
    }

    // MARK: - 5-Account Geometry & Layout Tests

    func testFiveAccountsProduceValidNotchLength() {
        let length1 = NotchLayout.shapeLength(cellCount: 1)
        let length5 = NotchLayout.shapeLength(cellCount: 5)
        XCTAssertGreaterThan(length5, length1)

        let pitch = NotchLayout.cellPitch(for: .right)
        for i in 0..<5 {
            let center = NotchLayout.ringCenter(index: i)
            XCTAssertGreaterThan(center, 0)
            if i > 0 {
                let prevCenter = NotchLayout.ringCenter(index: i - 1)
                XCTAssertEqual(center - prevCenter, pitch, accuracy: 0.01)
            }
        }
    }
}
