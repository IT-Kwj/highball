import XCTest
@testable import HighballKit

/// The arm64 engine line (private/notes/rosetta-transition-plan.md, for macOS 28's end of Rosetta):
/// the app derives every architecture-specific path from the manifest, needs Rosetta only for the
/// engines that say so, and runs an arm64 engine through the signed loader helper in Highball.app,
/// never through the engine's own loader. Nothing here runs Wine; the layouts are what the M4 spike
/// of 2026-10-04 measured working.
final class EngineArchTests: XCTestCase {
    private func manifest(_ arch: String, requires: [String]? = nil) -> EngineManifest {
        var m = EngineManifest(id: "\(arch == "arm64" ? "arm64" : "x64")-test-r1", displayName: "test", arch: arch, minMacOS: "26.5", components: [:])
        m.requires = requires
        return m
    }

    private func tempRoot(_ name: String) -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: Environments stay on one architecture

    /// No prefix has been moved between the Intel engines and the arm64 line, so the picker and
    /// the failure advice never offer it; a recipe's engine ask offers a new environment instead.
    func testEnvironmentsMoveOnlyWithinOneArchitecture() {
        let intel = manifest("x86_64"), arm = manifest("arm64")
        var intel2 = intel; intel2.id = "x64-test-r2"
        let root = tempRoot("hb-arch-move")
        let installed = [InstalledEngine(manifest: intel, root: root.appending(path: intel.id)),
                         InstalledEngine(manifest: arm, root: root.appending(path: arm.id))]
        XCTAssertEqual(EngineStore.offeredEngines(installed: installed, known: [intel2], current: intel.id, macOS: "27.0").map(\.id),
                       ["x64-test-r1", "x64-test-r2"])
        XCTAssertEqual(EngineStore.offeredEngines(installed: installed, known: [intel2], current: arm.id, macOS: "27.0").map(\.id),
                       ["arm64-test-r1"])
        XCTAssertEqual(Set(EngineStore.offeredEngines(installed: installed, known: [intel2], current: "gone-r1", macOS: "27.0").map(\.id)),
                       ["x64-test-r1", "arm64-test-r1", "x64-test-r2", "gone-r1"], "an environment whose engine is gone keeps every choice")
        XCTAssertNil(EngineStore.alternateEngine(for: arm.id, installed: installed, defaultID: intel.id), "an Intel default is no advice for an arm64 environment")
        XCTAssertNil(EngineStore.alternateEngine(for: intel.id, installed: installed, defaultID: nil))
        XCTAssertTrue(EngineStore.sameArch(current: nil, target: "arm64"))
        XCTAssertFalse(EngineStore.sameArch(current: "x86_64", target: "arm64"))
        XCTAssertFalse(EngineStore.sameArch(current: "arm64", target: "x86_64"))
    }

    func testTheDownloadSizeCountsEachArchiveOnce() {
        var m = manifest("arm64")
        let renderers = URL(string: "https://example.com/renderers-arm64.tar.xz")!
        m.components["vkd3d"] = EngineManifest.Component(kind: "renderer", url: renderers, sha256: "a", size: 100)
        m.components["dxvk"] = EngineManifest.Component(kind: "renderer", url: renderers, sha256: "a", size: 100)
        m.components["wine"] = EngineManifest.Component(kind: "wine", url: URL(string: "https://example.com/wine.tar.xz")!, sha256: "b", size: 50)
        XCTAssertEqual(m.downloadBytes, 150, "two folders of one archive are one download")
    }

    func testDirectoriesFollowTheArchitecture() {
        let intel = manifest("x86_64"), arm = manifest("arm64")
        XCTAssertEqual(intel.pe64LibDir, "x86_64-windows")
        XCTAssertEqual(intel.unixLibDir, "x86_64-unix")
        XCTAssertEqual(arm.pe64LibDir, "aarch64-windows", "Wine's ARM64X builtins, with the ARM64EC code x86-64 programs call into")
        XCTAssertEqual(arm.unixLibDir, "aarch64-unix")
        XCTAssertEqual(EngineManifest.pe32LibDir, "i386-windows", "32-bit programs run through WoW64 on both lines")
        XCTAssertFalse(intel.isNativeARM64); XCTAssertTrue(arm.isNativeARM64)
        XCTAssertEqual(EngineIntegrity.libraryDirectories(engineRoot: URL(fileURLWithPath: "/e"), arch: "arm64").map(\.lastPathComponent),
                       ["aarch64-windows", "i386-windows"])
        XCTAssertEqual(EngineIntegrity.libraryDirectories(engineRoot: URL(fileURLWithPath: "/e")).map(\.lastPathComponent),
                       ["x86_64-windows", "i386-windows"], "the default stays the Intel layout every shipped engine has")
    }

