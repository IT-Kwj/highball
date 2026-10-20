import XCTest
@testable import HighballKit

/// A recipe's later dependencies and the steps that only take effect when Wine's drivers start (highball#397).
final class RecipeRequirementsTests: XCTestCase {
    private func recipe(_ json: String) throws -> Recipe {
        try JSONDecoder.highball.decode(Recipe.self, from: Data(json.utf8))
    }

    func testMissingRequiredTweaksSkipsAppliedOnesAndLaunchers() throws {
        let game = try recipe("""
        {"id": "msfs", "kind": "game", "title": "Flight", "requires": ["steam", "flight-controls-raw-hid", "dotnet48", "gone"],
         "steps": [{"type": "note", "text": "x"}]}
        """)
        let tweaks = [
            "flight-controls-raw-hid": try recipe("""
            {"id": "flight-controls-raw-hid", "kind": "tweak", "title": "Flight controls", "steps": [{"type": "note", "text": "x"}]}
            """),
            "dotnet48": try recipe("""
            {"id": "dotnet48", "kind": "tweak", "title": ".NET", "steps": [{"type": "note", "text": "x"}]}
            """),
            "steam": try recipe("""
            {"id": "steam", "kind": "launcher", "title": "Steam", "steps": [{"type": "note", "text": "x"}]}
            """),
        ]
        let missing = game.missingRequiredTweaks(applied: ["msfs", "dotnet48"], resolve: { tweaks[$0] })
        XCTAssertEqual(missing.map(\.id), ["flight-controls-raw-hid"],
                       "an applied tweak, a launcher and an id this build doesn't ship are not applied again")
        XCTAssertEqual(game.missingRequiredTweaks(applied: ["flight-controls-raw-hid", "dotnet48"], resolve: { tweaks[$0] }).count, 0)
    }

    func testDriverSettingsAreRegistryValuesUnderServices() throws {
        let raw = try recipe("""
        {"id": "flight-controls-raw-hid", "kind": "tweak", "title": "Flight controls", "steps": [
          {"type": "registry", "key": "HKLM\\\\System\\\\CurrentControlSet\\\\Services\\\\winebus\\\\Devices\\\\294b", "name": "Hidraw", "valueType": "REG_DWORD", "data": "1"}]}
        """)
        XCTAssertTrue(raw.changesDriverSettings)
        XCTAssertFalse(raw.changesLaunchEnvironment, "a registry value is no launch variable")
        XCTAssertTrue(Recipe.isServiceKey(#"HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\winebus"#))
        XCTAssertTrue(Recipe.isServiceKey("hklm/system/currentcontrolset/services/winebus"))
        XCTAssertFalse(Recipe.isServiceKey(#"HKCU\Software\Wine\WineBus"#), "Wine never reads winebus options there")
        XCTAssertFalse(Recipe.isServiceKey(#"HKLM\System\CurrentControlSet\Control\Session Manager"#))
        let dll = try recipe("""
        {"id": "x", "kind": "tweak", "title": "X", "steps": [
          {"type": "registry", "key": "HKCU\\\\Software\\\\Wine\\\\DllOverrides", "name": "xaudio2_7", "valueType": "REG_SZ", "data": "native"}]}
        """)
        XCTAssertFalse(dll.changesDriverSettings)
    }
}
