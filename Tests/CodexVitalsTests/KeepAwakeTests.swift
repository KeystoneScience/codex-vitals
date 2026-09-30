import Darwin
import Foundation
import KeepAwakeCore
import XCTest
@testable import CodexVitals

final class KeepAwakeTests: XCTestCase {
    func testDurationBoundsAcceptExplicitNeverButRejectInvalidSessions() {
        for duration in [-1, 59, .nan, .infinity, 43_201] as [Double] {
            XCTAssertFalse(KeepAwakePolicy.validDuration(duration))
        }
        XCTAssertTrue(KeepAwakePolicy.validDuration(60))
        XCTAssertTrue(KeepAwakePolicy.validDuration(43_200))
        XCTAssertTrue(KeepAwakePolicy.validDuration(0))
    }

    func testNeverSessionDoesNotExpireAfterClockAndElapsedTimeAdvance() {
        let env = SessionEnvironment()
        var waits = 0
        env.onWait = {
            waits += 1
            env.now += 365 * 24 * 60 * 60
            env.uptime += 365 * 24 * 60 * 60
            return waits == 3 ? "stopped" : nil
        }
        KeepAwakeSession.run(duration: 0, environment: env)
        XCTAssertEqual(waits, 3)
        XCTAssertEqual(env.messages, ["ACTIVE never", "STOPPED stopped"])
        XCTAssertEqual(env.changes, [true, false])
    }

    func testNeverSessionStillRestoresSleepOnDisconnectLowBatteryAndQuit() {
        for reason in ["closed", "battery", "stopped"] {
            let env = SessionEnvironment()
            env.onWait = {
                switch reason {
                case "closed": return "closed"
                case "battery": env.batteryPercent = 15
                default: env.interrupted = true
                }
                return nil
            }
            KeepAwakeSession.run(duration: 0, environment: env)
            XCTAssertEqual(env.messages, ["ACTIVE never", "STOPPED \(reason)"])
            XCTAssertEqual(env.changes, [true, false])
        }
    }

    func testTimerRestoresSleepAtDeadline() {
        let env = SessionEnvironment()
        env.onWait = { env.now += 30; env.uptime += 30; return nil }
        KeepAwakeSession.run(duration: 60, environment: env)
        XCTAssertEqual(env.changes, [true, false])
        XCTAssertEqual(env.messages.last, "STOPPED expired")
        XCTAssertFalse(env.sleepDisabled!)
    }

    func testBackwardClockChangeCannotExtendSession() {
        let env = SessionEnvironment()
        env.onWait = { env.now -= 3600; env.uptime += 60; return nil }
        KeepAwakeSession.run(duration: 60, environment: env)
        XCTAssertEqual(env.messages.last, "STOPPED expired")
        XCTAssertEqual(env.changes, [true, false])
    }

    func testManualStopAndAppDisconnectBothRestoreSleep() {
        for reason in ["stopped", "closed"] {
            let env = SessionEnvironment()
            env.onWait = { reason }
            KeepAwakeSession.run(duration: 60, environment: env)
            XCTAssertEqual(env.messages.last, "STOPPED \(reason)")
            XCTAssertEqual(env.changes, [true, false])
        }
    }

    func testLowBatteryEndsActiveSession() {
        let env = SessionEnvironment()
        env.onWait = { env.batteryPercent = 15; return nil }
        KeepAwakeSession.run(duration: 60, environment: env)
        XCTAssertEqual(env.messages.last, "STOPPED battery")
        XCTAssertEqual(env.changes, [true, false])
    }

    func testExistingOverrideAndUnknownSupportAreNotModified() {
        for state: Bool? in [true, nil] {
            let env = SessionEnvironment()
            env.sleepDisabled = state
            KeepAwakeSession.run(duration: 60, environment: env)
            XCTAssertTrue(env.changes.isEmpty)
            XCTAssertEqual(env.messages, [state == true ? "ERROR busy" : "ERROR unsupported"])
        }
    }

    func testAlreadyLowBatteryDoesNotStart() {
        let env = SessionEnvironment()
        env.batteryPercent = 10
        KeepAwakeSession.run(duration: 60, environment: env)
        XCTAssertTrue(env.changes.isEmpty)
        XCTAssertEqual(env.messages, ["ERROR battery"])
    }

