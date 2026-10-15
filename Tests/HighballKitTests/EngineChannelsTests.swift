import XCTest
@testable import HighballKit

/// The gate in front of engine lines that ship hidden. A wrong answer here would either hand a
/// preview engine to every player or hide it from the people testing it.
final class EngineChannelsTests: XCTestCase {
    private var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func manifest(id: String, channel: String?) throws -> EngineManifest {
        var json: [String: Any] = ["id": id, "displayName": id, "arch": "arm64", "minMacOS": "26.5", "components": [String: Any]()]
        if let channel { json["channel"] = channel }
        return try JSONDecoder().decode(EngineManifest.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testNoChannelIsForEveryone() {
        XCTAssertTrue(EngineChannels.visible(channel: nil, beta: false, preview: false))
    }

    func testBetaNeedsBetaBuildsOrThePreviewKey() {
        XCTAssertFalse(EngineChannels.visible(channel: "beta", beta: false, preview: false))
        XCTAssertTrue(EngineChannels.visible(channel: "beta", beta: true, preview: false))
        XCTAssertTrue(EngineChannels.visible(channel: "beta", beta: false, preview: true))
    }

    func testPreviewNeedsThePreviewKeyEvenWithBetaBuilds() {
        XCTAssertFalse(EngineChannels.visible(channel: "preview", beta: true, preview: false))
        XCTAssertTrue(EngineChannels.visible(channel: "preview", beta: false, preview: true))
    }

    func testAnUnknownChannelStaysHidden() {
        XCTAssertFalse(EngineChannels.visible(channel: "previw", beta: true, preview: false))
        XCTAssertTrue(EngineChannels.visible(channel: "previw", beta: false, preview: true))
    }

    func testARecipePinnedToAHiddenEngineIsHiddenAndOthersAreNot() throws {
        let bundled = [try manifest(id: "arm64-line-r1", channel: "preview"), try manifest(id: "x64-line-r9", channel: nil)]
        XCTAssertTrue(EngineChannels.hidesPin("arm64-line-r1", bundled: bundled, beta: true, preview: false))
        XCTAssertFalse(EngineChannels.hidesPin("arm64-line-r1", bundled: bundled, beta: false, preview: true))
        XCTAssertFalse(EngineChannels.hidesPin("x64-line-r9", bundled: bundled, beta: false, preview: false))
        XCTAssertFalse(EngineChannels.hidesPin(nil, bundled: bundled, beta: false, preview: false))
        // A pin no bundled manifest carries keeps its own answer (Play asks for a Highball update).
        XCTAssertFalse(EngineChannels.hidesPin("x64-line-r10", bundled: bundled, beta: false, preview: false))
    }

    func testEveryEngineThePlayersHaveTodayHasNoChannel() throws {
        let dir = repo.appending(path: "spike/engines")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" } + [repo.appending(path: "spike/engine-manifest.json")]
        for file in files {
            let m = try EngineManifest.load(from: file)
            if m.isNativeARM64 { continue }
            XCTAssertNil(m.channel, "\(m.id) is an Intel engine players already have; a channel would hide it from them")
        }
    }
}
