import XCTest
@testable import HighballKit

/// An engine unpacked onto an exFAT or other non-APFS drive gets a `._name` file beside each file,
/// and GStreamer tried to load the `._libgst*.dylib` ones as plugins (a player on Discord, 2026-10-11).
/// A game folder there gets them too, and Alice: Madness Returns failed on them (highball-db#429).
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

        XCTAssertEqual(AppleDouble.removeTwins(in: nested, recursive: false), 1)
        let left = try XCTUnwrap(AppleDouble.rawNames(in: nested)).sorted()
        XCTAssertEqual(left, ["._orphan.dylib", "libgstcoreelements.dylib"], "a ._ file with nothing beside it is not a sidecar")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "._wine").path), "not recursive, the parent is left")

        // A linked folder is someone else's: the walk does not follow it.
        let outside = FileManager.default.temporaryDirectory.appending(path: "hb-appledouble-out-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        for name in ["save", "._save"] { try Data().write(to: outside.appending(path: name)) }
        try FileManager.default.createSymbolicLink(at: root.appending(path: "linked"), withDestinationURL: outside)

        XCTAssertEqual(AppleDouble.removeTwins(in: root, recursive: true), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "._wine").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appending(path: "._save").path), "links are not followed")
    }

    /// A game folder on APFS keeps native extended attributes, so nothing there is a sidecar and the
    /// folder is not even walked: a `._` file a game ships stays.
    func testAGameFolderOnAPFSIsLeftAlone() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "hb-appledouble-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Game.upk", "._Game.upk"] { try Data().write(to: root.appending(path: name)) }
        try XCTSkipUnless((try? root.resourceValues(forKeys: [.volumeTypeNameKey]))?.volumeTypeName?.lowercased() == "apfs",
                          "the temporary folder is not on APFS")

        XCTAssertFalse(AppleDouble.volumeKeepsTwins(root))
        XCTAssertEqual(AppleDouble.cleanGameFolder(root), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "._Game.upk").path))
    }

    /// On exFAT a value written to a file lands in `._name` beside it, which is what a game read as
    /// its own; the cleanup takes those and leaves the game's files.
    func testAGameFolderOnExFATLosesItsSidecars() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "hb-exfat-\(UUID().uuidString)", directoryHint: .isDirectory)
        let image = work.appending(path: "volume.dmg"), mount = work.appending(path: "mnt", directoryHint: .isDirectory)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        guard Self.hdiutil(["create", "-quiet", "-size", "20m", "-fs", "ExFAT", "-volname", "HBTEST", image.path]),
              Self.hdiutil(["attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, image.path]) else {
            throw XCTSkip("no exFAT disk image could be made and attached here")
        }
        defer { _ = Self.hdiutil(["detach", "-quiet", "-force", mount.path]) }

        let cooked = mount.appending(path: "CookedPC", directoryHint: .isDirectory)
        try fm.createDirectory(at: cooked, withIntermediateDirectories: true)
        let package = cooked.appending(path: "Startup.upk")
        try Data("package".utf8).write(to: package)
        XCTAssertEqual(setxattr(package.path, "com.example.highball", "1", 1, 0, 0), 0)
        XCTAssertTrue(try XCTUnwrap(AppleDouble.rawNames(in: cooked)).contains("._Startup.upk"), "exFAT keeps the value in a ._ file")

        XCTAssertTrue(AppleDouble.volumeKeepsTwins(mount))
        XCTAssertGreaterThanOrEqual(AppleDouble.cleanGameFolder(mount), 1)
        XCTAssertFalse(try XCTUnwrap(AppleDouble.rawNames(in: cooked)).contains("._Startup.upk"))
        XCTAssertEqual(try Data(contentsOf: package), Data("package".utf8), "the game's own file stays as it was")
    }

    private static func hdiutil(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
