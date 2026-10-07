import Foundation
import XCTest
@testable import CodexVitals

final class AWSSecretCredentialsTests: XCTestCase {
    func testCLIReadsConfiguredSecretWithoutPuttingTokensInArguments() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auth = "{\"tokens\":{\"access_token\":\"synthetic-access\"}}"
        try JSONSerialization.data(withJSONObject: ["SecretString": auth])
            .write(to: directory.appendingPathComponent("response.json"))
        let executable = directory.appendingPathComponent("aws")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$(dirname \"$0\")/args\"\n/bin/cat \"$(dirname \"$0\")/response.json\"\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let provider = AWSCLISecretCredentialProvider(executableURL: executable)
        let data = try await provider.authData(from: source())
        XCTAssertEqual(String(data: data, encoding: .utf8), auth)
        let args = try String(contentsOf: directory.appendingPathComponent("args"), encoding: .utf8)
        XCTAssertTrue(args.contains("synthetic-secret"))
        XCTAssertTrue(args.contains("us-east-2"))
        XCTAssertFalse(args.contains("synthetic-access"))
    }

    func testSlowCLIIsBounded() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("aws")
        try Data("#!/bin/sh\nexec /bin/sleep 10\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        do {
            _ = try await AWSCLISecretCredentialProvider(executableURL: executable, timeout: 0.2).authData(from: source())
            XCTFail("Expected timeout")
        } catch AWSSecretCredentialError.timedOut { }
    }

    private func source() throws -> AWSSecretCredentialSource {
        try XCTUnwrap(AWSSecretCredentialSource(metadata: ["aws_profile": "default", "region": "us-east-2", "secret_id": "synthetic-secret"]))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Headroom-AWSTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
}
