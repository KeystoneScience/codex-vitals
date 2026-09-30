import AppKit
import Combine
import Darwin
import Foundation
import KeepAwakeCore
import OSLog

protocol KeepAwakeSessionTransport: AnyObject {
    func start(duration: TimeInterval, event: @escaping (String) -> Void)
    func stop()
}

@MainActor
final class KeepAwakeController: ObservableObject {
    static let shared = KeepAwakeController()

    enum Phase: Equatable { case off, starting, active, stopping }
    @Published private(set) var phase: Phase = .off
    @Published private(set) var deadline: Date?
    @Published private(set) var message: String?
    @Published private(set) var brightnessWarning: String?
    @Published private(set) var systemSleepDisabled: Bool?
    @Published private(set) var startingDetail = "Waiting for macOS approval…"
    private let makeTransport: () -> KeepAwakeSessionTransport
    private let readSleepDisabled: () -> Bool?
    private var transport: KeepAwakeSessionTransport?
    private var generation = UUID()

    init(
        makeTransport: @escaping () -> KeepAwakeSessionTransport = { KeepAwakeProcessSession() },
        readSleepDisabled: @escaping () -> Bool? = { KeepAwakePower.sleepDisabled() }
    ) {
        self.makeTransport = makeTransport
        self.readSleepDisabled = readSleepDisabled
        systemSleepDisabled = readSleepDisabled()
    }

    var isConfirmedOn: Bool { systemSleepDisabled == true }
    var canStart: Bool { phase == .off && systemSleepDisabled == false }

    var statusText: String {
        switch phase {
        case .off:
            switch systemSleepDisabled {
            case .some(let disabled): return disabled ? "On elsewhere" : "Off"
            case .none: return "Status unknown"
            }
        case .starting: return startingDetail == "Waiting for macOS approval…" ? "Waiting for approval…" : "Starting…"
        case .active:
            guard isConfirmedOn else {
                return systemSleepDisabled == false ? "Off · Session ending" : "Status unknown"
            }
            return deadline.map { "On until \(ResetFormatter.timeText($0))" } ?? "On · No timer"
        case .stopping: return "Turning off…"
        }
    }

    var label: String { "Keep awake · \(statusText)" }

    func refreshSystemState() { systemSleepDisabled = readSleepDisabled() }

    func start(minutes: Int) {
        guard phase == .off else { return }
        guard (0...720).contains(minutes) else {
            message = "Choose Never or a duration from 1 minute to 12 hours."
            return
        }
        refreshSystemState()
        guard canStart else {
            message = isConfirmedOn
                ? "Sleep is already disabled outside this session. Turn it off in the app that enabled it first."
                : "Unable to read the Mac’s sleep setting. Try again."
            return
        }
        message = nil
        brightnessWarning = nil
        startingDetail = "Waiting for macOS approval…"
        phase = .starting
        generation = UUID()
        let current = generation
        let session = makeTransport()
        transport = session
        session.start(duration: TimeInterval(minutes) * 60) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                self.receive(event)
            }
        }
    }

    func stop() {
        guard phase != .off, transport != nil else { return }
        phase = .stopping
        transport?.stop()
    }

    private func receive(_ event: String) {
        if event == "NOTICE brightness-restore" {
            brightnessWarning = "macOS could not restore the screen brightness. Use the brightness keys to adjust it."
            return
        }
        if event == "CONNECTED" {
            startingDetail = "Approved. Enabling keep awake…"
            return
        }
        let activeValue = event.hasPrefix("ACTIVE ") ? String(event.dropFirst(7)) : nil
        let activeEpoch = activeValue.flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }
        if activeValue == "never" || activeEpoch != nil {
            deadline = activeEpoch.map { Date(timeIntervalSince1970: $0) }
            systemSleepDisabled = true // The helper sends ACTIVE only after verifying the kernel flag.
            // Cancelling the administrator prompt can race with successful helper startup.
            if phase == .stopping { transport?.stop() } else { phase = .active }
            return
        }
        if event == "ERROR restoring" {
            phase = .stopping
            message = "macOS has not restored sleep yet. Retrying automatically…"
            return
        }
        switch event {
        case "STOPPED expired": message = "Timer finished. Normal sleep is restored."
        case "STOPPED battery": message = "Stopped at 15% battery. Normal sleep is restored."
        case "STOPPED changed": message = "Sleep was re-enabled outside Headroom."
        case "STOPPED stopped", "STOPPED closed": message = nil
        case "CANCELLED": message = "Administrator approval was cancelled. Keep awake is off."
        case "ERROR authorization": message = "macOS did not grant administrator approval. Keep awake was not started."
        case "ERROR timeout": message = "The administrator prompt timed out. Try starting again."
        case "ERROR handshake": message = "Administrator approval finished, but the helper did not connect. Keep awake was not started."
        case "ERROR missing-helper": message = "The keep-awake helper is missing from the app. Reinstall Headroom."
        case "ERROR lock": message = "The keep-awake helper could not open its session lock. Keep awake was not started."
        case "ERROR launch": message = "The keep-awake helper could not launch. Keep awake was not started."
        case "ERROR busy": message = "Another keep-awake session is already controlling sleep. Turn it off first."
        case "ERROR battery": message = "Connect power or charge above 15% to start."
        case "ERROR unsupported": message = "This Mac did not report closed-lid sleep support."
        case "ERROR enable": message = "macOS could not enable keep awake. Normal sleep is restored."
        case "ERROR disconnected":
            message = "The keep-awake helper disconnected. Check the Mac’s sleep setting before closing the lid."
        default:
            if event.hasPrefix("ERROR launch-detail ") {
                message = "The helper could not start: \(event.dropFirst(20))"
            } else {
                message = "Keep awake could not start (\(event))."
            }
        }
        phase = .off
        deadline = nil
        transport = nil
        refreshSystemState()
    }
}

