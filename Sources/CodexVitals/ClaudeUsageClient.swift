import Foundation

struct ClaudeUsageResult: Sendable {
    let credential: String
    let response: ClaudeUsageResponse
}

protocol ClaudeUsageProviding: Sendable {
    func validateAccount(credential: String, expectedAccountUUID: String?) async throws

    func fetchUsage(
        credential: String,
        expectedAccountUUID: String?,
        refreshIfNeeded: Bool,
        persistRefreshedCredential: @Sendable (String) async throws -> Void
    ) async throws -> ClaudeUsageResult
}

final class ClaudeUsageClient: ClaudeUsageProviding, @unchecked Sendable {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        return "Headroom/\(version)"
    }

    private let session: URLSession
    private let identityLock = NSLock()
    private var verifiedIdentities: [String: String] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchUsage(
        credential rawCredential: String,
        expectedAccountUUID: String?,
        refreshIfNeeded: Bool,
        persistRefreshedCredential: @Sendable (String) async throws -> Void
    ) async throws -> ClaudeUsageResult {
        var credential = try ClaudeCredentialEnvelope(rawValue: rawCredential)
        // Reject a copied token before rotating it on behalf of the wrong profile.
        // A still-valid access token (or an identity verified earlier this run)
        // lets us check ownership without spending its refresh token.
        if !credential.isExpiring || identityLock.withLock({ verifiedIdentities[credential.accessToken] != nil }) {
            try await validateAccount(credential: credential.rawValue, expectedAccountUUID: expectedAccountUUID)
        }
        if refreshIfNeeded && credential.needsRefresh() {
            credential = try await refresh(credential, expectedAccountUUID: expectedAccountUUID)
            try await validateAccount(credential: credential.rawValue, expectedAccountUUID: expectedAccountUUID)
            // A usage failure must not discard a successfully rotated refresh token.
            try await persistRefreshedCredential(credential.rawValue)
        } else {
            try await validateAccount(credential: credential.rawValue, expectedAccountUUID: expectedAccountUUID)
        }

        var request = URLRequest(url: Self.usageURL, timeoutInterval: 15)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClaudeNativeError.networkUnavailable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            let decoded = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
            return ClaudeUsageResult(credential: credential.rawValue, response: decoded)
        case 401:
            throw ClaudeNativeError.refreshRejected
        case 403:
            throw Self.isAuthenticationRejection(data)
                ? ClaudeNativeError.refreshRejected : ClaudeNativeError.serviceUnavailable(status)
        case 429:
            throw ClaudeNativeError.rateLimited(
                retryAfter: Self.retryAfterSeconds(from: response as? HTTPURLResponse)
            )
        default:
            throw ClaudeNativeError.serviceUnavailable(status)
        }
    }

    func validateAccount(credential rawCredential: String, expectedAccountUUID: String?) async throws {
        guard let expectedAccountUUID, !expectedAccountUUID.isEmpty else {
            throw ClaudeNativeError.invalidAccountMetadata
        }
        let credential = try ClaudeCredentialEnvelope(rawValue: rawCredential)
        let actual: String
        if let cached = identityLock.withLock({ verifiedIdentities[credential.accessToken] }) {
            actual = cached
        } else {
            var request = URLRequest(url: Self.profileURL, timeoutInterval: 15)
            request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw ClaudeNativeError.networkUnavailable
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                if status == 401 || (status == 403 && Self.isAuthenticationRejection(data)) {
                    throw ClaudeNativeError.refreshRejected
                }
                if status == 429 {
                    throw ClaudeNativeError.rateLimited(retryAfter: Self.retryAfterSeconds(from: response as? HTTPURLResponse))
                }
                throw ClaudeNativeError.serviceUnavailable(status)
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let account = root["account"] as? [String: Any],
                  let uuid = account["uuid"] as? String, !uuid.isEmpty else {
                throw ClaudeNativeError.invalidAccountMetadata
            }
            actual = uuid
            identityLock.withLock { verifiedIdentities[credential.accessToken] = uuid }
        }
        guard actual == expectedAccountUUID else {
            throw ClaudeNativeError.credentialAccountMismatch
        }
    }

    private static func isAuthenticationRejection(_ data: Data) -> Bool {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let error = body["error"] as? [String: Any]
        let type = error?["type"] as? String ?? body["error"] as? String
        return ["authentication_error", "permission_error", "invalid_grant"].contains(type ?? "")
    }

    static func retryAfterSeconds(from response: HTTPURLResponse?) -> TimeInterval? {
        guard let rawValue = response?.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        guard let seconds = TimeInterval(rawValue) else { return nil }
        return max(0, seconds)
    }

    private func refresh(
        _ credential: ClaudeCredentialEnvelope,
        expectedAccountUUID: String?
    ) async throws -> ClaudeCredentialEnvelope {
        guard let refreshToken = credential.refreshToken else {
            throw ClaudeNativeError.refreshRejected
        }
        var request = URLRequest(url: Self.tokenURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        var body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
        ]
        if let scopes = credential.oauth["scopes"] as? [String], !scopes.isEmpty {
            body["scope"] = scopes.joined(separator: " ")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClaudeNativeError.networkUnavailable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status == 429 {
                throw ClaudeNativeError.rateLimited(
                    retryAfter: Self.retryAfterSeconds(from: response as? HTTPURLResponse)
                )
            }
            if status == 401 || ((status == 400 || status == 403) && Self.isAuthenticationRejection(data)) {
                throw ClaudeNativeError.refreshRejected
            }
            throw ClaudeNativeError.serviceUnavailable(status)
        }

        let token = try JSONDecoder().decode(ClaudeTokenResponse.self, from: data)
        if let expectedAccountUUID,
           let actual = token.account?.uuid,
           actual != expectedAccountUUID {
            throw ClaudeNativeError.credentialAccountMismatch
        }
        let updated = try credential.replacingOAuth(with: token)
        // The token endpoint's account is authoritative. Remember it before the
        // usage request so an unrelated profile outage cannot lose a rotated token.
        if let actual = token.account?.uuid, !actual.isEmpty {
            identityLock.withLock { verifiedIdentities[token.accessToken] = actual }
        }
        return try ClaudeCredentialEnvelope(rawValue: updated)
    }
}
