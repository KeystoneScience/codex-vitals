import Darwin
import Foundation

struct ClaudeLoginCommand {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
}

enum ClaudeCLI {
    static func resolveLoginCommand(
        email: String?,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        searchDirectories: [String]? = nil,
        probeTimeout: TimeInterval = 8,
        fileManager: FileManager = .default
    ) throws -> ClaudeLoginCommand {
        let directories = searchDirectories ?? commandSearchDirectories(environment: environment)
        let candidates = executableCandidates(
            homeURL: homeURL,
            searchDirectories: directories,
            fileManager: fileManager
        )
        var foundInstallation = false
        for candidate in candidates {
            guard fileManager.isExecutableFile(atPath: candidate.path),
                  (try? candidate.resolvingSymlinksInPath()
                    .resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            foundInstallation = true
            var loginEnvironment = environment
            loginEnvironment["PATH"] = uniqueDirectories(
                [candidate.deletingLastPathComponent().path] + directories
            ).joined(separator: ":")
            guard (try? supportsLogin(
                executableURL: candidate,
                environment: loginEnvironment,
                timeout: probeTimeout,
                fileManager: fileManager
            )) == true else { continue }

            // Claude subscriptions are the default; --console opts into API billing.
            var arguments = ["auth", "login"]
            if let email = Account.normalizedAlias(email) {
                arguments += ["--email", email]
            }
            return ClaudeLoginCommand(
                executableURL: candidate,
                arguments: arguments,
                environment: loginEnvironment
            )
        }
        throw foundInstallation ? ClaudeNativeError.claudeCLIIncompatible : .claudeCLIUnavailable
    }

    private static func executableCandidates(
        homeURL: URL,
        searchDirectories: [String],
        fileManager: FileManager
    ) -> [URL] {
        var candidates = [homeURL.appendingPathComponent(".local/bin/claude")]
        // A native installation can survive after its .local/bin symlink is lost.
        candidates += versions(
            at: homeURL.appendingPathComponent(".local/share/claude/versions"),
            fileManager: fileManager
        )
        candidates += [".volta/bin/claude", ".bun/bin/claude", ".asdf/shims/claude", ".npm-global/bin/claude"]
            .map { homeURL.appendingPathComponent($0) }
        candidates += searchDirectories.map {
            URL(fileURLWithPath: $0).appendingPathComponent("claude")
        }
        candidates += versions(
            at: homeURL.appendingPathComponent(".nvm/versions/node"),
            fileManager: fileManager
        ).map { $0.appendingPathComponent("bin/claude") }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func versions(at directory: URL, fileManager: FileManager) -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.sorted {
            $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending
        }
    }

    private static func commandSearchDirectories(environment: [String: String]) -> [String] {
        uniqueDirectories([
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ] + (environment["PATH"]?.split(separator: ":").map(String.init) ?? []))
    }

    private static func uniqueDirectories(_ directories: [String]) -> [String] {
        var seen = Set<String>()
        return directories.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func supportsLogin(
        executableURL: URL,
        environment: [String: String],
        timeout: TimeInterval,
        fileManager: FileManager
    ) throws -> Bool {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("Headroom-Claude-CLI-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("help.log")
        fileManager.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["auth", "login", "--help"]
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Darwin.usleep(25_000)
        }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < terminationDeadline {
                Darwin.usleep(25_000)
            }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            return false
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }
        let reader = try FileHandle(forReadingFrom: outputURL)
        defer { try? reader.close() }
        let data = try reader.read(upToCount: 64 * 1024) ?? Data()
        let help = String(data: data, encoding: .utf8) ?? ""
        // Legacy CLIs return success and top-level help for an unknown auth command.
        return help.contains("Usage: claude auth login")
    }
}
