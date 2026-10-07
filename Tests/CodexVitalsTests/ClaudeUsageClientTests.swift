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
        ClaudeUsageURLProtocol.setHandler { request in
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
        ClaudeUsageURLProtocol.setHandler { request in
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
        ClaudeUsageURLProtocol.setHandler { request in
            XCTAssertEqual(request.url, ClaudeUsageClient.usageURL)
            return (200, Data("{}".utf8))
        }
        _ = try await client().fetchUsage(
            credential: oldCredential(), expectedAccountUUID: "account-test", refreshIfNeeded: false,
            persistRefreshedCredential: { _ in XCTFail("Active account must be owned by Claude Code") }
        )
    }

    private var tokenResponse: Data {
        Data("""
        {"access_token":"renewed-access","refresh_token":"rotated-refresh","expires_in":604800,"account":{"uuid":"account-test"}}
        """.utf8)
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
