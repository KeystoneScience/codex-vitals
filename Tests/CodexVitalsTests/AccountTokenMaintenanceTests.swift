import Foundation
import XCTest
@testable import CodexVitals

final class AccountTokenMaintenanceTests: XCTestCase {
    func testDailyCheckIsDueOnFirstLaunchAndAfterTwentyFourHours() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertTrue(AccountTokenMaintenance.isDue(lastSuccessfulCheck: nil, now: now))
        XCTAssertTrue(AccountTokenMaintenance.isDue(lastSuccessfulCheck: now.addingTimeInterval(-86400), now: now))
        XCTAssertFalse(AccountTokenMaintenance.isDue(lastSuccessfulCheck: now.addingTimeInterval(-86399), now: now))
    }

    func testClaudeRenewalIsDueWithoutHistoryOrAfterOneDay() throws {
        let now = Date()
        var root: [String: Any] = ["claudeAiOauth": [
            "accessToken": "test-access",
            "refreshToken": "test-refresh",
            "expiresAt": now.addingTimeInterval(7 * 86400).timeIntervalSince1970 * 1000,
        ]]
        XCTAssertTrue(try envelope(root).needsRefresh(at: now))
        root["headroomLastRefreshAt"] = now.addingTimeInterval(-86400).timeIntervalSince1970
        XCTAssertTrue(try envelope(root).needsRefresh(at: now))
        root["headroomLastRefreshAt"] = now.addingTimeInterval(-3600).timeIntervalSince1970
        XCTAssertFalse(try envelope(root).needsRefresh(at: now))
    }

    func testClaudeExpiryStillTriggersRenewalBeforeDailyDeadline() throws {
        let now = Date()
        let root: [String: Any] = [
            "headroomLastRefreshAt": now.timeIntervalSince1970,
            "claudeAiOauth": ["accessToken": "test-access", "expiresAt": now.addingTimeInterval(300).timeIntervalSince1970 * 1000],
        ]
        XCTAssertTrue(try envelope(root).needsRefresh(at: now))
    }

    func testClaudeReplacementRecordsDailyRenewalAndRotatedRefreshToken() throws {
        let original = try envelope(["claudeAiOauth": ["accessToken": "old", "refreshToken": "old-refresh"]])
        let response = try JSONDecoder().decode(ClaudeTokenResponse.self, from: Data(#"{"access_token":"new","refresh_token":"new-refresh","expires_in":172800}"#.utf8))
        let updated = try ClaudeCredentialEnvelope(rawValue: original.replacingOAuth(with: response))
        XCTAssertEqual(updated.refreshToken, "new-refresh")
        XCTAssertFalse(updated.needsRefresh())
        XCTAssertNotNil(updated.root["headroomLastRefreshAt"])
    }

    private func envelope(_ object: [String: Any]) throws -> ClaudeCredentialEnvelope {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try ClaudeCredentialEnvelope(rawValue: XCTUnwrap(String(data: data, encoding: .utf8)))
    }
}