    func testFailedEnableStillRollsBackAndNeverReportsActive() {
        let env = SessionEnvironment()
        env.enableSucceeds = false
        KeepAwakeSession.run(duration: 60, environment: env)
        XCTAssertEqual(env.changes, [true, false])
        XCTAssertEqual(env.messages, ["ERROR enable"])
    }

    func testRestoreFailuresRetryBeforeReportingOff() {
        let env = SessionEnvironment()
        env.restoreFailures = 3
        env.onWait = { "stopped" }
        KeepAwakeSession.run(duration: 60, environment: env)
        XCTAssertEqual(env.changes, [true, false, false, false, false])
        XCTAssertEqual(Array(env.messages.suffix(2)), ["ERROR restoring", "STOPPED stopped"])
        XCTAssertFalse(env.sleepDisabled!)
    }

    func testTerminationSignalRestoresSleep() {
        let env = SessionEnvironment()
        env.onWait = { env.interrupted = true; return nil }
        KeepAwakeSession.run(duration: 60, environment: env)
        XCTAssertEqual(env.changes, [true, false])
        XCTAssertEqual(env.messages.last, "STOPPED stopped")
    }

    func testEverySessionExitRestoresBrightnessBeforeAllowingSleep() {
        for reason in ["stopped", "closed", "expired", "battery", "changed", "signal"] {
            let env = SessionEnvironment()
            env.onWait = {
                switch reason {
                case "expired": env.uptime += 60
                case "battery": env.batteryPercent = 15
                case "changed": env.sleepDisabled = false
                case "signal": env.interrupted = true
                default: return reason
                }
                return nil
            }
            KeepAwakeSession.run(duration: 60, environment: env)
            XCTAssertGreaterThan(env.brightnessUpdates, 0)
            XCTAssertEqual(Array(env.cleanup.suffix(2)), ["brightness", "sleep"])
        }
    }

    func testBrightnessRestoreFailureDoesNotBlockSleepRestoration() {
        let env = SessionEnvironment()
        env.brightnessRestoreFailures = 3
        KeepAwakeSession.run(duration: 60, environment: env)
        XCTAssertEqual(Array(env.messages.suffix(2)), ["NOTICE brightness-restore", "STOPPED stopped"])
        XCTAssertEqual(env.cleanup, ["brightness", "brightness", "brightness", "sleep"])
        XCTAssertEqual(env.sleepDisabled, false)
    }

    @MainActor
    func testBrightnessWarningDoesNotEndSessionOrGetLostOnStop() async {
        let transport = FakeTransport()
        let controller = KeepAwakeController(makeTransport: { transport }, readSleepDisabled: { false })
        controller.start(minutes: 1)
        transport.event?("ACTIVE never")
        transport.event?("NOTICE brightness-restore")
        await drainEvents()
        XCTAssertEqual(controller.phase, .active)
        XCTAssertNotNil(controller.brightnessWarning)
        transport.event?("STOPPED stopped")
        await drainEvents()
        XCTAssertEqual(controller.phase, .off)
        XCTAssertNotNil(controller.brightnessWarning)
    }

