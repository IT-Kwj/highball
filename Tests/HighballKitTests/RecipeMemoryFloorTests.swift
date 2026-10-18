import XCTest
@testable import HighballKit

/// A recipe's memory floor: data the asks read, absent from every recipe written before it.
final class RecipeMemoryFloorTests: XCTestCase {
    private func recipe(_ json: String) throws -> Recipe {
        try JSONDecoder().decode(Recipe.self, from: Data(json.utf8))
    }

    func testAFloorIsReadAndARecipeWithoutOneHasNone() throws {
        let with = try recipe(#"{"id":"g","kind":"game","title":"G","engine":"arm64-wine11.18-r3","minMemoryGB":32,"steps":[]}"#)
        XCTAssertEqual(with.minMemoryGB, 32)
        let without = try recipe(#"{"id":"g","kind":"game","title":"G","steps":[]}"#)
        XCTAssertNil(without.minMemoryGB)
    }

    func testOnlyAMacUnderTheFloorIsTold() throws {
        let r = try recipe(#"{"id":"g","kind":"game","title":"G","minMemoryGB":32,"steps":[]}"#)
        XCTAssertNil(r.memoryShortfall(memoryMB: 32_768))
        XCTAssertNil(r.memoryShortfall(memoryMB: 65_536))
        let short = try XCTUnwrap(r.memoryShortfall(memoryMB: 16_384))
        XCTAssertEqual(short.needGB, 32)
        XCTAssertEqual(short.haveGB, 16)
        XCTAssertNil(try recipe(#"{"id":"g","kind":"game","title":"G","steps":[]}"#).memoryShortfall(memoryMB: 8_192))
    }
}
