import Foundation
import XCTest
@testable import CodexVitals

final class ClaudeUsageClientTests: XCTestCase {
    override func tearDown() {
        ClaudeUsageURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func testRotatedCredentialIsPersistedBeforeRateLimitedUsageRequest() async throws {
        let recorder = CredentialRecorder()
        setUsageHandler { request in
            if request.url == ClaudeUsageClient.tokenURL {
                return (200, self.tokenResponse)
            }
            XCTAssertNotNil(recorder.value)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer renewed-access")
            return (429, Data("{}".utf8))
        }
        do {
            _ = try await client().fetchUsage(
                credential: oldCredential(), expectedAccountUUID: "account-test", refreshIfNeeded: true,
                persistRefreshedCredential: { recorder.record($0) }
            )
            XCTFail("Expected usage rate limit")
        } catch let error as ClaudeNativeError {
            XCTAssertEqual(error, .rateLimited(retryAfter: nil))
        }
        let persisted = try ClaudeCredentialEnvelope(rawValue: XCTUnwrap(recorder.value))
        XCTAssertEqual(persisted.refreshToken, "rotated-refresh")
        XCTAssertFalse(persisted.needsRefresh())
    }

    func testPersistenceFailureStopsUsageRequest() async throws {
        setUsageHandler { request in
            XCTAssertEqual(request.url, ClaudeUsageClient.tokenURL)
            return (200, self.tokenResponse)
        }
        do {
            _ = try await client().fetchUsage(
                credential: oldCredential(), expectedAccountUUID: "account-test", refreshIfNeeded: true,
                persistRefreshedCredential: { _ in throw PersistenceFailure.expected }
            )
            XCTFail("Expected storage failure")
        } catch is PersistenceFailure { }
    }

    func testActiveAccountDoesNotSpendRefreshToken() async throws {
        setUsageHandler { request in
            XCTAssertEqual(request.url, ClaudeUsageClient.usageURL)
            return (200, Data("{}".utf8))
        }
        _ = try await client().fetchUsage(
            credential: oldCredential(), expectedAccountUUID: "account-test", refreshIfNeeded: false,
            persistRefreshedCredential: { _ in XCTFail("Active account must be owned by Claude Code") }
        )
    }

    func testRefreshIdentifiesHeadroomAndPreservesExistingScopes() async throws {
        let credential = "{\"claudeAiOauth\":{\"accessToken\":\"old-access\",\"refreshToken\":\"old-refresh\",\"expiresAt\":1,\"scopes\":[\"user:profile\",\"user:inference\"]}}"
        setUsageHandler { request in
            XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Headroom/") == true)
            if request.url == ClaudeUsageClient.tokenURL {
                let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: self.requestBody(request)) as? [String: Any])
                XCTAssertEqual(body["scope"] as? String, "user:profile user:inference")
                return (200, self.tokenResponse)
            }
            return (200, Data("{}".utf8))
        }
        _ = try await client().fetchUsage(
            credential: credential, expectedAccountUUID: "account-test", refreshIfNeeded: true,
            persistRefreshedCredential: { _ in }
        )
    }

    func testRequestBlockDoesNotMasqueradeAsRevokedLogin() async throws {
        for shouldRefresh in [false, true] {
            setUsageHandler { _ in
                (403, Data("{\"error\":{\"type\":\"request_blocked\",\"message\":\"Request blocked by Cloudflare\"}}".utf8))
            }
            do {
                _ = try await client().fetchUsage(
                    credential: oldCredential(), expectedAccountUUID: "account-test", refreshIfNeeded: shouldRefresh,
                    persistRefreshedCredential: { _ in XCTFail("Blocked requests must not replace credentials") }
                )
                XCTFail("Expected blocked request")
            } catch let error as ClaudeNativeError {
                XCTAssertEqual(error, .serviceUnavailable(403))
            }
        }
    }

    func testRevokedRefreshTokenRequiresLogin() async throws {
        setUsageHandler { _ in
            (400, Data("{\"error\":\"invalid_grant\",\"error_description\":\"Refresh token not found or invalid\"}".utf8))
        }
        do {
            _ = try await client().fetchUsage(
                credential: oldCredential(), expectedAccountUUID: "account-test", refreshIfNeeded: true,
                persistRefreshedCredential: { _ in XCTFail("Rejected refresh must not replace credentials") }
            )
            XCTFail("Expected rejected refresh")
        } catch let error as ClaudeNativeError {
            XCTAssertEqual(error, .refreshRejected)
        }
    }

    private func setUsageHandler(_ handler: @escaping (URLRequest) throws -> (Int, Data)) {
        ClaudeUsageURLProtocol.setHandler { request in
            if request.url == ClaudeUsageClient.profileURL {
                return (200, Data(#"{"account":{"uuid":"account-test"}}"#.utf8))
            }
            return try handler(request)
        }
    }

    func testWrongAccountTokenCannotReturnUsageOrReplaceSavedCredentials() async throws {
        ClaudeUsageURLProtocol.setHandler { request in
            XCTAssertEqual(request.url, ClaudeUsageClient.profileURL)
            return (200, Data(#"{"account":{"uuid":"other-account"}}"#.utf8))
        }
        do {
            _ = try await client().fetchUsage(
                credential: oldCredential(), expectedAccountUUID: "account-test", refreshIfNeeded: false,
                persistRefreshedCredential: { _ in XCTFail("Mismatched credential must not be saved") }
            )
            XCTFail("Expected account mismatch")
        } catch let error as ClaudeNativeError {
            XCTAssertEqual(error, .credentialAccountMismatch)
        }
    }

    func testWrongAccountRefreshResponseCannotReplaceSavedCredentials() async throws {
        ClaudeUsageURLProtocol.setHandler { request in
            XCTAssertEqual(request.url, ClaudeUsageClient.tokenURL)
            return (200, Data(#"{"access_token":"wrong-access","refresh_token":"wrong-refresh","expires_in":3600,"account":{"uuid":"other-account"}}"#.utf8))
        }
        do {
            _ = try await client().fetchUsage(
                credential: oldCredential(), expectedAccountUUID: "account-test", refreshIfNeeded: true,
                persistRefreshedCredential: { _ in XCTFail("Mismatched refresh must not be saved") }
            )
            XCTFail("Expected account mismatch")
        } catch let error as ClaudeNativeError {
            XCTAssertEqual(error, .credentialAccountMismatch)
        }
    }

    func testUnexpiredWrongAccountTokenCannotSpendRefreshToken() async throws {
        let credential = String(data: try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": [
                "accessToken": "wrong-access", "refreshToken": "wrong-refresh",
                "expiresAt": Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000,
            ],
        ]), encoding: .utf8)!
        ClaudeUsageURLProtocol.setHandler { request in
            XCTAssertEqual(request.url, ClaudeUsageClient.profileURL)
            return (200, Data(#"{"account":{"uuid":"other-account"}}"#.utf8))
        }
        do {
            _ = try await client().fetchUsage(
                credential: credential, expectedAccountUUID: "account-test", refreshIfNeeded: true,
                persistRefreshedCredential: { _ in XCTFail("Mismatched credential must not be saved") }
            )
            XCTFail("Expected account mismatch before refresh")
        } catch let error as ClaudeNativeError {
            XCTAssertEqual(error, .credentialAccountMismatch)
        }
    }

    func testCachedIdentityStillRejectsAnotherProfile() async throws {
        let requests = CredentialRecorder()
        ClaudeUsageURLProtocol.setHandler { request in
            XCTAssertEqual(request.url, ClaudeUsageClient.profileURL)
            XCTAssertNil(requests.value)
            requests.record("checked")
            return (200, Data(#"{"account":{"uuid":"account-test"}}"#.utf8))
        }
        let provider = client()
        try await provider.validateAccount(credential: oldCredential(), expectedAccountUUID: "account-test")
        do {
            try await provider.validateAccount(credential: oldCredential(), expectedAccountUUID: "other-account")
            XCTFail("Expected cached identity mismatch")
        } catch let error as ClaudeNativeError {
            XCTAssertEqual(error, .credentialAccountMismatch)
        }
    }

    func testProfileWithoutIdentityCannotAuthorizeUsage() async throws {
        ClaudeUsageURLProtocol.setHandler { request in
            XCTAssertEqual(request.url, ClaudeUsageClient.profileURL)
            return (200, Data(#"{"account":{}}"#.utf8))
        }
        do {
            _ = try await client().fetchUsage(
                credential: oldCredential(), expectedAccountUUID: "account-test", refreshIfNeeded: false,
                persistRefreshedCredential: { _ in XCTFail("Unverified credential must not be saved") }
            )
            XCTFail("Expected missing identity")
        } catch let error as ClaudeNativeError {
            XCTAssertEqual(error, .invalidAccountMetadata)
        }
    }

    private var tokenResponse: Data {
        Data("""
        {"access_token":"renewed-access","refresh_token":"rotated-refresh","expires_in":604800,"account":{"uuid":"account-test"}}
        """.utf8)
    }

    private func requestBody(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count == 0 { return data }
            guard count > 0 else { throw try XCTUnwrap(stream.streamError) }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private func oldCredential() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": ["accessToken": "old-access", "refreshToken": "old-refresh", "expiresAt": 1],
        ])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func client() -> ClaudeUsageClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeUsageURLProtocol.self]
        return ClaudeUsageClient(session: URLSession(configuration: configuration))
    }
}

private enum PersistenceFailure: Error { case expected }

private final class CredentialRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? { lock.withLock { stored } }
    func record(_ value: String) { lock.withLock { stored = value } }
}

private final class ClaudeUsageURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> (Int, Data))?

    static func setHandler(_ value: ((URLRequest) throws -> (Int, Data))?) {
        lock.withLock { handler = value }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.lock.withLock { Self.handler })
            let (status, data) = try handler(request)
            let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() { }
}