    func testPrivateSocketRoundTripPeerIdentityAndDisconnect() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/vitals-socket-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try KeepAwakeSocket.make()
        defer { close(server) }
        let path = directory.appendingPathComponent("s").path
        try KeepAwakeSocket.bind(server, path: path)
        let client = try KeepAwakeSocket.make()
        try KeepAwakeSocket.connect(client, path: path)
        XCTAssertTrue(KeepAwakeSocket.readable(server, milliseconds: 200))
        let peer = accept(server, nil, nil)
        XCTAssertGreaterThanOrEqual(peer, 0)
        defer { close(peer) }
        XCTAssertEqual(KeepAwakeSocket.peerUID(peer), getuid())
        XCTAssertTrue(KeepAwakeSocket.send("STOP", to: client))
        XCTAssertEqual(try KeepAwakeSocket.receive(peer), "STOP")
        close(client)
        XCTAssertTrue(KeepAwakeSocket.readable(peer, milliseconds: 200))
        XCTAssertThrowsError(try KeepAwakeSocket.receive(peer))
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    @MainActor
    func testControllerWaitsForHelperAndTimerCompletion() async {
        let transport = FakeTransport()
        let controller = KeepAwakeController(makeTransport: { transport }, readSleepDisabled: { false })
        controller.start(minutes: 60)
        XCTAssertEqual(controller.phase, .starting)
        XCTAssertEqual(controller.label, "Keep awake · Waiting for approval…")
        XCTAssertEqual(transport.duration, 3600)
        XCTAssertNil(controller.deadline)
        transport.event?("ACTIVE 1800000000")
        await drainEvents()
        XCTAssertEqual(controller.phase, .active)
        XCTAssertNotNil(controller.deadline)
        XCTAssertTrue(controller.statusText.hasPrefix("On until "))
        controller.stop()
        XCTAssertEqual(controller.phase, .stopping)
        transport.event?("ERROR restoring")
        await drainEvents()
        XCTAssertEqual(controller.phase, .stopping)
        transport.event?("STOPPED expired")
        await drainEvents()
        XCTAssertEqual(controller.phase, .off)
        XCTAssertEqual(controller.label, "Keep awake · Off")
        XCTAssertNil(controller.deadline)
        XCTAssertEqual(controller.message, "Timer finished. Normal sleep is restored.")
    }

    @MainActor
    func testCancelDuringAuthorizationCannotBecomeActive() async {
        let transport = FakeTransport()
        let controller = KeepAwakeController(makeTransport: { transport }, readSleepDisabled: { false })
        controller.start(minutes: 15)
        controller.stop()
        transport.event?("ACTIVE 1800000000")
        await drainEvents()
        XCTAssertEqual(controller.phase, .stopping)
        XCTAssertEqual(transport.stops, 2)
        transport.event?("CANCELLED")
        await drainEvents()
        XCTAssertEqual(controller.phase, .off)
    }

    @MainActor
    func testNeverIsOnlyShownAsOnAfterHelperConfirms() async {
        let transport = FakeTransport()
        let controller = KeepAwakeController(makeTransport: { transport }, readSleepDisabled: { false })
        XCTAssertEqual(controller.statusText, "Off")
        controller.start(minutes: 0)
        XCTAssertEqual(transport.duration, 0)
        XCTAssertEqual(controller.statusText, "Waiting for approval…")
        XCTAssertFalse(controller.isConfirmedOn)
        transport.event?("ACTIVE never")
        await drainEvents()
        XCTAssertEqual(controller.phase, .active)
        XCTAssertEqual(controller.statusText, "On · No timer")
        XCTAssertTrue(controller.isConfirmedOn)
        XCTAssertNil(controller.deadline)
        controller.stop()
        XCTAssertEqual(controller.statusText, "Turning off…")
        transport.event?("STOPPED stopped")
        await drainEvents()
        XCTAssertEqual(controller.statusText, "Off")
    }

    @MainActor
    func testExistingSystemOverrideIsVisibleAndCannotStartAnotherSession() {
        let transport = FakeTransport()
        var systemState: Bool? = true
        let controller = KeepAwakeController(makeTransport: { transport }, readSleepDisabled: { systemState })
        XCTAssertEqual(controller.statusText, "On elsewhere")
        XCTAssertTrue(controller.isConfirmedOn)
        XCTAssertFalse(controller.canStart)
        controller.start(minutes: 0)
        XCTAssertNil(transport.duration)
        systemState = false
        controller.refreshSystemState()
        XCTAssertEqual(controller.statusText, "Off")
        XCTAssertTrue(controller.canStart)
        systemState = nil
        controller.refreshSystemState()
        XCTAssertEqual(controller.statusText, "Status unknown")
        XCTAssertFalse(controller.canStart)
    }