    func testOnlyEnginesThatSaySoNeedRosetta() throws {
        XCTAssertTrue(manifest("x86_64", requires: ["rosetta2"]).requiresRosetta)
        XCTAssertFalse(manifest("arm64", requires: []).requiresRosetta)
        XCTAssertFalse(manifest("arm64").requiresRosetta, "no requires at all means nothing is required")
        // Every engine shipped today is Intel code and must keep saying so, or the app would stop
        // installing Rosetta for it.
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "spike")
        var files = try FileManager.default.contentsOfDirectory(at: dir.appending(path: "engines"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        files.append(dir.appending(path: "engine-manifest.json"))
        for f in files {
            let m = try EngineManifest.load(from: f)
            XCTAssertEqual(m.arch, "x86_64", "\(m.id) is not an Intel engine")
            XCTAssertTrue(m.requiresRosetta, "\(m.id) no longer declares rosetta2")
        }
    }

    func testAnARM64EngineNeedsFEXAndTheSignedLoader() throws {
        let arm = manifest("arm64")
        let files = InstalledEngine.requiredFiles(for: arm)
        XCTAssertTrue(files.contains("engine/lib/wine/aarch64-windows/kernel32.dll"))
        XCTAssertTrue(files.contains("engine/lib/wine/aarch64-unix/ntdll.so"))
        XCTAssertTrue(files.contains("engine/lib/wine/i386-windows/kernel32.dll"))
        XCTAssertFalse(files.contains { $0.contains("x86_64") }, "nothing Intel is expected of an arm64 engine")
        for fex in ["engine/lib/wine/aarch64-windows/xtajit64.dll", "engine/lib/wine/aarch64-windows/xtajit.dll",
                    "engine/lib/wine/aarch64-unix/libarm64ecfex.so", "engine/lib/wine/aarch64-unix/libwow64fex.so"] {
            XCTAssertTrue(files.contains(fex), "\(fex) is what makes x86 programs run at all")
        }
        XCTAssertEqual(InstalledEngine.requiredFiles, InstalledEngine.requiredFiles(for: manifest("x86_64")), "the Intel list is unchanged")

        // A tree with every file, but the loader is the engine's own: not complete.
        let root = tempRoot("arm64-engine")
        for f in files { try touch(root.appending(path: f)) }
        let engine = InstalledEngine(manifest: arm, root: root)
        XCTAssertEqual(engine.missingFiles, [InstalledEngine.signedLoaderName])
        XCTAssertFalse(engine.usesSignedLoader)

        // Linking the signed helper completes it, sets the engine's loader aside once, and makes
        // bin/wine the relative link Wine itself installs, so a start through either path reaches
        // the helper and finds ntdll.so beside the Unix-side link.
        let app = tempRoot("Highball.app").appendingPathExtension("app")
        let helper = WineLoaderHelper.binary(inAppBundle: app)
        try touch(helper)
        try EngineStore().linkSignedLoader(root, manifest: arm, helper: helper)
        let unixLink = root.appending(path: "engine/lib/wine/aarch64-unix/wine")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: unixLink.path), helper.path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root.appending(path: "engine/bin/wine").path), "../lib/wine/aarch64-unix/wine")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "engine/bin/wine.unsigned").path), "the engine's own loader is kept aside")
        XCTAssertTrue(engine.usesSignedLoader)
        XCTAssertEqual(engine.missingFiles, [])
        XCTAssertEqual(engine.wineBinary.resolvingSymlinksInPath().path, helper.resolvingSymlinksInPath().path, "a launch runs the helper")

        // The app moved: the next read repoints the link and nothing else changes.
        let moved = tempRoot("Moved.app").appendingPathExtension("app")
        let helper2 = WineLoaderHelper.binary(inAppBundle: moved)
        try touch(helper2)
        try EngineStore().linkSignedLoader(root, manifest: arm, helper: helper2)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: unixLink.path), helper2.path)
        XCTAssertEqual(engine.missingFiles, [])

        // An Intel engine is never touched.
        let intelRoot = tempRoot("x64-engine")
        try touch(intelRoot.appending(path: "engine/bin/wine"))
        try EngineStore().linkSignedLoader(intelRoot, manifest: manifest("x86_64", requires: ["rosetta2"]), helper: helper)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: intelRoot.appending(path: "engine/bin/wine").path))
    }

    func testTheHelperIsFoundInTheEnvironmentThenTheAppThenApplications() throws {
        let app = tempRoot("App").appendingPathExtension("app"), installed = tempRoot("Installed").appendingPathExtension("app")
        let nowhere = URL(fileURLWithPath: "/nonexistent/Highball.app")
        XCTAssertNil(WineLoaderHelper.locate(environment: [:], appBundle: app, applications: nowhere), "nothing on disk yet")
        try touch(WineLoaderHelper.binary(inAppBundle: installed))
        XCTAssertEqual(WineLoaderHelper.locate(environment: [:], appBundle: app, applications: installed), WineLoaderHelper.binary(inAppBundle: installed))
        try touch(WineLoaderHelper.binary(inAppBundle: app))
        XCTAssertEqual(WineLoaderHelper.locate(environment: [:], appBundle: app, applications: installed), WineLoaderHelper.binary(inAppBundle: app),
                       "the running app's own helper wins over the one in Applications")
        let override = tempRoot("Override").appendingPathExtension("app")
        try touch(WineLoaderHelper.binary(inAppBundle: override))
        let bundlePath = override.appending(path: "Contents/Helpers/WineLoader.app").path
        XCTAssertEqual(WineLoaderHelper.locate(environment: [WineLoaderHelper.environmentKey: bundlePath], appBundle: app, applications: installed),
                       WineLoaderHelper.binary(inAppBundle: override), "the environment names the bundle")
        XCTAssertEqual(WineLoaderHelper.locate(environment: [WineLoaderHelper.environmentKey: WineLoaderHelper.binary(inAppBundle: override).path], appBundle: app, applications: installed),
                       WineLoaderHelper.binary(inAppBundle: override), "or the binary")
        XCTAssertEqual(WineLoaderHelper.locate(environment: [WineLoaderHelper.environmentKey: "/nonexistent/wine"], appBundle: app, applications: installed),
                       WineLoaderHelper.binary(inAppBundle: app), "a wrong override falls through")
        // The CLI on a Mac without the app: a non-bundle main executable has no helper of its own.
        XCTAssertEqual(WineLoaderHelper.locate(environment: [:], appBundle: URL(fileURLWithPath: "/usr/local/bin/highball"), applications: installed),
                       WineLoaderHelper.binary(inAppBundle: installed))
    }

    func testTheRosettaSwitchOnlyReachesRosettaEngines() throws {
        // Bottle.environment sets ROSETTA_ADVERTISE_AVX for an Intel engine (EnvironmentTests) and
        // must not for an arm64 one, where x86 code runs through FEX and the variable means nothing.
        var bottle = Bottle(url: URL(fileURLWithPath: "/tmp/hb-arch-test-bottle"), settings: BottleSettings(name: "t", engineID: "arm64-test-r1"))
        bottle.settings.advertiseAVX = true
        let arm = InstalledEngine(manifest: manifest("arm64"), root: tempRoot("arm64-engine"))
        XCTAssertNil(try bottle.environment(engine: arm, renderer: .wined3d)["ROSETTA_ADVERTISE_AVX"])
        let intel = InstalledEngine(manifest: manifest("x86_64", requires: ["rosetta2"]), root: tempRoot("x64-engine"))
        XCTAssertEqual(try bottle.environment(engine: intel, renderer: .wined3d)["ROSETTA_ADVERTISE_AVX"], "1")
    }
}
