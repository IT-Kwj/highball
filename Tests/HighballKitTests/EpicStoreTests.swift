import XCTest
@testable import HighballKit

final class EpicStoreTests: XCTestCase {
    /// highball#409: an install legendary refused reached the player as "epic install exited with 1".
    func testLegendaryInstallFailuresBecomeSentences() {
        XCTAssertEqual(EpicStore.installFailure("[cli] CRITICAL: Not enough available disk space! 51200.00 MiB < 122880.00 MiB"),
                       "This Mac doesn't have enough free space for the game. It needs 120 GB and 50 GB are free. Free some space, then press Install again.")
        XCTAssertNil(EpicStore.installFailure("[cli] CRITICAL: Installation cannot proceed, exiting."), "the summary line adds nothing")
        XCTAssertEqual(EpicStore.installFailure("[cli] ERROR: Game is not owned by this account"),
                       "Epic's installer stopped with this message. Game is not owned by this account")
        XCTAssertNil(EpicStore.installFailure("[cli] INFO: Download size: 95232.19 MiB (Compression savings: 2.1%)"))
    }

    /// Legendary has no terminal under Highball: the selective-download prompt (optional
    /// language packs) raised EOFError and killed the install (#110). `-y` alone does not skip it.
    /// legendary's lines as a GTA V Enhanced install printed them (highball#287): the size once,
    /// then the amount downloaded, which the activity strip turns into a bar and bytes.
    func testLegendarySizeAndProgressLines() {
        XCTAssertEqual(EpicStore.downloadSize(inLegendaryLine: "[cli] INFO: Download size: 95232.19 MiB (Compression savings: 2.1%)"),
                       Int64(95232.19 * 1_048_576))
        XCTAssertEqual(EpicStore.downloaded(inLegendaryLine: "[DLManager] INFO:  - Downloaded: 9075.51 MiB, Written: 9415.55 MiB"),
                       Int64(9075.51 * 1_048_576))
        for other in ["[DLManager] INFO: = Progress: 10.07% (10035/99671), Running for 00:06:22, ETA: 00:56:57",
                      "[DLManager] INFO:  - Cache usage: 463.00 MiB, active tasks: 32",
                      "[DLManager] INFO:  + Download\t- 27.94 MiB/s (raw) / 27.94 MiB/s (decompressed)",
                      "[cli] INFO: Install size: 97000.00 MiB",
                      "[DLManager] INFO:  - Downloaded: n/a"] {
            XCTAssertNil(EpicStore.downloadSize(inLegendaryLine: other), other)
            XCTAssertNil(EpicStore.downloaded(inLegendaryLine: other), other)
        }
    }

    func testInstallAnswersEveryPromptOnTheCommandLine() {
        let args = EpicStore.installArguments(appName: "Phoenix", basePath: "/c/Games")
        XCTAssertTrue(args.contains("-y"))
        XCTAssertTrue(args.contains("--skip-sdl"))
        XCTAssertEqual(Array(args.prefix(2)), ["install", "Phoenix"])
        XCTAssertEqual(args[args.firstIndex(of: "--base-path")! + 1], "/c/Games")
    }
}
