import XCTest
@testable import HighballKit

/// Battle.net games in the library (highball#417): the update agent's product.db read without a
/// schema library, the client's aggregate.json, the launch Battle.net's own shortcuts use, and the
/// tile the library builds. product-client-only.db is the file from a real environment on this
/// project's test Mac, with Battle.net installed and no game (2026-10-29). The game records are
/// built here field by field in the same layout, because no game was installed on that Mac.
final class BattleNetLibraryTests: XCTestCase {
    // MARK: A protocol buffer writer for fixtures

    private enum PB {
        static func varint(_ value: UInt64) -> [UInt8] {
            var v = value, out: [UInt8] = []
            repeat {
                var b = UInt8(v & 0x7F); v >>= 7
                if v != 0 { b |= 0x80 }
                out.append(b)
            } while v != 0
            return out
        }
        static func field(_ n: Int, _ v: UInt64) -> [UInt8] { varint(UInt64(n << 3)) + varint(v) }
        static func field(_ n: Int, _ bytes: [UInt8]) -> [UInt8] { varint(UInt64(n << 3 | 2)) + varint(UInt64(bytes.count)) + bytes }
        static func field(_ n: Int, _ s: String) -> [UInt8] { field(n, Array(s.utf8)) }
    }

    /// One install record as the agent writes it: uid, product code, settings (install path,
    /// region), cached state (base state: installed, playable, version; a backfill progress
    /// holding a double; update progress with the build's total bytes), operations.
    private func record(uid: String, code: String, path: String, installed: Bool = true, playable: Bool = true,
                        version: String = "1.0.0.1", bytes: UInt64 = 0) -> [UInt8] {
        let settings = PB.field(1, path) + PB.field(2, "us") + PB.field(3, 0) + PB.field(6, "enUS")
        let base = PB.field(1, installed ? 1 : 0) + PB.field(2, playable ? 1 : 0) + PB.field(3, 1) + PB.field(7, version)
            + PB.field(10, "")
        let backfill = [0x09] + [UInt8](repeating: 0, count: 6) + [0xF0, 0x3F]        // field 1, double 1.0
        let update = PB.field(4, bytes)
        let cached = PB.field(1, base) + PB.field(2, backfill) + PB.field(4, update)
        return PB.field(1, PB.field(1, uid) + PB.field(2, code) + PB.field(3, settings) + PB.field(4, cached)
                        + PB.field(5, PB.field(2, 0x7FFF_FFFF)) + PB.field(6, "") + PB.field(7, 0))
    }

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appending(path: "hb-bnet-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func bottle(_ name: String = "Games") throws -> Bottle {
        let b = Bottle(url: tmp.appending(path: "bottles/\(name)", directoryHint: .isDirectory),
                       settings: BottleSettings(name: name, engineID: "e"))
        try FileManager.default.createDirectory(at: BattleNetLibrary.agentDirectory(of: b), withIntermediateDirectories: true)
        return b
    }

