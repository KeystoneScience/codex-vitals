import CryptoKit
import XCTest
@testable import CodexVitals

final class CodexTokenRefreshServiceTests: XCTestCase {
    func testAuthErrorClassificationIsCaseInsensitive() {
        XCTAssertEqual(
            UsageService.authErrorCode(from: ["detail": ["code": "token_expired"]]),
            "token_expired"
        )
        XCTAssertTrue(UsageService.isRecoverableAuthError("token expired"))
        XCTAssertTrue(UsageService.requiresRelogin("REFRESH FAILED - RE-LOGIN REQUIRED"))
    }

    func testProactiveRefreshUsesFiveMinuteBoundary() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let withinWindow = try XCTUnwrap(StoredCodexAuth.parse(root: authRoot(
            now: now,
            accessExpiresAt: now.addingTimeInterval(5 * 60).timeIntervalSince1970
        )))
        let outsideWindow = try XCTUnwrap(StoredCodexAuth.parse(root: authRoot(
            now: now,
            accessExpiresAt: now.addingTimeInterval(6 * 60).timeIntervalSince1970
        )))

        XCTAssertTrue(CodexTokenRefreshService.shouldRefresh(withinWindow, at: now))
        XCTAssertFalse(CodexTokenRefreshService.shouldRefresh(outsideWindow, at: now))
    }

    func testDailyFallbackAppliesWhenTokenExpiryIsUnavailable() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var root = authRoot(now: now, accessExpiresAt: now.timeIntervalSince1970)
        var tokens = try XCTUnwrap(root["tokens"] as? [String: Any])
        tokens["id_token"] = jwt([
            "sub": "subject-test",
            "email": "test@example.com",
            "https://api.openai.com/auth": ["chatgpt_account_id": "account-test"],
        ])
        tokens["access_token"] = jwt([:])
        root["tokens"] = tokens
        root["last_refresh"] = ISO8601DateFormatter.codexVitals.string(
            from: now.addingTimeInterval(-24 * 60 * 60)
        )
        let auth = try XCTUnwrap(StoredCodexAuth.parse(root: root))

        XCTAssertTrue(CodexTokenRefreshService.shouldRefresh(auth, at: now))
    }

    func testDailyRenewalRefreshesTokensEvenWithLongRemainingLifetime() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var root = authRoot(now: now, accessExpiresAt: now.addingTimeInterval(7 * 24 * 60 * 60).timeIntervalSince1970)
        root["last_refresh"] = ISO8601DateFormatter.codexVitals.string(from: now.addingTimeInterval(-24 * 60 * 60))
        XCTAssertTrue(CodexTokenRefreshService.shouldRefresh(try XCTUnwrap(StoredCodexAuth.parse(root: root)), at: now))
        root["last_refresh"] = ISO8601DateFormatter.codexVitals.string(from: now.addingTimeInterval(-23 * 60 * 60))
        XCTAssertFalse(CodexTokenRefreshService.shouldRefresh(try XCTUnwrap(StoredCodexAuth.parse(root: root)), at: now))
    }

    func testCanonicalAuthHydratesStaleAccountsCache() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let collection = AccountProfileCollection(
            profiles: [fixture.profileKey: fixture.staleProfile],
            orderedKeys: [fixture.profileKey],
            workspaceAliases: [:]
        )
        let hydrated = fixture.store.hydrate(collection)

        XCTAssertEqual(hydrated.profiles[fixture.profileKey]?["access"] as? String, fixture.storedAccessToken)
        XCTAssertEqual(hydrated.profiles[fixture.profileKey]?["refresh"] as? String, "stored-refresh")
    }

    func testInactiveExpiredProfileRefreshesCanonicalAuthFirst() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let newAccessToken = jwt(["exp": fixture.now.addingTimeInterval(10 * 24 * 60 * 60).timeIntervalSince1970])
        let responseData = try JSONSerialization.data(withJSONObject: [
            "access_token": newAccessToken,
            "refresh_token": "rotated-refresh",
        ])
        let transport = MockRefreshTransport(response: CodexTokenRefreshHTTPResponse(
            statusCode: 200,
            data: responseData,
            retryAfter: nil
        ))
        let service = CodexTokenRefreshService(
            transport: transport,
            credentialStore: fixture.store,
            profileGate: CodexProfileOperationGate(),
            permitPool: CodexRefreshPermitPool(limit: 2),
            now: { fixture.now }
        )

        let result = await service.credentialForUsage(
            profileKey: fixture.profileKey,
            profile: fixture.staleProfile
        )
        guard case let .ready(credential) = result else {
            return XCTFail("Expected refreshed credential")
        }
        XCTAssertEqual(credential.accessToken, newAccessToken)

        let persisted = try XCTUnwrap(StoredCodexAuth.load(from: fixture.authURL))
        XCTAssertEqual(persisted.accessToken, newAccessToken)
        XCTAssertEqual(persisted.refreshToken, "rotated-refresh")
        let derived = try XCTUnwrap(AppStorage.readJSON(fixture.accountsURL)?["profiles"] as? [String: Any])
        let entry = try XCTUnwrap(derived[fixture.profileKey] as? [String: Any])
        XCTAssertEqual(entry["access"] as? String, newAccessToken)
        let refreshCallCount = await transport.callCount()
        XCTAssertEqual(refreshCallCount, 1)
    }

    func testActiveProfileNeverSpendsRefreshToken() async throws {
        let fixture = try makeFixture(writeMatchingLiveAuth: true)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let transport = MockRefreshTransport(response: CodexTokenRefreshHTTPResponse(
            statusCode: 500,
            data: Data(),
            retryAfter: nil
        ))
        let service = CodexTokenRefreshService(
            transport: transport,
            credentialStore: fixture.store,
            profileGate: CodexProfileOperationGate(),
            permitPool: CodexRefreshPermitPool(limit: 2),
            now: { fixture.now }
        )

        let result = await service.credentialForUsage(
            profileKey: fixture.profileKey,
            profile: fixture.staleProfile
        )
        guard case let .ready(credential) = result else {
            return XCTFail("Expected live active credential")
        }
        XCTAssertEqual(credential.accessToken, fixture.liveAccessToken)
        let refreshCallCount = await transport.callCount()
        XCTAssertEqual(refreshCallCount, 0)
    }

    func testPermanentRefreshFailureIsNotRetriedUntilAuthChanges() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let data = try JSONSerialization.data(withJSONObject: [
            "error": ["code": "refresh_token_reused"],
        ])
        let transport = MockRefreshTransport(response: CodexTokenRefreshHTTPResponse(
            statusCode: 400,
            data: data,
            retryAfter: nil
        ))
        let service = CodexTokenRefreshService(
            transport: transport,
            credentialStore: fixture.store,
            profileGate: CodexProfileOperationGate(),
            permitPool: CodexRefreshPermitPool(limit: 2),
            now: { fixture.now }
        )

        let first = await service.credentialForUsage(
            profileKey: fixture.profileKey,
            profile: fixture.staleProfile
        )
        let second = await service.credentialForUsage(
            profileKey: fixture.profileKey,
            profile: fixture.staleProfile
        )

        guard case let .unavailable(firstMessage) = first,
              case let .unavailable(secondMessage) = second else {
            return XCTFail("Expected re-login requirement")
        }
        XCTAssertEqual(firstMessage, CodexTokenRefreshService.reloginRequiredMessage)
        XCTAssertEqual(secondMessage, CodexTokenRefreshService.reloginRequiredMessage)
        let refreshCallCount = await transport.callCount()
        XCTAssertEqual(refreshCallCount, 1)
    }

    func testAWSImportRecoversPermanentFailureWithoutSpendingSharedRefreshToken() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        try configureAWS(fixture, lastSyncedAt: nil)
        let metaURL = fixture.authURL.deletingLastPathComponent().appendingPathComponent("meta.json")
        var meta = try XCTUnwrap(AppStorage.readJSON(metaURL))
        meta["token_refresh"] = [
            "status": "permanent", "error_code": "invalid_refresh_token",
            "auth_revision": SHA256.hash(data: try Data(contentsOf: fixture.authURL)).map { String(format: "%02x", $0) }.joined(),
        ]
        try AppStorage.writeJSON(meta, to: metaURL)
        let imported = authRoot(now: fixture.now, accessExpiresAt: fixture.now.addingTimeInterval(7 * 86400).timeIntervalSince1970,
                                refreshToken: "aws-owned-refresh")
        let aws = MockAWSSecretCredentials(result: .success(try JSONSerialization.data(withJSONObject: imported)))
        let oauth = MockRefreshTransport(response: .init(statusCode: 500, data: Data(), retryAfter: nil))
        let service = CodexTokenRefreshService(transport: oauth, awsCredentials: aws, credentialStore: fixture.store, now: { fixture.now })
        let result = await service.credentialForUsage(profileKey: fixture.profileKey, profile: fixture.staleProfile)
        guard case let .ready(credential) = result else { return XCTFail("Expected AWS recovery") }
        XCTAssertEqual(credential.accessToken, StoredCodexAuth.parse(root: imported)?.accessToken)
        XCTAssertEqual(StoredCodexAuth.load(from: fixture.authURL)?.refreshToken, "aws-owned-refresh")
        let updatedMeta = try XCTUnwrap(AppStorage.readJSON(metaURL))
        XCTAssertNil(updatedMeta["token_refresh"])
        XCTAssertNotNil((updatedMeta["credential_source"] as? [String: Any])?["last_synced_at"])
        let awsCalls = await aws.callCount(); let oauthCalls = await oauth.callCount()
        XCTAssertEqual(awsCalls, 1); XCTAssertEqual(oauthCalls, 0)
    }

    func testRecentlySyncedAWSAccountSkipsLocalDailyTokenRenewal() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        var root = authRoot(now: fixture.now, accessExpiresAt: fixture.now.addingTimeInterval(7 * 86400).timeIntervalSince1970)
        root["last_refresh"] = ISO8601DateFormatter.codexVitals.string(from: fixture.now.addingTimeInterval(-2 * 86400))
        try AppStorage.writeJSON(root, to: fixture.authURL)
        try configureAWS(fixture, lastSyncedAt: fixture.now)
        let aws = MockAWSSecretCredentials(result: .failure(.unavailable))
        let oauth = MockRefreshTransport(response: .init(statusCode: 500, data: Data(), retryAfter: nil))
        let service = CodexTokenRefreshService(transport: oauth, awsCredentials: aws, credentialStore: fixture.store, now: { fixture.now })
        guard case .ready = await service.credentialForUsage(profileKey: fixture.profileKey, profile: fixture.staleProfile) else {
            return XCTFail("Expected cached AWS access token")
        }
        let awsCalls = await aws.callCount(); let oauthCalls = await oauth.callCount()
        XCTAssertEqual(awsCalls, 0); XCTAssertEqual(oauthCalls, 0)
    }

    func testWrongAWSAccountCannotOverwriteSavedCredentials() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        try configureAWS(fixture, lastSyncedAt: nil)
        let before = try Data(contentsOf: fixture.authURL)
        var root = authRoot(now: fixture.now, accessExpiresAt: fixture.now.addingTimeInterval(86400).timeIntervalSince1970)
        var tokens = try XCTUnwrap(root["tokens"] as? [String: Any]); tokens["account_id"] = "another-account"; root["tokens"] = tokens
        let aws = MockAWSSecretCredentials(result: .success(try JSONSerialization.data(withJSONObject: root)))
        let service = CodexTokenRefreshService(awsCredentials: aws, credentialStore: fixture.store, now: { fixture.now })
        guard case .unavailable = await service.credentialForUsage(profileKey: fixture.profileKey, profile: fixture.staleProfile) else {
            return XCTFail("Expected account identity rejection")
        }
        XCTAssertEqual(try Data(contentsOf: fixture.authURL), before)
    }

    func testAWSAccountSyncsAfterOneDayEvenWithValidAccessToken() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let root = authRoot(now: fixture.now, accessExpiresAt: fixture.now.addingTimeInterval(7 * 86400).timeIntervalSince1970)
        try AppStorage.writeJSON(root, to: fixture.authURL)
        try configureAWS(fixture, lastSyncedAt: fixture.now.addingTimeInterval(-86400))
        let aws = MockAWSSecretCredentials(result: .success(try JSONSerialization.data(withJSONObject: root)))
        let oauth = MockRefreshTransport(response: .init(statusCode: 500, data: Data(), retryAfter: nil))
        let service = CodexTokenRefreshService(transport: oauth, awsCredentials: aws, credentialStore: fixture.store, now: { fixture.now })
        guard case .ready = await service.credentialForUsage(profileKey: fixture.profileKey, profile: fixture.staleProfile) else {
            return XCTFail("Expected daily AWS sync")
        }
        let awsCalls = await aws.callCount(); let oauthCalls = await oauth.callCount()
        XCTAssertEqual(awsCalls, 1); XCTAssertEqual(oauthCalls, 0)
    }

    func testAWSFailureDoesNotFallBackToSharedRefreshToken() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        try configureAWS(fixture, lastSyncedAt: nil)
        let aws = MockAWSSecretCredentials(result: .failure(.unavailable))
        let oauth = MockRefreshTransport(response: .init(statusCode: 500, data: Data(), retryAfter: nil))
        let service = CodexTokenRefreshService(transport: oauth, awsCredentials: aws, credentialStore: fixture.store, now: { fixture.now })
        guard case .unavailable = await service.credentialForUsage(profileKey: fixture.profileKey, profile: fixture.staleProfile) else {
            return XCTFail("Expected AWS unavailable")
        }
        let oauthCalls = await oauth.callCount(); XCTAssertEqual(oauthCalls, 0)
    }

    func testActiveAWSProfileRemainsOwnedByCodex() async throws {
        let fixture = try makeFixture(writeMatchingLiveAuth: true)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        try configureAWS(fixture, lastSyncedAt: nil)
        let aws = MockAWSSecretCredentials(result: .failure(.unavailable))
        let service = CodexTokenRefreshService(awsCredentials: aws, credentialStore: fixture.store, now: { fixture.now })
        guard case let .ready(credential) = await service.credentialForUsage(profileKey: fixture.profileKey, profile: fixture.staleProfile) else {
            return XCTFail("Expected live Codex credential")
        }
        XCTAssertEqual(credential.accessToken, fixture.liveAccessToken)
        let awsCalls = await aws.callCount(); XCTAssertEqual(awsCalls, 0)
    }

    private func configureAWS(_ fixture: Fixture, lastSyncedAt: Date?) throws {
        let url = fixture.authURL.deletingLastPathComponent().appendingPathComponent("meta.json")
        var meta = try XCTUnwrap(AppStorage.readJSON(url))
        var source: [String: Any] = ["kind": "aws_secrets_manager", "aws_profile": "default", "region": "us-east-2", "secret_id": "synthetic-auth"]
        if let lastSyncedAt { source["last_synced_at"] = ISO8601DateFormatter.codexVitals.string(from: lastSyncedAt) }
        meta["credential_source"] = source
        try AppStorage.writeJSON(meta, to: url)
    }

    private struct Fixture {
        let rootURL: URL
        let accountsURL: URL
        let authURL: URL
        let profileKey: String
        let staleProfile: [String: Any]
        let storedAccessToken: String
        let liveAccessToken: String
        let now: Date
        let store: CodexCanonicalCredentialStore
    }

    private func makeFixture(writeMatchingLiveAuth: Bool = false) throws -> Fixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexVitalsRefreshTests-\(UUID().uuidString)", isDirectory: true)
        let profilesURL = rootURL.appendingPathComponent("profiles", isDirectory: true)
        let profileURL = profilesURL.appendingPathComponent("captured", isDirectory: true)
        let authURL = profileURL.appendingPathComponent("auth.json")
        let metaURL = profileURL.appendingPathComponent("meta.json")
        let accountsURL = rootURL.appendingPathComponent("accounts.json")
        let liveAuthURL = rootURL.appendingPathComponent("live-auth.json")
        let profileKey = "openai-codex:team:test@example.com"
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let storedAccessToken = jwt(["exp": now.addingTimeInterval(-60).timeIntervalSince1970])
        let liveAccessToken = jwt(["exp": now.addingTimeInterval(10 * 24 * 60 * 60).timeIntervalSince1970])
        let storedRoot = authRoot(
            now: now,
            accessExpiresAt: now.addingTimeInterval(-60).timeIntervalSince1970,
            accessToken: storedAccessToken,
            refreshToken: "stored-refresh"
        )
        try AppStorage.writeJSON(storedRoot, to: authURL)
        try AppStorage.writeJSON([
            "email": "test@example.com",
            "account_id": "account-test",
            "source_profile_key": profileKey,
        ], to: metaURL)

        let staleProfile: [String: Any] = [
            "email": "test@example.com",
            "accountId": "account-test",
            "access": "stale-cache-access",
            "refresh": "stale-cache-refresh",
            "expires": 0,
        ]
        try AppStorage.writeJSON([
            "version": 1,
            "profiles": [profileKey: staleProfile],
            "order": ["default": [profileKey]],
        ], to: accountsURL)

        if writeMatchingLiveAuth {
            try AppStorage.writeJSON(authRoot(
                now: now,
                accessExpiresAt: now.addingTimeInterval(10 * 24 * 60 * 60).timeIntervalSince1970,
                accessToken: liveAccessToken,
                refreshToken: "live-refresh"
            ), to: liveAuthURL)
        }

        return Fixture(
            rootURL: rootURL,
            accountsURL: accountsURL,
            authURL: authURL,
            profileKey: profileKey,
            staleProfile: staleProfile,
            storedAccessToken: storedAccessToken,
            liveAccessToken: liveAccessToken,
            now: now,
            store: CodexCanonicalCredentialStore(
                profileStoreURL: profilesURL,
                accountsURL: accountsURL,
                liveAuthURL: liveAuthURL
            )
        )
    }

    private func authRoot(
        now: Date,
        accessExpiresAt: TimeInterval,
        accessToken: String? = nil,
        refreshToken: String = "refresh"
    ) -> [String: Any] {
        let idToken = jwt([
            "sub": "subject-test",
            "email": "test@example.com",
            "iat": now.addingTimeInterval(-60).timeIntervalSince1970,
            "exp": now.addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970,
            "https://api.openai.com/auth": ["chatgpt_account_id": "account-test"],
        ])
        return [
            "auth_mode": "chatgpt",
            "last_refresh": ISO8601DateFormatter.codexVitals.string(from: now),
            "tokens": [
                "id_token": idToken,
                "access_token": accessToken ?? jwt(["exp": accessExpiresAt]),
                "refresh_token": refreshToken,
                "account_id": "account-test",
            ],
        ]
    }

    private func jwt(_ payload: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).signature"
    }
}

private actor MockAWSSecretCredentials: AWSSecretCredentialProviding {
    let result: Result<Data, AWSSecretCredentialError>
    private var calls = 0
    init(result: Result<Data, AWSSecretCredentialError>) { self.result = result }
    func authData(from source: AWSSecretCredentialSource) throws -> Data {
        calls += 1
        return try result.get()
    }
    func callCount() -> Int { calls }
}

private actor MockRefreshTransport: CodexTokenRefreshTransport {
    private let response: CodexTokenRefreshHTTPResponse
    private var refreshTokens: [String] = []

    init(response: CodexTokenRefreshHTTPResponse) {
        self.response = response
    }

    func refresh(refreshToken: String) async throws -> CodexTokenRefreshHTTPResponse {
        refreshTokens.append(refreshToken)
        return response
    }

    func callCount() -> Int {
        refreshTokens.count
    }
}
