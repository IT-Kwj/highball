import XCTest
@testable import HighballKit

/// highball#323: the strip's Stop cancelled a task nothing listened to, so an Epic download
/// went on, and outlived the app. Stop now signals legendary and every process it started,
/// the way Ctrl-C in a terminal does, and escalates for whatever is still running.
final class LegendaryControlTests: XCTestCase {
    private func run(_ script: String) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try p.run()
        return p
    }

    private func waitUntil(_ seconds: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { usleep(50_000) }
    }

    private func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    func testStopEndsTheProcessAndEverythingUnderIt() throws {
        // A shell's background jobs ignore SIGINT, as a downloader child might not answer it
        // either, so this also covers the escalation to SIGTERM.
        let p = try run("sleep 60 & sleep 60 & wait")
        waitUntil { LegendaryControl.tree(p.processIdentifier).count >= 3 }
        let tree = LegendaryControl.tree(p.processIdentifier)
        XCTAssertEqual(tree.count, 3, "the shell and its two sleeps")
        XCTAssertEqual(tree.first, p.processIdentifier, "parents first")

        let control = LegendaryControl(grace: 0.3)
        control.started(p)
        control.stop()
        waitUntil { !p.isRunning }
        XCTAssertFalse(p.isRunning)
        waitUntil { !tree.dropFirst().contains(where: alive) }
        XCTAssertFalse(tree.dropFirst().contains(where: alive), "no child left running")
    }

    func testAStopBeforeTheStartStopsItAsSoonAsItStarts() throws {
        let control = LegendaryControl(grace: 0.3)
        control.stop()
        let p = try run("exec sleep 60")
        control.started(p)
        waitUntil { !p.isRunning }
        XCTAssertFalse(p.isRunning)
    }

    func testTheLockRefusalIsRecognized() {
        XCTAssertTrue(EpicStore.refusedForLock("[cli] CRITICAL: Failed to acquire installed data lock, only one instance of Legendary may install/import/move applications at a time."))
        XCTAssertFalse(EpicStore.refusedForLock("[cli] INFO: Download size: 95232.19 MiB (Compression savings: 2.1%)"))
    }
}
