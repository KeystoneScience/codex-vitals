import AppKit
import Foundation

enum ClaudeLoginBrowser {
    struct Capture {
        let executableURL: URL
        let outputURL: URL
    }

    static func prepareCapture(in directory: URL, fileManager: FileManager = .default) throws -> Capture {
        let executableURL = directory.appendingPathComponent("open-browser")
        let outputURL = directory.appendingPathComponent("browser-url")
        // Capture the URL the CLI actually opens. Its console output contains a
        // different manual-code URL, which cannot finish the local callback flow.
        let script = "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$HEADROOM_CLAUDE_AUTH_URL_FILE\"\n"
        try Data(script.utf8).write(to: executableURL)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)
        guard fileManager.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ClaudeNativeError.browserLoginUnavailable
        }
        return Capture(executableURL: executableURL, outputURL: outputURL)
    }

    static func authorizationURL(in output: String) -> URL? {
        guard let expression = try? NSRegularExpression(pattern: "https://[^\\s\\u001b]+") else { return nil }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        for match in expression.matches(in: output, range: range) {
            guard let matchRange = Range(match.range, in: output),
                  let components = URLComponents(string: String(output[matchRange])),
                  components.scheme == "https",
                  let host = components.host,
                  ["claude.ai", "console.anthropic.com", "platform.claude.com"].contains(host),
                  components.path == "/oauth/authorize",
                  let items = components.queryItems,
                  let redirect = items.first(where: { $0.name == "redirect_uri" })?.value,
                  let callback = URLComponents(string: redirect),
                  callback.scheme == "http",
                  let callbackHost = callback.host,
                  ["localhost", "127.0.0.1", "[::1]"].contains(callbackHost),
                  callback.path == "/callback",
                  let port = callback.port, (1...65535).contains(port),
                  items.contains(where: { $0.name == "response_type" && $0.value == "code" }),
                  items.contains(where: { $0.name == "state" && $0.value?.isEmpty == false }),
                  items.contains(where: { $0.name == "code_challenge" && $0.value?.isEmpty == false }),
                  let url = components.url else { continue }
            return url
        }
        return nil
    }

    @MainActor
    static func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}
