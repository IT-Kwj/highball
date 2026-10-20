import XCTest
@testable import HighballKit

/// The checks a launch makes before the program starts, and the tweak removal next to them.
final class LaunchChecksTests: XCTestCase {

    /// highball#396: Steam warned it would stop running on Windows 7 in an environment whose setting
    /// said Windows 11. The prefix's own version is what Wine reports, read from its registry files.
    func testPrefixWindowsVersionComesFromTheRegistryFiles() {
        func system(_ build: String) -> String {
            "WINE REGISTRY Version 2\n\n[Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion] 1788462370\n\"CurrentBuild\"=\"\(build)\"\n\"CurrentVersion\"=\"6.3\"\n"
        }
        XCTAssertEqual(WineRunner.prefixWindowsVersion(userReg: "", systemReg: system("7601")), "win7", "what winetricks win7 leaves")
        XCTAssertEqual(WineRunner.prefixWindowsVersion(userReg: "", systemReg: system("19045")), "win10")
        XCTAssertEqual(WineRunner.prefixWindowsVersion(userReg: "", systemReg: system("22000")), "win11")
        XCTAssertEqual(WineRunner.prefixWindowsVersion(userReg: "", systemReg: system("9600")), "win81")
        XCTAssertNil(WineRunner.prefixWindowsVersion(userReg: "", systemReg: ""), "nothing to read, nothing to change")
        // The per-user value wins in Wine, so it wins here.
        let user = "WINE REGISTRY Version 2\n\n[Software\\\\Wine] 1788462370\n\"Version\"=\"win7\"\n\n[Software\\\\Wine\\\\Direct3D] 1788462370\n\"Version\"=\"win11\"\n"
        XCTAssertEqual(WineRunner.prefixWindowsVersion(userReg: user, systemReg: system("22000")), "win7")
        XCTAssertEqual(WineRunner.prefixWindowsVersion(userReg: "[Software\\\\Wine\\\\Direct3D] 1\n\"Version\"=\"win7\"\n", systemReg: system("22000")), "win11",
                       "a value of the same name under another key is not the version")
    }

    /// highball#371: the log could not show whether DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN was set.
    func testTheHeaderShowsRendererAndControllerSwitchesOnly() {
        let env = ["DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN": "1", "SDL_JOYSTICK_MFI": "0", "HOME": "/Users/someone",
                   "STEAM_TOKEN": "secret", "MVK_CONFIG_USE_MTLHEAP": "0", "WINE_NO_DELAYED_FORK": "1",
                   "D3DM_LONG": String(repeating: "x", count: 300)]
        XCTAssertEqual(WineRunner.headerSwitchLines(env),
                       "# DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN=1\n# MVK_CONFIG_USE_MTLHEAP=0\n# SDL_JOYSTICK_MFI=0\n# WINE_NO_DELAYED_FORK=1\n")
    }

    /// A DualSense player had "Controllers through SDL" installed and no way back but regedit.
    func testRegistryOnlyTweaksCanBeRemoved() throws {
        let sdl = try JSONDecoder.highball.decode(Recipe.self, from: Data("""
        {"id": "controller-sdl", "kind": "tweak", "title": "Controllers through SDL", "steps": [
          {"type": "registry", "key": "HKLM\\\\System\\\\CurrentControlSet\\\\Services\\\\winebus", "name": "DisableHidraw", "valueType": "REG_DWORD", "data": "1"},
          {"type": "registry", "key": "HKLM\\\\System\\\\CurrentControlSet\\\\Services\\\\winebus", "name": "Enable SDL", "valueType": "REG_DWORD", "data": "1"},
          {"type": "note", "text": "Restart the environment."}]}
        """.utf8))
        XCTAssertTrue(sdl.isRemovable)
        XCTAssertEqual(sdl.registryValues.map(\.name), ["DisableHidraw", "Enable SDL"])
        let runtime = try JSONDecoder.highball.decode(Recipe.self, from: Data("""
        {"id": "xact", "kind": "tweak", "title": "XACT", "steps": [{"type": "winetricks", "verbs": ["xact"]},
          {"type": "registry", "key": "HKCU\\\\Software\\\\Wine\\\\DllOverrides", "name": "xaudio2_7", "valueType": "REG_SZ", "data": "native"}]}
        """.utf8))
        XCTAssertFalse(runtime.isRemovable, "a runtime that installed files can't be taken off by deleting values")
        let notesOnly = try JSONDecoder.highball.decode(Recipe.self, from: Data("""
        {"id": "n", "kind": "tweak", "title": "N", "steps": [{"type": "note", "text": "x"}]}
        """.utf8))
        XCTAssertFalse(notesOnly.isRemovable, "nothing to remove")
    }
}
