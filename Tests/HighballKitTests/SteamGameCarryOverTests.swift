import XCTest
@testable import HighballKit

/// A game handed to a new environment as a clone. A wrong answer here either downloads 50 GB again for nothing or,
/// worse, gives a second Steam a folder another environment uses.
final class SteamGameCarryOverTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appending(path: "carryover-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// A library folder holding one installed game, as Steam lays it out.
    private func library(_ name: String, appid: Int = 2537590, installdir: String = "MSFS2024", state: Int = 4) throws -> SteamGame {
        let root = tmp.appending(path: name, directoryHint: .isDirectory)
        let game = root.appending(path: "steamapps/common/\(installdir)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: game.appending(path: "Packages"), withIntermediateDirectories: true)
        try Data("exe".utf8).write(to: game.appending(path: "FlightSimulator2024.exe"))
        try Data("package".utf8).write(to: game.appending(path: "Packages/one.fsarchive"))
        try Data("\"AppState\" { \"appid\" \"\(appid)\" \"StateFlags\" \"\(state)\" }".utf8)
            .write(to: root.appending(path: "steamapps/appmanifest_\(appid).acf"))
        return SteamGame(appid: appid, name: "Game", installdir: installdir, sizeOnDisk: 1, stateFlags: state, lastPlayed: nil,
                         libraryRoot: root)
    }

    private func steamapps(_ name: String) throws -> URL {
        let dir = tmp.appending(path: "\(name)/steamapps", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testTheGameAndItsRecordArriveAndTheOriginalStaysAsItWas() throws {
        let game = try library("old")
        let dest = try steamapps("new")
        XCTAssertEqual(SteamGameCarryOver.carry(game, into: dest), .carried)
        let copied = dest.appending(path: "common/MSFS2024")
        XCTAssertEqual(try String(contentsOf: copied.appending(path: "Packages/one.fsarchive"), encoding: .utf8), "package")
        XCTAssertEqual(try String(contentsOf: copied.appending(path: "FlightSimulator2024.exe"), encoding: .utf8), "exe")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appending(path: "appmanifest_2537590.acf").path))
        // The clone is a copy of its own: writing to it leaves the original alone.
        try Data("changed".utf8).write(to: copied.appending(path: "FlightSimulator2024.exe"))
        XCTAssertEqual(try String(contentsOf: game.installFolder!.appending(path: "FlightSimulator2024.exe"), encoding: .utf8), "exe")
    }

    func testAGameStillDownloadingOrUpdatingStaysWhereItIs() throws {
        let game = try library("old", state: 1026)
        let dest = try steamapps("new")
        guard case .skipped = SteamGameCarryOver.carry(game, into: dest) else { return XCTFail("a game Steam is still writing must not be cloned") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appending(path: "common/MSFS2024").path))
        XCTAssertFalse(SteamGameCarryOver.canCarry(game, toBottlesRoot: tmp))
        // Paused, or files missing, on top of an installed build: not whole either.
        for state in [4 | 512, 4 | 32, 4 | 2 | 1024] {
            XCTAssertFalse(SteamGameCarryOver.canCarry(try library("old\(state)", state: state), toBottlesRoot: tmp), "state \(state)")
        }
    }

    /// Fully installed with an update waiting (StateFlags 6): the files of the installed build are all there, so the game
    /// comes along with its record as it is, and the new environment's Steam downloads only the update.
    func testAGameWithAnUpdateWaitingComesAlongAndKeepsItsRecord() throws {
        let game = try library("old", state: 6)
        let dest = try steamapps("new")
        XCTAssertTrue(SteamGameCarryOver.canCarry(game, toBottlesRoot: tmp))
        XCTAssertEqual(SteamGameCarryOver.carry(game, into: dest), .carried)
        XCTAssertEqual(try String(contentsOf: dest.appending(path: "common/MSFS2024/Packages/one.fsarchive"), encoding: .utf8), "package")
        let record = try String(contentsOf: dest.appending(path: "appmanifest_2537590.acf"), encoding: .utf8)
        XCTAssertTrue(record.contains("\"StateFlags\" \"6\""), "the record still says an update is required")
    }

    func testANewEnvironmentThatHasTheGameAlreadyIsLeftAlone() throws {
        let game = try library("old")
        let dest = try steamapps("new")
        try FileManager.default.createDirectory(at: dest.appending(path: "common/MSFS2024"), withIntermediateDirectories: true)
        guard case .skipped = SteamGameCarryOver.carry(game, into: dest) else { return XCTFail("an existing install must not be overwritten") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appending(path: "appmanifest_2537590.acf").path))
    }

    func testARefusedCloneLeavesNothingBehind() throws {
        let game = try library("old")
        let dest = try steamapps("new")
        let outcome = SteamGameCarryOver.carry(game, into: dest) { _, to in
            try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)   // a partial tree
            throw POSIXError(.EXDEV)   // another volume: clonefile refuses
        }
        guard case .skipped = outcome else { return XCTFail("a refused clone must not count as carried") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appending(path: "common/MSFS2024").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appending(path: "appmanifest_2537590.acf").path))
    }

    func testAFolderLinkedToAnotherEnvironmentBecomesFilesOfItsOwn() throws {
        // The M4's FH6 environment kept its game as a link to another environment's copy.
        let real = try library("shared")
        let linked = tmp.appending(path: "linked/steamapps/common", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked.appending(path: "MSFS2024"), withDestinationURL: real.installFolder!)
        try FileManager.default.copyItem(at: real.libraryRoot!.appending(path: "steamapps/appmanifest_2537590.acf"),
                                         to: tmp.appending(path: "linked/steamapps/appmanifest_2537590.acf"))
        let game = SteamGame(appid: 2537590, name: "Game", installdir: "MSFS2024", sizeOnDisk: 1, stateFlags: 4, lastPlayed: nil,
                             libraryRoot: tmp.appending(path: "linked", directoryHint: .isDirectory))
        let dest = try steamapps("new")
        XCTAssertEqual(SteamGameCarryOver.carry(game, into: dest), .carried)
        let copied = dest.appending(path: "common/MSFS2024")
        let kind = try FileManager.default.attributesOfItem(atPath: copied.path)[.type] as? FileAttributeType
        XCTAssertEqual(kind, .typeDirectory, "the new environment must get a folder, not a link to a shared one")
    }

    func testAGameOnThisVolumeCanComeAlong() throws {
        let game = try library("old")
        XCTAssertTrue(SteamGameCarryOver.canCarry(game, toBottlesRoot: tmp))
    }
}
