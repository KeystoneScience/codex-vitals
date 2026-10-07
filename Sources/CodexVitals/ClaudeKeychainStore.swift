import Darwin
import Foundation
import Security

protocol ClaudeKeychainStoring: Sendable {
    var activeAccountName: String { get }
    func read(service: String, account: String) throws -> String?
    func write(service: String, account: String, value: String) throws
    func delete(service: String, account: String) throws
}

final class ClaudeKeychainStore: ClaudeKeychainStoring, @unchecked Sendable {
    static let activeService = "Claude Code-credentials"
    static let profileService = "com.ramterstudio.CodexVitals.Claude"
    static let safetyService = "com.ramterstudio.CodexVitals.Claude.Safety"
    static let safetyAccount = "last-live-credential"

    private let securityURL: URL
    private let keychainURL: URL?
    private let commandTimeout: TimeInterval
    private let maximumOutputBytes = 64 * 1024
    private let maximumInteractiveCommandBytes = 4_000

    init(
        keychainURL: URL? = nil,
        securityURL: URL = URL(fileURLWithPath: "/usr/bin/security"),
        commandTimeout: TimeInterval = 15
    ) {
        self.keychainURL = keychainURL
        self.securityURL = securityURL
        self.commandTimeout = commandTimeout
    }

    var activeAccountName: String {
        let environmentUser = ProcessInfo.processInfo.environment["USER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return environmentUser?.isEmpty == false ? environmentUser! : NSUserName()
    }

    func read(service: String, account: String) throws -> String? {
        let result = try run(arguments: keychainArguments([
            "find-generic-password", "-a", account, "-w", "-s", service,
        ]))
        if result.status == 0 {
            guard let value = String(data: result.stdout, encoding: .utf8) else {
                throw ClaudeNativeError.keychainUnavailable("invalid response")
            }
            let password = value.hasSuffix("\n") ? String(value.dropLast()) : value
            // security prints non-ASCII or multiline passwords as hex. Only decode
            // when the result is a JSON credential, leaving ordinary text intact.
            if password.utf8.count.isMultiple(of: 2),
               password.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
                let bytes = Array(password.utf8)
                var decoded = Data()
                for index in stride(from: 0, to: bytes.count, by: 2) {
                    let pair = String(bytes: bytes[index...index + 1], encoding: .utf8)!
                    decoded.append(UInt8(pair, radix: 16)!)
                }
                if decoded.count <= maximumOutputBytes,
                   (try? JSONSerialization.jsonObject(with: decoded)) is [String: Any],
                   let credential = String(data: decoded, encoding: .utf8) {
                    return credential
                }
            }
            guard password.utf8.count <= maximumOutputBytes else {
                throw ClaudeNativeError.keychainUnavailable("response too large")
            }
            return password
        }
        if result.status == 44 { return nil }
        throw ClaudeNativeError.keychainUnavailable("read failed (\(result.status))")
    }

    func write(service: String, account: String, value: String) throws {
        guard let data = value.data(using: .utf8), data.count <= maximumOutputBytes else {
            throw ClaudeNativeError.keychainValueTooLarge
        }
        // Pass the credential through stdin, not argv. Hex encoding doubled its size
        // and rejected ordinary Claude JWTs before the browser login could start.
        let destination = keychainURL.map { " " + quoted($0.path) } ?? ""
        let command = "add-generic-password -U -a \(quoted(account)) -s \(quoted(service)) -w \(quoted(value))\(destination)\n"
        if command.utf8.count > maximumInteractiveCommandBytes
            || value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) {
            try writeNative(service: service, account: account, data: data)
            return
        }
        let result = try run(arguments: ["-i"], standardInput: Data(command.utf8))
        guard result.status == 0 else {
            throw ClaudeNativeError.keychainUnavailable("write failed (\(result.status))")
        }
    }

    func delete(service: String, account: String) throws {
        let result = try run(arguments: keychainArguments([
            "delete-generic-password", "-a", account, "-s", service,
        ]))
        guard result.status == 0 || result.status == 44 else {
            throw ClaudeNativeError.keychainUnavailable("delete failed (\(result.status))")
        }
    }

    private func quoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func keychainArguments(_ arguments: [String]) -> [String] {
        arguments + (keychainURL.map { [$0.path] } ?? [])
    }

    private func writeNative(service: String, account: String, data: Data) throws {
        var keychain: SecKeychain?
        if let keychainURL {
            let status = SecKeychainOpen(keychainURL.path, &keychain)
            guard status == errSecSuccess else {
                throw ClaudeNativeError.keychainUnavailable("open failed (\(status))")
            }
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let keychain { query[kSecMatchSearchList as String] = [keychain] }
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            query.removeValue(forKey: kSecMatchSearchList as String)
            if let keychain { query[kSecUseKeychain as String] = keychain }
            query[kSecValueData as String] = data
            query[kSecAttrAccess as String] = try nativeAccess(service: service)
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw ClaudeNativeError.keychainUnavailable("write failed (\(status))")
        }
    }

    private func nativeAccess(service: String) throws -> SecAccess {
        var currentApplication: SecTrustedApplication?
        var securityApplication: SecTrustedApplication?
        var status = SecTrustedApplicationCreateFromPath(nil, &currentApplication)
        guard status == errSecSuccess, let currentApplication else {
            throw ClaudeNativeError.keychainUnavailable("access setup failed (\(status))")
        }
        status = SecTrustedApplicationCreateFromPath(securityURL.path, &securityApplication)
        guard status == errSecSuccess, let securityApplication else {
            throw ClaudeNativeError.keychainUnavailable("access setup failed (\(status))")
        }
        var access: SecAccess?
        status = SecAccessCreate(service as CFString, [currentApplication, securityApplication] as CFArray, &access)
        guard status == errSecSuccess, let access else {
            throw ClaudeNativeError.keychainUnavailable("access setup failed (\(status))")
        }
        return access
    }

    private func run(arguments: [String], standardInput: Data? = nil) throws -> ProcessResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Headroom-Keychain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("output")
        let errorURL = directory.appendingPathComponent("errors")
        for url in [outputURL, errorURL] {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let process = Process()
        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? errors.close() }
        process.executableURL = securityURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        if let standardInput {
            let input = Pipe()
            process.standardInput = input
            try process.run()
            input.fileHandleForWriting.write(standardInput)
            try input.fileHandleForWriting.close()
        } else {
            try process.run()
        }
        let deadline = Date().addingTimeInterval(commandTimeout)
        while process.isRunning && Date() < deadline { Darwin.usleep(25_000) }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < terminationDeadline { Darwin.usleep(25_000) }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw ClaudeNativeError.keychainUnavailable("access timed out; check the macOS Keychain permission prompt")
        }
        process.waitUntilExit()
        let stdout = try Data(contentsOf: outputURL)
        let stderr = try Data(contentsOf: errorURL)
        guard stdout.count <= maximumOutputBytes * 2 + 1, stderr.count <= maximumOutputBytes else {
            throw ClaudeNativeError.keychainUnavailable("response too large")
        }
        return ProcessResult(status: process.terminationStatus, stdout: stdout)
    }

    private struct ProcessResult {
        let status: Int32
        let stdout: Data
    }
}
