import XCTest
@testable import HighballKit

/// A user hive with a `Software\Wow6432Node` key sends Wine's 32-bit lookups of HKCU\Software
/// into that subtree, so the Rockstar launcher could not see Steam (error 113, a player's Red
/// Dead Redemption 2 environment moved off the Wine 10 engine, 2026-10-13).
final class SteamRegistryViewTests: XCTestCase {
    private let header = "WINE REGISTRY Version 2\n;; All keys relative to \\\\User\\\\S-1-5-21-0-0-0-1000\n\n#arch=win64\n"
    private let steam = "\n[Software\\\\Valve\\\\Steam] 1790000000\n#time=1dd0000000000000\n\"ActiveProcess\"=dword:00000020\n"
    private let subtree = "\n[Software\\\\Wow6432Node\\\\Microsoft\\\\Internet Explorer\\\\Main] 1790700450\n\"Start Page\"=\"https://www.winehq.org\"\n"

    func testTheLinkGoesInOnlyWhenTheSubtreeAndSteamAreThere() throws {
        XCTAssertNil(SteamRegistryView.linkBlock(for: header + steam), "no subtree, nothing is redirected")
        XCTAssertNil(SteamRegistryView.linkBlock(for: header + subtree), "no Steam, nothing to link")
        let block = try XCTUnwrap(SteamRegistryView.linkBlock(for: header + steam + subtree, now: Date(timeIntervalSince1970: 1_791_741_900)))
        XCTAssertTrue(block.contains("\n[Software\\\\Wow6432Node\\\\Valve] 1791741900\n#link\n\"SymbolicLinkValue\"=hex(6):"))
        XCTAssertNil(SteamRegistryView.linkBlock(for: header + steam + subtree + block), "a second run leaves it")
        XCTAssertNotNil(SteamRegistryView.linkBlock(for: header + steam + "\n[Software\\\\Wow6432Node] 1790700450\n"),
                        "the bare key redirects too")
    }

    func testTheLinkNamesSteamsKeyInUTF16() throws {
        let block = try XCTUnwrap(SteamRegistryView.linkBlock(for: header + steam + subtree))
        let hex = try XCTUnwrap(block.components(separatedBy: "hex(6):").last?.trimmingCharacters(in: .whitespacesAndNewlines))
        let bytes = hex.split(separator: ",").compactMap { UInt8($0, radix: 16) }
        let units = stride(from: 0, to: bytes.count, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
        XCTAssertEqual(String(decoding: units, as: UTF16.self), #"\REGISTRY\User\S-1-5-21-0-0-0-1000\Software\Valve"#)
    }

    func testRepairAppendsToAStoppedEnvironmentOnce() throws {
        let prefix = FileManager.default.temporaryDirectory.appending(path: "hb-steamview-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: prefix) }
        let hive = prefix.appending(path: "user.reg")
        let original = header + steam + subtree
        try original.write(to: hive, atomically: true, encoding: .utf8)

        XCTAssertTrue(try SteamRegistryView.repair(prefix: prefix))
        let after = try String(contentsOf: hive, encoding: .utf8)
        XCTAssertTrue(after.hasPrefix(original), "what was there is kept as it was")
        XCTAssertTrue(after.contains("[Software\\\\Wow6432Node\\\\Valve]"))
        XCTAssertFalse(try SteamRegistryView.repair(prefix: prefix), "already linked")
        XCTAssertEqual(try String(contentsOf: hive, encoding: .utf8), after)
    }
}