    @MainActor
    func testLostConnectionDoesNotReportOffWhileSleepIsStillDisabled() async {
        let transport = FakeTransport()
        var systemState = false
        let controller = KeepAwakeController(makeTransport: { transport }, readSleepDisabled: { systemState })
        controller.start(minutes: 0)
        systemState = true
        transport.event?("ACTIVE never")
        await drainEvents()
        transport.event?("ERROR disconnected")
        await drainEvents()
        XCTAssertEqual(controller.statusText, "On elsewhere")
        XCTAssertTrue(controller.isConfirmedOn)
        systemState = false
        controller.refreshSystemState()
        XCTAssertEqual(controller.statusText, "Off")
    }

    @MainActor
    private func drainEvents() async {
        // The callback hops onto the main actor just as a background socket event does.
        for _ in 0..<5 { await Task.yield() }
    }

    func testAuthorizationUsesForegroundHelperAndPreservesExecutionErrors() {
        let script = KeepAwakeProcessSession.authorizationScript(
            helper: "/Applications/Headroom.app/Contents/MacOS/helper",
            socketPath: "/private/tmp/test/session", uid: 501, duration: 60
        )
        XCTAssertTrue(script.contains("do shell script \"exec '"))
        XCTAssertTrue(script.contains("with administrator privileges"))
        XCTAssertTrue(script.contains("with timeout of 2147483647 seconds"))
        XCTAssertFalse(script.contains("nohup"))
        XCTAssertFalse(script.contains("/dev/null"))
        XCTAssertFalse(script.contains(" &"))
        XCTAssertEqual(KeepAwakeProcessSession.authorizationFailure(output: "execution error: User canceled. (-128)", exitCode: 1), "CANCELLED")
        XCTAssertEqual(KeepAwakeProcessSession.authorizationFailure(output: "", exitCode: 0), "ERROR handshake")
        XCTAssertEqual(KeepAwakeProcessSession.authorizationFailure(output: "Permission denied (126)", exitCode: 1), "ERROR launch-detail Permission denied (126)")
    }

    @MainActor
    func testApprovalAndHelperLaunchAreDifferentStatesAndFailureIsVisible() async {
        let transport = FakeTransport()
        let controller = KeepAwakeController(makeTransport: { transport }, readSleepDisabled: { false })
        controller.start(minutes: 1)
        XCTAssertEqual(controller.startingDetail, "Waiting for macOS approval…")
        transport.event?("CONNECTED")
        await drainEvents()
        XCTAssertEqual(controller.startingDetail, "Approved. Enabling keep awake…")
        XCTAssertEqual(controller.statusText, "Starting…")
        XCTAssertFalse(controller.isConfirmedOn)
        transport.event?("ERROR launch-detail Permission denied (126)")
        await drainEvents()
        XCTAssertEqual(controller.statusText, "Off")
        XCTAssertEqual(controller.message, "The helper could not start: Permission denied (126)")
    }
}

private final class FakeTransport: KeepAwakeSessionTransport {
    var duration: TimeInterval?
    var event: ((String) -> Void)?
    var stops = 0
    func start(duration: TimeInterval, event: @escaping (String) -> Void) { self.duration = duration; self.event = event }
    func stop() { stops += 1 }
}

private final class SessionEnvironment: KeepAwakeSessionEnvironment {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var uptime: TimeInterval = 100
    var interrupted = false
    var batteryPercent: Int? = nil
    var sleepDisabled: Bool? = false
    var changes: [Bool] = []
    var messages: [String] = []
    var onWait: () -> String? = { "stopped" }
    var enableSucceeds = true
    var restoreFailures = 0
    var brightnessUpdates = 0
    var brightnessRestoreFailures = 0
    var cleanup: [String] = []
    func setSleepDisabled(_ disabled: Bool) -> Bool {
        if !disabled { cleanup.append("sleep") }
        changes.append(disabled)
        if !disabled && restoreFailures > 0 { restoreFailures -= 1; return false }
        sleepDisabled = disabled
        return !disabled || enableSucceeds
    }
    func waitForStop() -> String? { onWait() }
    func send(_ message: String) { messages.append(message) }
    func waitBeforeRetry() {}
    func updateDisplayBrightness() { brightnessUpdates += 1 }
    func restoreDisplayBrightness() -> Bool {
        cleanup.append("brightness")
        if brightnessRestoreFailures > 0 { brightnessRestoreFailures -= 1; return false }
        return true
    }
}
