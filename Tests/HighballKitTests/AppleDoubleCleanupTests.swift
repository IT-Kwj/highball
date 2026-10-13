import XCTest
@testable import HighballKit

/// An engine unpacked onto an exFAT or other non-APFS drive gets a `._name` file beside each file,
/// and GStreamer tried to load the `._libgst*.dylib` ones as plugins (a player on Discord, 2026-10-11).
final class AppleDoubleCleanupTests: XCTestCase {
    func testOnlyTheSidecarsOfFilesThatExistGo() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "hb-appledouble-\(UUID().uuidString)", directoryHint: .isDirectory)
        let nested = root.appending(path: "lib/gstreamer-1.0", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["libgstcoreelements.dylib", "._libgstcoreelements.dylib", "._orphan.dylib"] {
            try Data().write(to: nested.appending(path: name))
        }
        for name in ["wine", "._wine"] { try Data().write(to: root.appending(path: name)) }

        XCTAssertEqual(EngineStore.removeAppleDoubleFiles(in: nested, recursive: false), 1)
        let left = try XCTUnwrap(EngineStore.rawNames(in: nested)).sorted()
        XCTAssertEqual(left, ["._orphan.dylib", "libgstcoreelements.dylib"], "a ._ file with nothing beside it is not a sidecar")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "._wine").path), "not recursive, the parent is left")

        XCTAssertEqual(EngineStore.removeAppleDoubleFiles(in: root, recursive: true), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "._wine").path))
    }
}
