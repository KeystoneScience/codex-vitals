import Foundation
import XCTest
@testable import CodexVitals

final class ClaudeCLITests: XCTestCase {
    func testNativeVersionIsFoundWithoutSymlinkAndPreferredOverLegacyNpmCLI() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let native = try fakeCLI(root.appendingPathComponent(".local/share/claude/versions/2.1.52"))
        let legacy = try fakeCLI(root.appendingPathComponent("homebrew/bin/claude"), supportsLogin: false)

        let command = try resolve(homeURL: root, searchDirectories: [legacy.deletingLastPathComponent().path])

        XCTAssertEqual(command.executableURL.resolvingSymlinksInPath(), native.resolvingSymlinksInPath())
        XCTAssertEqual(command.arguments, ["auth", "login"])
    }

    func testUnsupportedCLIIsSkippedEvenWhenHelpExitsSuccessfully() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try fakeCLI(root.appendingPathComponent(".local/bin/claude"), supportsLogin: false)
        let compatible = try fakeCLI(root.appendingPathComponent("another/bin/claude"))

        let command = try resolve(homeURL: root, searchDirectories: [compatible.deletingLastPathComponent().path])

        XCTAssertEqual(command.executableURL, compatible)
    }

    func testNativeSymlinkIsSupported() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let native = try fakeCLI(root.appendingPathComponent(".local/share/claude/versions/2.1.52"))
        let symlink = root.appendingPathComponent(".local/bin/claude")
        try FileManager.default.createDirectory(at: symlink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: native)

        XCTAssertEqual(try resolve(homeURL: root).executableURL, symlink)
    }

    func testLatestNativeVersionUsesNumericOrdering() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try fakeCLI(root.appendingPathComponent(".local/share/claude/versions/2.1.9"))
        let latest = try fakeCLI(root.appendingPathComponent(".local/share/claude/versions/2.1.52"))

        XCTAssertEqual(try resolve(homeURL: root).executableURL.resolvingSymlinksInPath(), latest.resolvingSymlinksInPath())
    }

    func testEmailIsPassedAsOneArgumentAndNodeIsAvailableInGUIEnvironment() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = try fakeCLI(root.appendingPathComponent("npm/bin/claude"))
        let command = try ClaudeCLI.resolveLoginCommand(
            email: "  user+team@example.com  ",
            homeURL: root,
            environment: ["PATH": "/usr/bin:/bin"],
            searchDirectories: [cli.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/bin", "/bin"]
        )

        XCTAssertEqual(command.arguments, ["auth", "login", "--email", "user+team@example.com"])
        XCTAssertTrue(try XCTUnwrap(command.environment["PATH"]).contains("/opt/homebrew/bin"))
        XCTAssertFalse(command.arguments.contains("--claudeai"))
    }

    func testOnlyLegacyInstallationReportsUpdateNeeded() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try fakeCLI(root.appendingPathComponent(".local/bin/claude"), supportsLogin: false)

        XCTAssertThrowsError(try resolve(homeURL: root)) {
            XCTAssertEqual($0 as? ClaudeNativeError, .claudeCLIIncompatible)
        }
    }

    func testNoInstallationReportsMissingCLI() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try resolve(homeURL: root)) {
            XCTAssertEqual($0 as? ClaudeNativeError, .claudeCLIUnavailable)
        }
    }

    func testUnresponsiveProbeTimesOutAndFallsBack() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stalled = root.appendingPathComponent(".local/bin/claude")
        try writeExecutable("#!/bin/sh\nexec /bin/sleep 5\n", to: stalled)
        let compatible = try fakeCLI(root.appendingPathComponent("another/bin/claude"))
        let command = try ClaudeCLI.resolveLoginCommand(
            email: nil,
            homeURL: root,
            environment: [:],
            searchDirectories: [compatible.deletingLastPathComponent().path],
            probeTimeout: 1
        )

        XCTAssertEqual(command.executableURL, compatible)
    }

    private func resolve(homeURL: URL, searchDirectories: [String] = []) throws -> ClaudeLoginCommand {
        try ClaudeCLI.resolveLoginCommand(
            email: nil,
            homeURL: homeURL,
            environment: [:],
            searchDirectories: searchDirectories
        )
    }

    @discardableResult
    private func fakeCLI(_ url: URL, supportsLogin: Bool = true) throws -> URL {
        let usage = supportsLogin ? "Usage: claude auth login [options]" : "Usage: claude [options] [command] [prompt]"
        // Only help probes are allowed; a test must never accidentally initiate login.
        try writeExecutable("""
        #!/bin/sh
        if [ "$1" != "auth" ] || [ "$2" != "login" ] || [ "$3" != "--help" ]; then
            exit 99
        fi
        printf '%s\\n' '\(usage)'
        """, to: url)
        return url
    }

    private func writeExecutable(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("Headroom-ClaudeCLITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
