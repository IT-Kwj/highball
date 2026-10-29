import XCTest
@testable import HighballKit

/// Games kept out of the library (highball#445): hidden ids and the Steam for Mac switch live in
/// library.json beside the other per-game choices, older files decode as before, and the library
/// shows a hidden game again only under the Hidden filter.
final class LibraryHiddenTests: XCTestCase {
    private var home: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "hb-hidden-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        store = LibraryStore(paths: HighballPaths(home: home))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func item(_ id: String, _ title: String) -> HighballKit.LibraryItem {
        HighballKit.LibraryItem(source: id.hasPrefix("pin:") ? .pin : .steam, id: id, title: title, bottleName: "Games", installed: true)
    }

    func testNothingIsHiddenAndMacSteamIsInWithoutAFile() {
        XCTAssertEqual(store.hiddenIDs(), [])
        XCTAssertTrue(store.includesMacSteam)
    }

    func testAFileFromBeforeTheFieldsDecodesWithItsHistory() throws {
        let old = #"{"formatVersion":1,"items":{"steam:620":{"lastPlayedAt":"2026-10-01T10:00:00Z","bottle":"Games"}},"launchArgs":{"steam:620":["-novid"]}}"#
        try Data(old.utf8).write(to: home.appending(path: "library.json"))
        XCTAssertEqual(store.hiddenIDs(), [])
        XCTAssertTrue(store.includesMacSteam)
        XCTAssertEqual(store.load()["steam:620"]?.bottle, "Games")
        // Writing the new fields keeps what was there.
        store.setHidden(true, for: "steam:620")
        store.setIncludesMacSteam(false)
        XCTAssertEqual(store.load()["steam:620"]?.bottle, "Games")
        XCTAssertEqual(store.launchArguments()["steam:620"], ["-novid"])
    }

    func testHidingAndShowingAGameIsKeptAcrossStores() {
        store.setHidden(true, for: "steam:620")
        store.setHidden(true, for: "epic:Duck")
        XCTAssertEqual(LibraryStore(paths: HighballPaths(home: home)).hiddenIDs(), ["steam:620", "epic:Duck"])
        store.setHidden(false, for: "steam:620")
        XCTAssertEqual(store.hiddenIDs(), ["epic:Duck"])
        store.setHidden(false, for: "epic:Duck")
        XCTAssertEqual(store.hiddenIDs(), [])
        let text = (try? String(contentsOf: home.appending(path: "library.json"), encoding: .utf8)) ?? ""
        XCTAssertFalse(text.contains("hidden"), "an empty list leaves the file as an older app wrote it")
    }

    /// A program's id carries its environment's name: hidden before a rename, it stays hidden
    /// after, and showing it again clears the mark kept under the old name.
    func testAProgramStaysHiddenAcrossAnEnvironmentRename() {
        let uuid = "B43215E4-3490-4E8A-835B-3668A02B279F"
        store.setHidden(true, for: "pin:Games:\(uuid)")
        XCTAssertTrue(LibraryStore.isHidden("pin:Play:\(uuid)", in: store.hiddenIDs()))
        XCTAssertFalse(LibraryStore.isHidden("pin:Play:00000000-0000-0000-0000-000000000001", in: store.hiddenIDs()))
        store.setHidden(false, for: "pin:Play:\(uuid)")
        XCTAssertEqual(store.hiddenIDs(), [])
    }

    func testTheSteamForMacSwitchRoundTrips() {
        store.setIncludesMacSteam(false)
        XCTAssertFalse(LibraryStore(paths: HighballPaths(home: home)).includesMacSteam)
        store.setIncludesMacSteam(true)
        XCTAssertTrue(store.includesMacSteam)
        let text = (try? String(contentsOf: home.appending(path: "library.json"), encoding: .utf8)) ?? ""
        XCTAssertFalse(text.contains("macSteamExcluded"), "back on is the default, not a stored value")
    }

    func testPruneDropsHiddenMarksOfGamesThatAreGone() {
        store.setHidden(true, for: "steam:620")
        store.setHidden(true, for: "steam:730")
        store.prune(validIDs: ["steam:730"])
        XCTAssertEqual(store.hiddenIDs(), ["steam:730"])
    }

    func testTheLibraryLeavesHiddenGamesOutAndTheFilterShowsThemAlone() {
        let items = [item("steam:620", "Portal 2"), item("steam:730", "Counter-Strike 2"), item("epic:Duck", "Cardpocalypse")]
        XCTAssertEqual(LibraryIndex.visible(items, hidden: [], showingHidden: false).map(\.id), items.map(\.id))
        XCTAssertEqual(LibraryIndex.visible(items, hidden: ["steam:730"], showingHidden: false).map(\.id), ["steam:620", "epic:Duck"])
        XCTAssertEqual(LibraryIndex.visible(items, hidden: ["steam:730"], showingHidden: true).map(\.id), ["steam:730"])
        XCTAssertEqual(LibraryIndex.visible(items, hidden: [], showingHidden: true).map(\.id), [], "the filter with nothing hidden lists nothing")
        // The Home row reads the same list, so a hidden installed game leaves it too.
        XCTAssertFalse(LibraryIndex.installedForHome(LibraryIndex.visible(items, hidden: ["steam:620"], showingHidden: false)).contains { $0.id == "steam:620" })
    }

    /// Leaving Steam for Mac out is the index built without its installs: a game only it holds has
    /// no tile, and one an environment also holds is no longer installed on the Mac, so Play takes
    /// the Windows copy.
    func testLeavingSteamForMacOutDropsItsGames() {
        let bottle = Bottle(url: URL(fileURLWithPath: "/tmp/hb-hidden-tests/bottles/Games"), settings: BottleSettings(name: "Games", engineID: "e"))
        let shared = SteamGame(appid: 620, name: "Portal 2", installdir: "Portal 2", sizeOnDisk: 1, stateFlags: 4, lastPlayed: nil)
        let macOnly = SteamGame(appid: 400, name: "Portal", installdir: "Portal", sizeOnDisk: 1, stateFlags: 4, lastPlayed: nil)
        let with = LibraryIndex.build(bottles: [bottle], steamByBottle: ["Games": [shared]], macInstalled: [shared, macOnly],
                                      epicOwned: [], epicInstalls: [:])
        XCTAssertEqual(with.map(\.id).sorted(), ["steam:400", "steam:620"])
        XCTAssertTrue(with.first { $0.id == "steam:620" }!.installedOnMac)
        let without = LibraryIndex.build(bottles: [bottle], steamByBottle: ["Games": [shared]], macInstalled: [],
                                         epicOwned: [], epicInstalls: [:])
        XCTAssertEqual(without.map(\.id), ["steam:620"])
        XCTAssertFalse(without[0].installedOnMac)
        XCTAssertTrue(without[0].installed)
    }
}
