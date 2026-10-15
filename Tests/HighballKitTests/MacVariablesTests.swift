import XCTest
@testable import HighballKit

/// A recipe's value that depends on the Mac (a video memory budget from its memory) keeps its
/// formula in the settings and gets this Mac's number at each launch.
final class MacVariablesTests: XCTestCase {
    func testMemoryAndAShareOfIt() {
        XCTAssertEqual(MacVariables.expand("${memoryMB}", memoryMB: 32768), "32768")
        XCTAssertEqual(MacVariables.expand("dxgi.maxVideoMemoryBudget=${memoryMB*0.375}", memoryMB: 32768), "dxgi.maxVideoMemoryBudget=12288",
                       "the budget measured on the 32 GB M4")
        XCTAssertEqual(MacVariables.expand("${memoryMB*0.375}", memoryMB: 16384), "6144")
        XCTAssertEqual(MacVariables.expand("${memoryMB*0.3}", memoryMB: 24576), "7372", "rounded down")
        XCTAssertEqual(MacVariables.expand("a=${memoryMB*2};b=${memoryMB}", memoryMB: 8192), "a=16384;b=8192")
    }

    func testAnythingElseStaysAsWritten() {
        XCTAssertEqual(MacVariables.expand("plain", memoryMB: 1), "plain")
        XCTAssertEqual(MacVariables.expand("${HOME}/x", memoryMB: 1), "${HOME}/x")
        XCTAssertEqual(MacVariables.expand("${memoryMB*}", memoryMB: 1), "${memoryMB*}")
        XCTAssertEqual(MacVariables.expand("${memoryMB*-1}", memoryMB: 1), "${memoryMB*-1}")
    }

    func testMachineMemoryIsReal() {
        XCTAssertGreaterThanOrEqual(Machine.memoryMB, 4096)
        XCTAssertEqual(MacVariables.expand("${memoryMB}"), String(Machine.memoryMB))
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "hb-macvars-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func engine() throws -> InstalledEngine {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "spike/engine-manifest.json")
        let engineRoot = root.appending(path: "engine")
        for name in ["dxmt", "dxvk", "d9vk"] {
            try FileManager.default.createDirectory(at: engineRoot.appending(path: "frameworks/renderer/\(name)/wine"), withIntermediateDirectories: true)
        }
        return InstalledEngine(manifest: try EngineManifest.load(from: url), root: engineRoot)
    }

    func testALaunchGetsThisMacsNumberAndTheSettingKeepsTheFormula() throws {
        var b = Bottle(url: root.appending(path: "bottle"), settings: BottleSettings(name: "t", engineID: "e"))
        b.settings.renderer = .dxvk
        b.settings.environment["DXVK_CONFIG"] = "dxgi.maxVideoMemoryBudget=${memoryMB*0.375}"
        let env = try b.environment(engine: try engine(), extra: ["GAME_ONLY": "${memoryMB}"])
        XCTAssertEqual(env["DXVK_CONFIG"], "dxgi.maxVideoMemoryBudget=\(Machine.memoryMB * 3 / 8)")
        XCTAssertEqual(env["GAME_ONLY"], String(Machine.memoryMB), "a game's own variables too")
        XCTAssertEqual(b.settings.environment["DXVK_CONFIG"], "dxgi.maxVideoMemoryBudget=${memoryMB*0.375}")

        b.settings.dxvkAppConfig["FlightSimulator2024.exe"] = ["dxgi.maxVideoMemoryBudget": "${memoryMB*0.375}"]
        try b.writeDxvkConfig()
        let conf = try String(contentsOf: b.dxvkConfigURL, encoding: .utf8)
        XCTAssertTrue(conf.contains("dxgi.maxVideoMemoryBudget = \(Machine.memoryMB * 3 / 8)"), conf)
        XCTAssertFalse(conf.contains("${"))
    }
}