    @discardableResult
    private func folder(_ relative: String, in b: Bottle, files: [String] = []) throws -> URL {
        let url = b.driveC.appending(path: relative, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for f in files { try Data("MZ".utf8).write(to: url.appending(path: f)) }
        return url
    }

    private func write(_ bytes: [UInt8], aggregate: String? = nil, to b: Bottle) throws {
        let agent = BattleNetLibrary.agentDirectory(of: b)
        try Data(bytes).write(to: agent.appending(path: "product.db"))
        if let aggregate { try Data(aggregate.utf8).write(to: agent.appending(path: "aggregate.json")) }
    }

    private var clientRecords: [UInt8] {
        record(uid: "agent", code: "agent", path: "C:/ProgramData/Battle.net/Agent", playable: false)
            + record(uid: "battle.net", code: "bna", path: "C:/Program Files (x86)/Battle.net")
    }

    // MARK: product.db

    func testRealProductDBWithOnlyTheClientHasNoGames() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/battlenet/product-client-only.db")
        let installs = try ProductDB.installs(in: Data(contentsOf: fixture))
        XCTAssertEqual(installs.map(\.productCode), ["agent", "bna"])
        let client = try XCTUnwrap(installs.last)
        XCTAssertEqual(client.uid, "battle.net")
        XCTAssertEqual(client.installPath, "C:/Program Files (x86)/Battle.net")
        XCTAssertEqual(client.version, "2.52.11.17778")
        XCTAssertTrue(client.installed)
        XCTAssertTrue(client.playable)
        XCTAssertFalse(installs[0].playable, "the agent is installed but never playable")

        let b = try bottle()
        try folder("Program Files (x86)/Battle.net", in: b, files: ["Battle.net Launcher.exe"])
        try FileManager.default.copyItem(at: fixture, to: BattleNetLibrary.agentDirectory(of: b).appending(path: "product.db"))
        try Data(#"{"installed": []}"#.utf8).write(to: BattleNetLibrary.agentDirectory(of: b).appending(path: "aggregate.json"))
        XCTAssertEqual(BattleNetLibrary.games(in: b), [], "the agent and the client are not games")
        XCTAssertEqual(BattleNetLibrary.client(in: b)?.lastPathComponent, "Battle.net Launcher.exe")
    }

    func testInstalledGamesComeFromProductDBAndTheClientsList() throws {
        let b = try bottle()
        let ow = try folder("Program Files (x86)/Overwatch", in: b, files: ["Overwatch Launcher.exe"])
        try folder("Program Files (x86)/Overwatch/_retail_", in: b, files: ["Overwatch.exe"])
        let hs = try folder("Program Files (x86)/Hearthstone", in: b, files: ["Hearthstone Beta Launcher.exe", "Hearthstone.exe"])
        try folder("Program Files (x86)/Diablo IV", in: b)                         // still downloading
        let db = clientRecords
            + record(uid: "prometheus", code: "pro", path: "C:/Program Files (x86)/Overwatch", version: "2.19.0.0.143071", bytes: 52_000_000_000)
            + record(uid: "hs_beta", code: "hsb", path: "C:\\Program Files (x86)\\Hearthstone", bytes: 4_000_000_000)
            + record(uid: "fenris", code: "fenris", path: "C:/Program Files (x86)/Diablo IV", playable: false)
            + record(uid: "osi", code: "osi", path: "C:/Program Files (x86)/Diablo II Resurrected")   // folder deleted
        // The client's list, in the shape it writes: Hearthstone named, its launcher, art and last play.
        let aggregate = """
            {"installed": [
              {"product_id": "hsb", "name": "Hearthstone", "icon_index": 0,
               "icon_path": "C:/Program Files (x86)/Hearthstone/Hearthstone Beta Launcher.exe",
               "launch_uri": "battlenet://game/hsb", "last_played_timestamp": 1786266760000,
               "box_art_uri": "https://bnetxboxassets.akamaized.net/hsb/box-enUS.webp",
               "logo_art_uri": "https://bnetxboxassets.akamaized.net/hsb/logo-enUS.webp"},
              {"product_id": "fenris", "name": "Diablo IV", "icon_path": "C:/Program Files (x86)/Diablo IV/Diablo IV Launcher.exe"}
            ]}
            """
        try write(db, aggregate: aggregate, to: b)

        let games = BattleNetLibrary.games(in: b)
        XCTAssertEqual(games.map(\.productCode), ["hsb", "pro"], "installed and playable with a folder only, by title")
        let hsb = try XCTUnwrap(games.first { $0.productCode == "hsb" })
        XCTAssertEqual(hsb.title, "Hearthstone")
        XCTAssertEqual(hsb.uid, "hs_beta")
        XCTAssertEqual(hsb.folder.path, hs.path, "backslashes too")
        XCTAssertEqual(hsb.launcher?.lastPathComponent, "Hearthstone Beta Launcher.exe")
        XCTAssertEqual(hsb.lastPlayed, Date(timeIntervalSince1970: 1_786_266_760))
        XCTAssertEqual(hsb.boxArt?.absoluteString, "https://bnetxboxassets.akamaized.net/hsb/box-enUS.webp")
        XCTAssertEqual(hsb.sizeOnDisk, 4_000_000_000)
        let pro = try XCTUnwrap(games.first { $0.productCode == "pro" })
        XCTAssertEqual(pro.title, "Overwatch", "the folder's name when the client's list has none")
        XCTAssertEqual(pro.launcher?.path, ow.appending(path: "Overwatch Launcher.exe").path, "the one launcher in the folder")
        XCTAssertEqual(pro.version, "2.19.0.0.143071")
        XCTAssertNil(pro.lastPlayed)
        XCTAssertNil(pro.boxArt)
        XCTAssertEqual(pro.libraryID, "battlenet:pro")
    }

    func testEditionsSharingAFolderAreToldApart() throws {
        let b = try bottle()
        try folder("Program Files (x86)/World of Warcraft", in: b, files: ["World of Warcraft Launcher.exe"])
        try write(clientRecords
                  + record(uid: "wow", code: "wow", path: "C:/Program Files (x86)/World of Warcraft")
                  + record(uid: "wow_classic", code: "wow_classic", path: "C:/Program Files (x86)/World of Warcraft"), to: b)
        let games = BattleNetLibrary.games(in: b)
        XCTAssertEqual(Set(games.map(\.title)), ["World of Warcraft (wow)", "World of Warcraft (wow_classic)"])
        XCTAssertEqual(Set(games.compactMap { $0.launcher?.lastPathComponent }), ["World of Warcraft Launcher.exe"])
        XCTAssertEqual(Set(games.compactMap { BattleNetLibrary.launch($0, client: nil)?.arguments }), [["--productcode=wow"], ["--productcode=wow_classic"]],
                       "one launcher, the product code picks the edition, as Blizzard's own shortcuts do")
    }

    func testAnyOtherDriveLetterFollowsTheEnvironmentsLink() throws {
        let b = try bottle()
        let external = tmp.appending(path: "External", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: external.appending(path: "Games/Diablo IV"), withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: external.appending(path: "Games/Diablo IV/Diablo IV Launcher.exe"))
        try FileManager.default.createDirectory(at: b.url.appending(path: "dosdevices"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: b.url.appending(path: "dosdevices/d:"), withDestinationURL: external)
        try write(clientRecords + record(uid: "fenris", code: "fenris", path: "D:/Games/Diablo IV"), to: b)
        let game = try XCTUnwrap(BattleNetLibrary.games(in: b).first)
        XCTAssertEqual(game.folder.resolvingSymlinksInPath().path, external.appending(path: "Games/Diablo IV").resolvingSymlinksInPath().path)
        XCTAssertEqual(game.launcher?.lastPathComponent, "Diablo IV Launcher.exe")
        XCTAssertNil(BattleNetLibrary.macURL(forWindowsPath: "Games/Diablo IV", in: b), "no drive letter, no guess")
    }

    func testDamagedOrMissingRecordsAreNoGames() throws {
        let b = try bottle()
        XCTAssertEqual(BattleNetLibrary.games(in: b), [], "no product.db")
        try folder("Program Files (x86)/Overwatch", in: b)
        let whole = clientRecords + record(uid: "prometheus", code: "pro", path: "C:/Program Files (x86)/Overwatch")
        try write(Array(whole.dropLast(3)), to: b)
        XCTAssertThrowsError(try ProductDB.installs(in: Data(whole.dropLast(3))))
        XCTAssertEqual(BattleNetLibrary.games(in: b), [], "a file cut short reads as nothing, never as half a list")
        try write(whole, aggregate: "not json", to: b)
        XCTAssertEqual(BattleNetLibrary.games(in: b).map(\.title), ["Overwatch"], "an unreadable list only loses the extras")
    }

    func testProtobufSkipsEveryWireTypeItDoesNotNeed() throws {
        let bytes = PB.field(1, 150) + [0x11] + [UInt8](repeating: 1, count: 8) + PB.field(3, "x") + [0x25, 1, 0, 0, 0]
        let fields = try Protobuf.fields(in: bytes)
        XCTAssertEqual(fields.map { $0.0 }, [1, 2, 3, 4])
        XCTAssertEqual(fields[0].1, .varint(150))
        XCTAssertEqual(fields[1].1, .fixed64(0x0101_0101_0101_0101))
        XCTAssertEqual(fields[2].1, .bytes(Array("x".utf8)))
        XCTAssertEqual(fields[3].1, .fixed32(1))
        XCTAssertThrowsError(try Protobuf.fields(in: [0x0B]), "a group is not something the agent writes")
        XCTAssertThrowsError(try Protobuf.fields(in: [0x0A, 0x05, 0x61]), "a length past the end")
    }

    // MARK: Play

    func testPlayStartsTheGamesLauncherElseOpensBattleNet() throws {
        let b = try bottle()
        let client = try folder("Program Files (x86)/Battle.net", in: b, files: ["Battle.net Launcher.exe", "Battle.net.exe"])
        try folder("Program Files (x86)/Overwatch", in: b, files: ["Overwatch Launcher.exe"])
        try folder("Program Files (x86)/Some Game", in: b, files: ["Game.exe"])
        try write(clientRecords + record(uid: "prometheus", code: "pro", path: "C:/Program Files (x86)/Overwatch")
                  + record(uid: "zzz", code: "zzz", path: "C:/Program Files (x86)/Some Game"), to: b)
        let games = BattleNetLibrary.games(in: b)
        let bnet = BattleNetLibrary.client(in: b)
        XCTAssertEqual(bnet?.path, client.appending(path: "Battle.net Launcher.exe").path, "the client's own record, the launcher the recipe pins")
        let pro = try XCTUnwrap(BattleNetLibrary.launch(try XCTUnwrap(games.first { $0.productCode == "pro" }), client: bnet))
        XCTAssertEqual(pro.executable.lastPathComponent, "Overwatch Launcher.exe")
        XCTAssertEqual(pro.arguments, ["--productcode=pro"])
        XCTAssertFalse(pro.throughClient)
        let other = try XCTUnwrap(games.first { $0.productCode == "zzz" })
        XCTAssertNil(other.launcher)
        XCTAssertEqual(BattleNetLibrary.launch(other, client: bnet), .init(executable: bnet!, arguments: [], throughClient: true),
                       "without a launcher of its own, Battle.net opens and its Play starts the game")
        XCTAssertNil(BattleNetLibrary.launch(other, client: nil))
    }

    func testTheRunningGameIsItsFolderButNotItsLauncher() throws {
        let b = try bottle()
        try folder("Program Files (x86)/Overwatch", in: b, files: ["Overwatch Launcher.exe"])
        try write(clientRecords + record(uid: "prometheus", code: "pro", path: "C:/Program Files (x86)/Overwatch"), to: b)
        let game = try XCTUnwrap(BattleNetLibrary.games(in: b).first)
        let marks = BattleNetLibrary.sessionMarkers(for: game)
        XCTAssertEqual(marks.markers.first, "\\Program Files (x86)\\Overwatch\\")
        XCTAssertEqual(marks.excluding, ["Overwatch Launcher.exe"])
        let launcherOnly = """
            4242 ??  S  0:00.10 C:\\Program Files (x86)\\Overwatch\\Overwatch Launcher.exe --productcode=pro
            4243 ??  S  0:03.00 C:\\Program Files (x86)\\Battle.net\\Battle.net.exe
            """
        XCTAssertFalse(SessionWatch.isAlive(markers: marks.markers, excluding: marks.excluding, ps: launcherOnly))
        let playing = launcherOnly + "\n4250 ??  R  1:00.00 C:\\Program Files (x86)\\Overwatch\\_retail_\\Overwatch.exe -uid prometheus"
        XCTAssertTrue(SessionWatch.isAlive(markers: marks.markers, excluding: marks.excluding, ps: playing))
        let session = GameSession(title: game.title, bottleName: "Games", appid: nil, markers: marks.markers, excluding: marks.excluding)
        XCTAssertTrue(SessionWatch.isAlive(session, ps: playing))
        XCTAssertFalse(SessionWatch.isAlive(session, ps: launcherOnly))
        XCTAssertTrue(SessionWatch.isAlive(markers: ["x"], excluding: [], ps: "a x b"), "nothing to leave out is the plain check")
    }

    // MARK: The library

    func testOneTilePerGameHomedLikeSteams() {
        func bottle(_ name: String) -> Bottle {
            Bottle(url: URL(fileURLWithPath: "/tmp/hb-lib-tests/bottles/\(name)"), settings: BottleSettings(name: name, engineID: "e"))
        }
        func game(in name: String, played: Date? = nil) -> BattleNetGame {
            BattleNetGame(productCode: "pro", uid: "prometheus", title: "Overwatch", installPath: "C:/Program Files (x86)/Overwatch",
                          folder: URL(fileURLWithPath: "/tmp/hb-lib-tests/bottles/\(name)/drive_c/Program Files (x86)/Overwatch"),
                          launcher: nil, sizeOnDisk: 7, lastPlayed: played,
                          boxArt: URL(string: "https://bnetxboxassets.akamaized.net/pro/box-enUS.webp"))
        }
        let a = bottle("a"), games = bottle("Games")
        let both = ["a": [game(in: "a")], "Games": [game(in: "Games", played: Date(timeIntervalSince1970: 100))]]
        var items = LibraryIndex.build(bottles: [a, games], steamByBottle: [:], epicOwned: [], epicInstalls: [:],
                                       battleNetByBottle: both, defaultBottle: "Games")
        XCTAssertEqual(items.count, 1, "one tile per game, never per install")
        let item = items[0]
        XCTAssertEqual(item.id, "battlenet:pro")
        XCTAssertEqual(item.source, .battlenet)
        XCTAssertEqual(item.battleNetProduct, "pro")
        XCTAssertEqual(item.bottleName, "Games", "the default environment before name order")
        XCTAssertEqual(item.otherBottles, ["a"])
        XCTAssertTrue(item.installed)
        XCTAssertEqual(item.sizeOnDisk, 7)
        XCTAssertEqual(item.lastPlayed, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(item.artworkTall?.host, "bnetxboxassets.akamaized.net")
        XCTAssertEqual(item.homed(in: "a").battleNetProduct, "pro", "Play in another environment keeps the product")
        items = LibraryIndex.build(bottles: [a, games], steamByBottle: [:], epicOwned: [], epicInstalls: [:],
                                   battleNetByBottle: both, plays: ["battlenet:pro": .init(lastPlayedAt: Date(timeIntervalSince1970: 200), bottle: "a")],
                                   defaultBottle: "Games")
        XCTAssertEqual(items[0].bottleName, "a", "where it was last played comes first")
        XCTAssertEqual(items[0].lastPlayed, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(LibraryIndex.installedForHome(items).map(\.id), ["battlenet:pro"], "installed, so on the Home row")
        XCTAssertEqual(Uninstall.route(for: items[0]), .windowsUninstaller, "Battle.net's own uninstaller, through Add or Remove Programs")
    }
}
