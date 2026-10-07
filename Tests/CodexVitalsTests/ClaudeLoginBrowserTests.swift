import Foundation
import XCTest
@testable import CodexVitals

final class ClaudeLoginBrowserTests: XCTestCase {
    private let authorization = "https://claude.ai/oauth/authorize?response_type=code&state=test-state&code_challenge=test-challenge&redirect_uri=http%3A%2F%2Flocalhost%3A54321%2Fcallback"

    func testExtractsClaudeAuthorizationURLFromRedirectedCLIOutput() throws {
        let output = "\(authorization)\n"
        XCTAssertEqual(ClaudeLoginBrowser.authorizationURL(in: output)?.absoluteString, authorization)
    }

    func testIgnoresUnrelatedOrUnsafeURLs() {
        for url in [
            "https://claude.ai.evil.example/oauth/authorize?response_type=code&state=test&code_challenge=test",
            "http://claude.ai/oauth/authorize?response_type=code&state=test&code_challenge=test",
            "https://claude.ai/docs",
            "https://claude.ai/oauth/authorize?response_type=code",
        ] {
            XCTAssertNil(ClaudeLoginBrowser.authorizationURL(in: url))
        }
    }

    func testHandlesAnsiOutputWithoutIncludingTerminalEscapeSequence() {
        XCTAssertEqual(ClaudeLoginBrowser.authorizationURL(in: "\u{001B}[32m\(authorization)\u{001B}[0m")?.absoluteString, authorization)
    }

    func testManualCodeURLCannotReplaceLocalCallbackURL() {
        let manual = authorization.replacingOccurrences(
            of: "http%3A%2F%2Flocalhost%3A54321%2Fcallback",
            with: "https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback"
        )
        XCTAssertNil(ClaudeLoginBrowser.authorizationURL(in: manual))
        XCTAssertEqual(ClaudeLoginBrowser.authorizationURL(in: manual + "\n" + authorization)?.absoluteString, authorization)
    }

    func testBrowserCapturePreservesCallbackURLAndPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Headroom-BrowserCapture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = try ClaudeLoginBrowser.prepareCapture(in: directory)
        let process = Process()
        process.executableURL = capture.executableURL
        process.arguments = [authorization]
        process.environment = ["HEADROOM_CLAUDE_AUTH_URL_FILE": capture.outputURL.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: capture.outputURL, encoding: .utf8), authorization + "\n")
        for (url, mode) in [(capture.executableURL, 0o700), (capture.outputURL, 0o600)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, mode)
        }
    }
}