/// A helper exists only for the requested session, with no installed daemon or sudo grant.
/// Closing this connection makes the privileged watchdog restore normal sleep.
final class KeepAwakeProcessSession: KeepAwakeSessionTransport, @unchecked Sendable {
    private static let logger = Logger(subsystem: "app.codexvitals.menubar", category: "KeepAwake")
    private let lock = NSLock()
    private var cancelled = false
    private var peer: Int32 = -1

    func stop() {
        lock.lock()
        cancelled = true
        if peer >= 0 { KeepAwakeSocket.send("STOP", to: peer) }
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func start(duration: TimeInterval, event: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let report: (String) -> Void = { message in
                Self.logger.notice("Session: \(message, privacy: .public)")
                event(message)
            }
            do { try run(duration: duration, event: report) }
            catch { report(isCancelled ? "CANCELLED" : "ERROR launch") }
        }
    }

    private func run(duration: TimeInterval, event: @escaping (String) -> Void) throws {
        guard KeepAwakePolicy.validDuration(duration),
              let helper = Bundle.main.executableURL?.deletingLastPathComponent()
                .appendingPathComponent("CodexVitalsKeepAwake"),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            event("ERROR missing-helper"); return
        }
        // A short private pathname fits sockaddr_un even with long macOS temp paths.
        let directory = URL(fileURLWithPath: "/private/tmp/codex-vitals-awake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("session").path
        let server = try KeepAwakeSocket.make()
        defer { close(server) }
        try KeepAwakeSocket.bind(server, path: socketPath)

        let script = Self.authorizationScript(helper: helper.path, socketPath: socketPath, uid: getuid(), duration: duration)
        let authorization = Process()
        authorization.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        authorization.arguments = ["-e", script]
        let errors = Pipe()
        authorization.standardError = errors
        authorization.standardOutput = FileHandle.nullDevice
        try authorization.run()
        defer { if authorization.isRunning { authorization.terminate() } }
        let start = ProcessInfo.processInfo.systemUptime
        var client: Int32 = -1
        while ProcessInfo.processInfo.systemUptime - start < 180 {
            if isCancelled { event("CANCELLED"); return }
            if !authorization.isRunning {
                let output = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                event(Self.authorizationFailure(output: output, exitCode: authorization.terminationStatus))
                return
            }
            guard KeepAwakeSocket.readable(server, milliseconds: 200) else { continue }
            let candidate = accept(server, nil, nil)
            guard candidate >= 0 else { continue }
            if KeepAwakeSocket.peerUID(candidate) == 0 {
                event("CONNECTED")
                client = candidate
                _ = fcntl(client, F_SETFD, FD_CLOEXEC)
                var one: Int32 = 1
                _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
                break
            }
            close(candidate)
        }
        guard client >= 0 else { event("ERROR timeout"); return }
        lock.lock()
        peer = client
        KeepAwakeSocket.send(cancelled ? "STOP" : "START", to: peer)
        lock.unlock()
        defer {
            lock.lock()
            peer = -1
            close(client)
            lock.unlock()
        }

        while true {
            guard KeepAwakeSocket.readable(client, milliseconds: 500) else { continue }
            do {
                let line = try KeepAwakeSocket.receive(client)
                event(line)
                if line.hasPrefix("STOPPED ") || (line.hasPrefix("ERROR ") && line != "ERROR restoring") { return }
            } catch {
                event(isCancelled ? "CANCELLED" : "ERROR disconnected")
                return
            }
        }
    }

    static func authorizationScript(helper: String, socketPath: String, uid: uid_t, duration: TimeInterval) -> String {
        // Run the helper in the authorized shell's foreground. Backgrounding with nohup hid
        // execution errors and let the authorization process exit before the IPC handshake.
        let command = "exec \(shellQuote(helper)) \(shellQuote(socketPath)) \(uid) \(Int(duration))"
        let purpose = duration == KeepAwakePolicy.noTimer
            ? "Allow Headroom to keep this Mac awake with its lid closed, with no auto-off timer."
            : "Allow Headroom to keep this Mac awake with its lid closed for a limited time."
        return """
        with timeout of 2147483647 seconds
            do shell script \(appleScriptQuote(command)) with administrator privileges with prompt \(appleScriptQuote(purpose))
        end timeout
        """
    }

    static func authorizationFailure(output: String, exitCode: Int32) -> String {
        if output.contains("(-128)") { return "CANCELLED" }
        if output.contains("(-60007)") || output.contains("(-60005)") { return "ERROR authorization" }
        if output.contains("(-1712)") { return "ERROR timeout" }
        guard exitCode != 0 else { return "ERROR handshake" }
        // The shell receives no passwords or account tokens; retain its short execution error.
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "ERROR launch" : "ERROR launch-detail \(detail.prefix(400))"
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
