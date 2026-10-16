import XCTest

@testable import HighballKit

final class MonitorPlacementTests: XCTestCase {
    private let lg = CGRect(x: -522, y: 982, width: 2560, height: 1440)
    private let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testSmallWindowIsCentredOnTarget() {
        let f = MonitorPlacement.frame(for: CGSize(width: 800, height: 600), on: lg)
        XCTAssertEqual(f, CGRect(x: 358, y: 1402, width: 800, height: 600))
    }

    func testOversizedWindowShrinksToTarget() {
        let f = MonitorPlacement.frame(for: CGSize(width: 3000, height: 2000), on: lg)
        XCTAssertEqual(f, lg)
    }

    func testIsOnUsesWindowCentre() {
        let onBuiltIn = MonitorPlacement.frame(for: CGSize(width: 800, height: 600), on: builtIn)
        XCTAssertFalse(MonitorPlacement.isOn(onBuiltIn, target: lg))
        XCTAssertTrue(
            MonitorPlacement.isOn(
                MonitorPlacement.frame(for: CGSize(width: 800, height: 600), on: lg), target: lg))
    }

    func testDisplayChoiceRoundTripsAndPruneKeepsOtherMaps() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = LibraryStore(paths: HighballPaths(home: tmp))
        store.setDisplay("U", for: "steam:1")
        XCTAssertEqual(store.displayChoices(), ["steam:1": "U"])
        store.setDisplay(nil, for: "steam:1")
        XCTAssertEqual(store.displayChoices(), [:])

        store.setDisplay("U", for: "steam:1")
        store.setDisplay("V", for: "steam:2")
        store.setLaunchArguments(["-w"], for: "steam:1")
        store.prune(validIDs: ["steam:1"])
        XCTAssertEqual(store.displayChoices(), ["steam:1": "U"])
        XCTAssertEqual(store.launchArguments(), ["steam:1": ["-w"]])
        store.prune(validIDs: [])
        XCTAssertEqual(store.displayChoices(), [:])
    }
}
