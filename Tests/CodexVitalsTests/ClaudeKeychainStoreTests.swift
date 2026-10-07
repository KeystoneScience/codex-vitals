import Foundation
import XCTest
@testable import CodexVitals

final class ClaudeKeychainStoreTests: XCTestCase {
    func testOrdinaryLargeClaudeCredentialRoundTripsThroughSecureStdin() throws {
        try withTemporaryKeychain { store in
            let data = try JSONSerialization.data(withJSONObject: [
                "claudeAiOauth": ["accessToken": String(repeating: "test", count: 520), "refreshToken": "synthetic"],
                "pluginSecrets": ["escaped": "quoted \"text\" and C:\\sample\\path"],
            ])
            let value = try XCTUnwrap(String(data: data, encoding: .utf8))
            try store.write(service: "Headroom-Tests", account: "tester", value: value)
            XCTAssertEqual(try store.read(service: "Headroom-Tests", account: "tester"), value)
        }
    }

    func testNativeFallbackPreservesLongAndMultilineCredentialsWhenUpdating() throws {
        try withTemporaryKeychain { store in
            let root = ["claudeAiOauth": ["accessToken": String(repeating: "synthetic", count: 1000), "refreshToken": "synthetic"]]
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
            let value = try XCTUnwrap(String(data: data, encoding: .utf8))
            try store.write(service: "Headroom-Tests", account: "tester", value: value)
            XCTAssertTrue(try store.read(service: "Headroom-Tests", account: "tester") == value)
            let replacement = value + "\n"
            try store.write(service: "Headroom-Tests", account: "tester", value: replacement)
            XCTAssertTrue(try store.read(service: "Headroom-Tests", account: "tester") == replacement)
        }
    }

    func testKeychainCommandTimeoutDoesNotLeaveAccountActionHanging() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Headroom-SlowSecurity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("security")
        try Data("#!/bin/sh\nexec /bin/sleep 10\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let store = ClaudeKeychainStore(securityURL: script, commandTimeout: 0.2)
        XCTAssertThrowsError(try store.read(service: "Headroom-Tests", account: "tester")) {
            XCTAssertTrue($0.localizedDescription.contains("timed out"))
        }
    }

    private func withTemporaryKeychain(_ body: (ClaudeKeychainStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Headroom-KeychainTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("test.keychain-db")
        try security(["create-keychain", "-p", "headroom-test-only", url.path])
        defer { try? security(["delete-keychain", url.path]) }
        try body(ClaudeKeychainStore(keychainURL: url))
    }

    private func security(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
