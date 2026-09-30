import Darwin
import Foundation
import KeepAwakeCore

private var interrupted: sig_atomic_t = 0
signal(SIGTERM) { _ in interrupted = 1 }
signal(SIGINT) { _ in interrupted = 1 }
signal(SIGHUP) { _ in interrupted = 1 }

func applySleepDisabled(_ disabled: Bool) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = ["-a", "disablesleep", disabled ? "1" : "0"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return false }
    let limit = ProcessInfo.processInfo.systemUptime + 5
    while process.isRunning && ProcessInfo.processInfo.systemUptime < limit { usleep(50_000) }
    if process.isRunning {
        process.terminate()
        let terminateDeadline = ProcessInfo.processInfo.systemUptime + 1
        while process.isRunning && ProcessInfo.processInfo.systemUptime < terminateDeadline { usleep(50_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        return false
    }
    for _ in 0..<10 {
        if KeepAwakePower.sleepDisabled() == disabled { return process.terminationStatus == 0 }
        usleep(100_000)
    }
    return false
}

struct SystemSessionEnvironment: KeepAwakeSessionEnvironment {
    let fd: Int32
    let brightness = LidBrightnessSession(display: SystemBuiltInDisplayBrightness())
    var now: Date { Date() }
    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var interrupted: Bool { isInterrupted() }
    var batteryPercent: Int? { KeepAwakePower.dischargingBatteryPercent() }
    var sleepDisabled: Bool? { KeepAwakePower.sleepDisabled() }
    func setSleepDisabled(_ disabled: Bool) -> Bool { applySleepDisabled(disabled) }
    func send(_ message: String) { KeepAwakeSocket.send(message, to: fd) }
    func waitBeforeRetry() { sleep(1) }
    func updateDisplayBrightness() { brightness.update(lidClosed: KeepAwakePower.lidClosed()) }
    func restoreDisplayBrightness() -> Bool { brightness.restore() }
    func waitForStop() -> String? {
        guard KeepAwakeSocket.readable(fd, milliseconds: 500) else { return nil }
        // STOP, malformed commands, and app exit all end the session. No arbitrary commands.
        return (try? KeepAwakeSocket.receive(fd)) == "STOP" ? "stopped" : "closed"
    }
}

func isInterrupted() -> Bool { interrupted != 0 }

func run() throws {
    let args = CommandLine.arguments
    guard geteuid() == 0, args.count == 4,
          let uid = uid_t(args[2]), uid != 0,
          let duration = TimeInterval(args[3]), KeepAwakePolicy.validDuration(duration) else {
        fputs("Headroom helper: invalid arguments or missing administrator privileges.\n", stderr)
        exit(64)
    }
    let fd = try KeepAwakeSocket.make()
    defer { close(fd) }
    try KeepAwakeSocket.connect(fd, path: args[1])
    guard KeepAwakeSocket.peerUID(fd) == uid else {
        fputs("Headroom helper: the app connection has the wrong user identity.\n", stderr)
        exit(65)
    }
    guard KeepAwakeSocket.readable(fd, milliseconds: 5_000),
          try KeepAwakeSocket.receive(fd) == "START" else {
        fputs("Headroom helper: the app did not confirm session startup.\n", stderr)
        exit(66)
    }

    // Serialize our sessions; refuse to take over another utility's existing sleep override.
    let lockFD = open("/var/run/codex-vitals-keep-awake.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard lockFD >= 0 else { KeepAwakeSocket.send("ERROR lock", to: fd); return }
    defer { close(lockFD) }
    guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { KeepAwakeSocket.send("ERROR busy", to: fd); return }
    KeepAwakeSession.run(duration: duration, environment: SystemSessionEnvironment(fd: fd))
}

do { try run() } catch {
    fputs("Headroom helper: local connection failed (\(error)).\n", stderr)
    exit(1)
}
