import Darwin
import Foundation

struct AWSSecretCredentialSource: Sendable {
    let profile: String
    let region: String
    let secretID: String
    let lastSyncedAt: Date?

    init?(metadata: [String: Any]) {
        guard let profile = metadata["aws_profile"] as? String,
              let region = metadata["region"] as? String,
              let secretID = metadata["secret_id"] as? String,
              [profile, region, secretID].allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") }) else { return nil }
        self.profile = profile
        self.region = region
        self.secretID = secretID
        if let value = metadata["last_synced_at"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            lastSyncedAt = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        } else {
            lastSyncedAt = nil
        }
    }

    func isDue(auth: StoredCodexAuth, at now: Date) -> Bool {
        guard let lastSyncedAt else { return true }
        return now.timeIntervalSince(lastSyncedAt) >= AccountTokenMaintenance.interval
            || auth.accessExpiresAt <= Int(now.addingTimeInterval(5 * 60).timeIntervalSince1970 * 1000)
    }
}

protocol AWSSecretCredentialProviding: Sendable {
    func authData(from source: AWSSecretCredentialSource) async throws -> Data
}

enum AWSSecretCredentialError: Error {
    case unavailable, invalidResponse, timedOut
}

struct AWSCLISecretCredentialProvider: AWSSecretCredentialProviding {
    var executableURL: URL?
    var timeout: TimeInterval = 20

    func authData(from source: AWSSecretCredentialSource) async throws -> Data {
        let candidates = ["/opt/homebrew/bin/aws", "/usr/local/bin/aws"]
            + (ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":")
                .map { String($0) + "/aws" } ?? [])
        guard let executable = executableURL ?? candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }).map({ URL(fileURLWithPath: $0) }) else { throw AWSSecretCredentialError.unavailable }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Headroom-AWS-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("secret.json")
        let errorURL = directory.appendingPathComponent("errors")
        for url in [outputURL, errorURL] {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? errors.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--profile", source.profile, "--region", source.region,
                             "secretsmanager", "get-secret-value", "--secret-id", source.secretID, "--output", "json"]
        var environment = ProcessInfo.processInfo.environment
        environment["AWS_PAGER"] = ""
        environment["AWS_CLI_AUTO_PROMPT"] = "off"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(0.5)
                while process.isRunning && Date() < deadline { usleep(25_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            try Task.checkCancellation()
            guard Date() < deadline else { throw AWSSecretCredentialError.timedOut }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AWSSecretCredentialError.unavailable }
        let reader = try FileHandle(forReadingFrom: outputURL)
        defer { try? reader.close() }
        let data = try reader.read(upToCount: 64 * 1024 + 1) ?? Data()
        guard data.count <= 64 * 1024,
              let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = response["SecretString"] as? String,
              let auth = value.data(using: .utf8) else { throw AWSSecretCredentialError.invalidResponse }
        return auth
    }
}
