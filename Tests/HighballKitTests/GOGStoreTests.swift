import XCTest
@testable import HighballKit

final class GOGStoreTests: XCTestCase {
    /// The temporary folder is reached as /var and as /private/var; compare one spelling.
    private func norm(_ url: URL?) -> String? {
        url.map { $0.path.hasPrefix("/private/var/") ? String($0.path.dropFirst("/private".count)) : $0.path }
    }

    /// GOG's sign-in ends on embed.gog.com/on_login_success; people paste the whole address, the
    /// address without its scheme, or the code alone.
    func testAuthorizationCodeFromWhatPeoplePaste() {
        XCTAssertEqual(GOGStore.authorizationCode(from: "https://embed.gog.com/on_login_success?origin=client&code=AbC-123_x"), "AbC-123_x")
        XCTAssertEqual(GOGStore.authorizationCode(from: "  embed.gog.com/on_login_success?origin=client&code=AbC12345  \n"), "AbC12345")
        XCTAssertEqual(GOGStore.authorizationCode(from: "AbC123def"), "AbC123def")
        XCTAssertNil(GOGStore.authorizationCode(from: "two words"))
        XCTAssertNil(GOGStore.authorizationCode(from: ""))
    }

    /// The sheet names the usual wrong pastes, and a code is only taken from a gog.com address.
    func testWrongPastesAreNamedAndNeverSent() {
        XCTAssertEqual(GOGStore.readSignIn(""), .empty)
        XCTAssertEqual(GOGStore.readSignIn(GOGStore.loginURL.absoluteString), .signInPage, "copied before logging in")
        XCTAssertEqual(GOGStore.readSignIn("https://login.gog.com/login?code=x"), .signInPage)
        XCTAssertEqual(GOGStore.readSignIn("https://embed.gog.com/on_login_success?origin=client"), .noCode)
        XCTAssertEqual(GOGStore.readSignIn("https://www.gog.com/en/account"), .noCode)
        XCTAssertEqual(GOGStore.readSignIn("https://example.com/on_login_success?code=AbC12345"), .notGOG)
        XCTAssertEqual(GOGStore.readSignIn("https://embed.gog.com.example.com/?code=AbC12345"), .notGOG)
        XCTAssertEqual(GOGStore.readSignIn("https://notgog.com/?code=AbC12345"), .notGOG)
        XCTAssertEqual(GOGStore.readSignIn("file:///etc/?code=AbC12345"), .notGOG)
        XCTAssertEqual(GOGStore.readSignIn("https://gog.com@example.com/?code=AbC12345"), .notGOG)
        XCTAssertEqual(GOGStore.readSignIn("https://example.com%2F.gog.com/?code=AbC12345"), .notGOG, "an encoded slash is not a gog.com host")
        XCTAssertEqual(GOGStore.readSignIn("https://embed.gog.com/on_login_success?xcode=AbC12345"), .noCode)
        XCTAssertEqual(GOGStore.readSignIn("short"), .notGOG)
    }

    /// Token values never reach an error message or a log line, however gogdl prints them.
    func testGogdlOutputIsRedacted() {
        let out = GOGStore.redacted(#"{"access_token": "aaa111", "refresh_token":"bbb222", "user_id": "42"} 'session_id': 'ccc333' code=ddd444&x=1 Authorization: Bearer eee555 auth --code fff666"#)
        for secret in ["aaa111", "bbb222", "ccc333", "ddd444", "eee555", "fff666"] { XCTAssertFalse(out.contains(secret), secret) }
        XCTAssertTrue(out.contains(#""user_id": "42""#), "the rest stays readable")
        let progress = "[PROGRESS] INFO: = Progress: 0.00 137861/45061146188, Running for: 00:00:02"
        XCTAssertEqual(GOGStore.redacted(progress), progress)
    }

    /// The folder with the tokens is this user's only, even when it already existed.
    func testGOGFolderIsPrivate() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = GOGStore(paths: HighballPaths(home: home))
        try FileManager.default.createDirectory(at: store.dir, withIntermediateDirectories: true)
        store.secureDirectory()
        let mode = try FileManager.default.attributesOfItem(atPath: store.dir.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
    }

    func testLoginURLIsGalaxysPublicClient() {
        let c = URLComponents(url: GOGStore.loginURL, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(c.queryItems?.first { $0.name == "client_id" }?.value, "46899977096215655")
        XCTAssertEqual(c.queryItems?.first { $0.name == "redirect_uri" }?.value, "https://embed.gog.com/on_login_success?origin=client")
        XCTAssertEqual(c.queryItems?.first { $0.name == "response_type" }?.value, "code")
    }

    /// gogdl's progress lines as a Control download printed them (2026-10-28).
    func testProgressLines() {
        let p = GOGStore.progress(inGogdlLine: "[PROGRESS] INFO: = Progress: 0.00 137861/45061146188, Running for: 00:00:02, ETA: 271:03:22")
        XCTAssertEqual(p?.written, 137861)
        XCTAssertEqual(p?.total, 45061146188)
        for other in ["[PROGRESS] INFO: = Downloaded: 27.50 MiB, Written: 0.00 MiB",
                      "[PROGRESS] INFO:  + Download\t- 27.50 MiB/s (raw) / 64.99 MiB/s (decompressed)",
                      "[V2] INFO: Initialized V2 Download Manager"] {
            XCTAssertNil(GOGStore.progress(inGogdlLine: other), other)
        }
    }

    func testInstallFailuresBecomeSentences() {
        XCTAssertEqual(GOGStore.installFailure("[TASK_EXECUTOR] ERROR: Unable to proceed, Not enough disk space"),
                       "This Mac doesn't have enough free space for the game. Free some space, then press Install again.")
        XCTAssertNotNil(GOGStore.installFailure("[CLI] ERROR: Game doesn't support content system api, unable to proceed using platform windows"))
        XCTAssertEqual(GOGStore.installFailure("[API] ERROR: Failed to get manifest"), "GOG's downloader stopped with this message. Failed to get manifest")
        XCTAssertNil(GOGStore.installFailure("[PROGRESS] INFO: = Progress: 12.00 1/2, Running for: 00:00:01, ETA: 00:00:01"))
    }

    func testDownloadAndUpdateArguments() {
        let download = GOGStore.downloadArguments(id: "1957528513", into: "/c/Games", support: "/s", language: "en-US", update: false)
        XCTAssertEqual(Array(download.prefix(2)), ["download", "1957528513"])
        XCTAssertEqual(download[download.firstIndex(of: "--path")! + 1], "/c/Games")
        XCTAssertEqual(download[download.firstIndex(of: "--platform")! + 1], "windows")
        XCTAssertTrue(download.contains("--with-dlcs"))
        let update = GOGStore.downloadArguments(id: "1957528513", into: "/c/Games/Ghostrunner", support: "/s", language: "en-US", update: true)
        XCTAssertEqual(update.first, "update")
    }

    func testLanguageFollowsTheMac() {
        XCTAssertEqual(GOGStore.language(for: ["en-US", "fr-FR", "de-DE"], preferred: ["fr-CA", "en-US"]), "fr-FR")
        XCTAssertEqual(GOGStore.language(for: ["en-US", "de-DE"], preferred: ["ja-JP"]), "en-US")
        XCTAssertEqual(GOGStore.language(for: ["de-DE"], preferred: ["ja-JP"]), "de-DE")
        XCTAssertEqual(GOGStore.language(for: [], preferred: ["ja-JP"]), "en-US")
    }

    // MARK: gamesdb

    /// A trimmed gamesdb release: Steam id taken from GOG's own release list, so the cover is
    /// Steam's 600×900 capsule and the compatibility row matches by Steam id.
    func testReleaseUsesTheSteamIDGOGGives() throws {
        let json = """
        {"type":"game","title":{"*":"Ghostrunner "},"game":{"visible_in_library":true,
         "releases":[{"platform_id":"gog","external_id":"1957528513"},{"platform_id":"steam","external_id":"1139900"}],
         "vertical_cover":{"url_format":"https://images.gog.com/abc{formatter}.{ext}?namespace=gamesdb"},
         "background":{"url_format":"https://images.gog.com/bg{formatter}.{ext}?namespace=gamesdb"}}}
        """
        let game = try XCTUnwrap(GOGStore.parseRelease(id: "1957528513", data: Data(json.utf8)))
        XCTAssertEqual(game.title, "Ghostrunner")
        XCTAssertEqual(game.steamAppID, 1139900)
        XCTAssertEqual(game.artworkTall?.absoluteString, "https://cdn.akamai.steamstatic.com/steam/apps/1139900/library_600x900.jpg")
        XCTAssertEqual(game.gogVerticalCover?.absoluteString, "https://images.gog.com/abc.jpg?namespace=gamesdb")
    }

    func testReleaseWithoutSteamFallsBackToGOGArt() throws {
        let json = """
        {"type":"game","title":{"*":"Quake II RTX"},"game":{"releases":[],
         "vertical_cover":{"url_format":"https://images.gog.com/q2{formatter}.{ext}?namespace=gamesdb"}}}
        """
        let game = try XCTUnwrap(GOGStore.parseRelease(id: "1825786806", data: Data(json.utf8)))
        XCTAssertNil(game.steamAppID)
        XCTAssertEqual(game.artworkTall?.absoluteString, "https://images.gog.com/q2.jpg?namespace=gamesdb")
    }

    func testDLCAndHiddenReleasesStayOutOfTheLibrary() {
        let dlc = #"{"type":"dlc","title":{"*":"Ghostrunner - Katana Pack"},"game":{"visible_in_library":true}}"#
        let hidden = #"{"type":"game","title":{"*":"Hidden"},"game":{"visible_in_library":false}}"#
        XCTAssertNil(GOGStore.parseRelease(id: "1", data: Data(dlc.utf8)))
        XCTAssertNil(GOGStore.parseRelease(id: "2", data: Data(hidden.utf8)))
    }

    // MARK: Installs on disk

    private func makeGame(_ root: URL, folder: String, infos: [String: String]) throws -> URL {
        let dir = root.appending(path: folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, json) in infos { try json.write(to: dir.appending(path: name), atomically: true, encoding: .utf8) }
        return dir
    }

    /// Ghostrunner as gogdl installed it, with its DLC's info file beside the game's, and Control
    /// from an offline installer in GOG's default folder: both found, with the DLC attached.
    func testInstalledGamesComeFromInfoFiles() throws {
        let driveC = FileManager.default.temporaryDirectory.appending(path: "gog-\(UUID().uuidString)/drive_c")
        defer { try? FileManager.default.removeItem(at: driveC.deletingLastPathComponent()) }
        let gr = try makeGame(driveC.appending(path: "Games"), folder: "Ghostrunner", infos: [
            "goggame-1957528513.info": #"{"gameId":"1957528513","rootGameId":"1957528513","name":"Ghostrunner","buildId":"555","clientId":"533","playTasks":[{"category":"game","isPrimary":true,"name":"Ghostrunner","path":"Ghostrunner\\Binaries\\Win64\\Ghostrunner-Win64-Shipping.exe","arguments":"-GOG","type":"FileTask"},{"category":"game","name":"Ghostrunner DX12","path":"Ghostrunner/Binaries/Win64/Ghostrunner-Win64-Shipping.exe","arguments":"-GOG -dx12","type":"FileTask"}]}"#,
            "goggame-2009792833.info": #"{"gameId":"2009792833","rootGameId":"1957528513","name":"Ghostrunner - Katana Pack"}"#,
        ])
        try FileManager.default.createDirectory(at: gr.appending(path: "Ghostrunner/Binaries/Win64"), withIntermediateDirectories: true)
        _ = try makeGame(driveC.appending(path: "GOG Games"), folder: "Control", infos: [
            "goggame-2049187585.info": #"{"gameId":"2049187585","rootGameId":"2049187585","name":"Control Ultimate Edition","buildId":"592","playTasks":[{"isPrimary":true,"name":"Control","path":"Control.exe","category":"launcher","type":"FileTask"},{"name":"Support","type":"URLTask","path":"","category":"document","url":"http://www.gog.com/support"}]}"#,
        ])
        // A download still running is not an install yet.
        let partial = try makeGame(driveC.appending(path: "Games"), folder: "Half", infos: ["goggame-1.info": #"{"gameId":"1","name":"Half"}"#])
        try "".write(to: partial.appending(path: ".gogdl-resume"), atomically: true, encoding: .utf8)

        let games = GOGStore.installedGames(driveC: driveC).sorted { $0.title < $1.title }
        XCTAssertEqual(games.map(\.id), ["2049187585", "1957528513"])
        let ghostrunner = games[1]
        XCTAssertEqual(ghostrunner.dlcIDs, ["2009792833"])
        XCTAssertEqual(ghostrunner.clientID, "533")
        XCTAssertEqual(ghostrunner.launchChoices.count, 2, "two visible game tasks: a choice on the page")

        let primary = try XCTUnwrap(ghostrunner.launchTask())
        let launch = try XCTUnwrap(GOGStore.launch(primary, in: ghostrunner))
        XCTAssertEqual(norm(launch.executable), norm(gr.appending(path: "Ghostrunner/Binaries/Win64/Ghostrunner-Win64-Shipping.exe")),
                       "Windows separators become Unix ones")
        XCTAssertEqual(launch.arguments, ["-GOG"])
        XCTAssertEqual(norm(launch.workingDirectory), norm(gr))
        XCTAssertEqual(ghostrunner.launchTask(choice: 1)?.arguments, "-GOG -dx12")

        // Control.exe is a launcher that hands over to Control_DX11.exe and exits: the session
        // watches every program in the folder, not the redist installers or the uninstaller.
        let controlFolder = driveC.appending(path: "GOG Games/Control")
        for exe in ["Control.exe", "Control_DX11.exe", "unins000.exe", "__redist/DirectX/DXSETUP.exe", "_CommonRedist/vcredist_x64.exe"] {
            let file = controlFolder.appending(path: exe)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: file.path, contents: Data())
        }
        XCTAssertEqual(games[0].sessionMarkers(launching: controlFolder.appending(path: "Control.exe")), ["Control.exe", "Control_DX11.exe"])
        XCTAssertTrue(SessionWatch.isAlive(markers: games[0].sessionMarkers(launching: controlFolder.appending(path: "Control.exe")), ps: "77480 Control_DX11.exe \n"))

        let control = games[0]
        XCTAssertTrue(control.launchChoices.isEmpty, "a manual is not a launch option")
        XCTAssertEqual(control.launchTask()?.path, "Control.exe")
    }

    /// Info files are written on Windows, where case does not matter; the Mac volume may care.
    func testPathsAreFoundWhateverTheirCase() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "gogcase-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "Bin"), withIntermediateDirectories: true)
        try "".write(to: root.appending(path: "Bin/Game.exe"), atomically: true, encoding: .utf8)
        // On a case-insensitive volume the spelling as written already opens; on a case-sensitive
        // one the lookup finds the file's own spelling. Either way the file is there.
        XCTAssertTrue(FileManager.default.fileExists(atPath: GOGStore.resolve(#"bin\GAME.EXE"#, in: root).path))
    }

    // MARK: Cloud saves

    func testSaveLocationsFromRemoteConfig() {
        let json = #"{"content":{"Windows":{"cloudStorage":{"enabled":true,"locations":[{"name":"saves","location":"<?SAVED_GAMES?>/Remedy/Control"}]}}}}"#
        XCTAssertEqual(GOGSaves.parseLocations(Data(json.utf8), clientID: "c"), [.init(name: "saves", template: "<?SAVED_GAMES?>/Remedy/Control")])
        let empty = #"{"content":{"Windows":{"cloudStorage":{"enabled":true,"locations":[]}}}}"#
        XCTAssertEqual(GOGSaves.parseLocations(Data(empty.utf8), clientID: "533")?.first?.name, "__default",
                       "an empty list is the SDK's own storage folder")
        XCTAssertEqual(GOGSaves.parseLocations(Data(empty.utf8), clientID: "533")?.first?.template,
                       "<?APPLICATION_DATA_LOCAL?>/GOG.com/Galaxy/Applications/533/Storage/Shared/Files")
        let off = #"{"content":{"Windows":{"cloudStorage":{"enabled":false}}}}"#
        XCTAssertNil(GOGSaves.parseLocations(Data(off.utf8), clientID: "c"))
    }

    func testClientIDFromCompressedBuildManifest() throws {
        let json = Data(#"{"baseProductId":"2049187585","clientId":"53538800219319237"}"#.utf8)
        // A v2 manifest as GOG serves it: zlib header, raw DEFLATE (checksum left off; not read).
        let zlib = Data([0x78, 0x9c]) + (try (json as NSData).compressed(using: .zlib) as Data)
        XCTAssertEqual(GOGSaves.clientID(inManifest: zlib), "53538800219319237")
        XCTAssertEqual(GOGSaves.clientID(inManifest: json), "53538800219319237", "plain JSON reads too")
        XCTAssertNil(GOGSaves.clientID(inManifest: Data([0x78, 0x9c, 0x00])))
    }

    func testSaveFoldersResolveInsideTheEnvironment() throws {
        let driveC = FileManager.default.temporaryDirectory.appending(path: "gogsaves-\(UUID().uuidString)/drive_c")
        defer { try? FileManager.default.removeItem(at: driveC.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: driveC.appending(path: "users/player"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: driveC.appending(path: "users/Public"), withIntermediateDirectories: true)
        let game = GOGStore.InstalledGame(id: "1", title: "G", folder: driveC.appending(path: "Games/G"), buildID: nil, clientID: nil, dlcIDs: [], tasks: [])
        let user = driveC.appending(path: "users/player")
        func path(_ template: String) -> String? { norm(GOGSaves.resolve(template, game: game, driveC: driveC, userName: "player")) }
        XCTAssertEqual(path("<?SAVED_GAMES?>/Remedy/Control"),
                       norm(user.appending(path: "Saved Games/Remedy/Control")))
        XCTAssertEqual(path(#"<?APPLICATION_DATA_LOCAL_LOW?>\Studio\Game"#),
                       norm(user.appending(path: "AppData/LocalLow/Studio/Game")))
        XCTAssertEqual(GOGSaves.resolve("<?INSTALL?>/saves", game: game, driveC: driveC)?.path, game.folder.appending(path: "saves").path)
        XCTAssertNil(GOGSaves.resolve("<?APPLICATION_SUPPORT?>/x", game: game, driveC: driveC), "a Mac-native variable has no Windows folder")
        XCTAssertNil(GOGSaves.resolve("<?DOCUMENTS?>/%USERNAME%/x", game: game, driveC: driveC), "an unknown Windows variable is not guessed")
        XCTAssertNil(GOGSaves.resolve("<?DOCUMENTS?>", game: game, driveC: driveC), "a whole known folder is never synced")
        XCTAssertNil(GOGSaves.resolve("<?INSTALL?>/", game: game, driveC: driveC))
        XCTAssertNil(GOGSaves.resolve("<?INSTALL?>/../..", game: game, driveC: driveC), "nor one outside it")
    }

    /// gogdl's conflict line, and the flags each direction passes (gogdl/saves.py).
    func testSaveSyncArgumentsAndConflictLine() {
        let location = GOGSaves.Location(name: "saves", template: "")
        let down = GOGSaves.arguments(folder: URL(fileURLWithPath: "/s"), id: "1", location: location, timestamp: "0", direction: .download)
        XCTAssertEqual(down, ["save-sync", "/s", "1", "--os", "windows", "--ts", "0", "--name", "saves", "--skip-upload"])
        XCTAssertEqual(GOGSaves.arguments(folder: URL(fileURLWithPath: "/s"), id: "1", location: location, timestamp: "5", direction: .upload).last, "--skip-download")
        XCTAssertEqual(GOGSaves.arguments(folder: URL(fileURLWithPath: "/s"), id: "1", location: location, timestamp: "5", direction: .forceDownload).last, "--force-download")
        XCTAssertTrue(GOGSaves.isConflict("[SAVES] WARNING: Files in conflict force downloading or uploading of files"))
        XCTAssertFalse(GOGSaves.isConflict("[SAVES] INFO: Downloading 3 files"))
    }

    /// The new timestamp is written without a newline, so it reaches the shared pipe glued to the
    /// next log line (gogdl/saves.py), and still has to be kept.
    func testSaveTimestampIsReadOffAGluedLine() throws {
        let glued = try XCTUnwrap(GOGSaves.timestamp(in: "1793193913.871504[SAVES] INFO: Done"))
        XCTAssertEqual(glued.0, "1793193913.871504")
        XCTAssertEqual(glued.1, "[SAVES] INFO: Done")
        XCTAssertEqual(GOGSaves.timestamp(in: "1793193913.871504")?.1, "")
        XCTAssertNil(GOGSaves.timestamp(in: "0"), "the unchanged 0 is not a sync")
        XCTAssertNil(GOGSaves.timestamp(in: "[SAVES] INFO: Downloading 3 files"))
    }

    // MARK: comet

    /// Tokens reach comet through a file in its private HOME, never its command line.
    func testCometArgumentsCarryNoTokens() {
        let args = GOGComet.arguments(username: "player")
        XCTAssertEqual(args, ["--from-heroic", "--username", "player", "--quit"])
        XCTAssertFalse(args.contains { $0.contains("token") })
    }

    func testCometSettingsRoundTrip() throws {
        var s = GOGSettings()
        s.cometOff["1"] = "crashed with comet"
        s.cloudSavesOff.insert("2")
        s.launchChoice["3"] = 1
        let back = try JSONDecoder().decode(GOGSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    // MARK: Library, play links, uninstall

    func testLibraryBuildsOneGOGTilePerGame() throws {
        func bottle(_ name: String) -> Bottle {
            Bottle(url: URL(fileURLWithPath: "/tmp/hb-gog-tests/bottles/\(name)"), settings: BottleSettings(name: name, engineID: "e"))
        }
        let games = bottle("Games"), clean = bottle("Clean")
        let installed = GOGStore.InstalledGame(id: "1957528513", title: "Ghostrunner", folder: games.driveC.appending(path: "Games/Ghostrunner"),
                                               buildID: "1", clientID: nil, dlcIDs: [], tasks: [])
        let offline = GOGStore.InstalledGame(id: "42", title: "From an offline installer", folder: clean.driveC.appending(path: "GOG Games/X"),
                                             buildID: nil, clientID: nil, dlcIDs: [], tasks: [])
        let items = LibraryIndex.build(bottles: [games, clean], steamByBottle: [:], epicOwned: [], epicInstalls: [:],
                                       gogGames: [GOGStore.Game(id: "1957528513", title: "Ghostrunner", steamAppID: 1139900),
                                                  GOGStore.Game(id: "7", title: "Owned, not installed")],
                                       gogInstalledByBottle: ["Games": [installed], "Clean": [offline]],
                                       defaultBottle: "Games")
        let gog = items.filter { $0.source == .gog }
        XCTAssertEqual(gog.count, 3)
        let gr = try XCTUnwrap(gog.first { $0.gogID == "1957528513" })
        XCTAssertEqual(gr.bottleName, "Games")
        XCTAssertTrue(gr.installed)
        XCTAssertNil(gr.steamAppID, "a GOG copy is never treated as a Steam game")
        XCTAssertEqual(gr.gogSteamAppID, 1139900)
        XCTAssertEqual(gr.artworkTall?.absoluteString, "https://cdn.akamai.steamstatic.com/steam/apps/1139900/library_600x900.jpg")
        let notInstalled = try XCTUnwrap(gog.first { $0.gogID == "7" })
        XCTAssertNil(notInstalled.bottleName)
        XCTAssertFalse(notInstalled.installed)
        let found = try XCTUnwrap(gog.first { $0.gogID == "42" }, "an install the account list does not name still gets a tile")
        XCTAssertEqual(found.bottleName, "Clean")
    }

    func testPinsInsideAGOGGameFolderGiveWayToItsTile() throws {
        var games = Bottle(url: URL(fileURLWithPath: "/tmp/hb-gog-tests/bottles/Games"), settings: BottleSettings(name: "Games", engineID: "e"))
        func tasks(_ json: String) throws -> [GOGStore.PlayTask] { try JSONDecoder().decode([GOGStore.PlayTask].self, from: Data(json.utf8)) }
        let quake = GOGStore.InstalledGame(id: "1825786806", title: "Quake II RTX", folder: games.driveC.appending(path: "GOG Games/Quake II RTX"),
                                           buildID: nil, clientID: nil, dlcIDs: [], tasks: try tasks(#"[{"isPrimary":true,"name":"Quake II RTX","path":"q2rtx.exe","type":"FileTask"}]"#))
        let control = GOGStore.InstalledGame(id: "2049187585", title: "Control", folder: games.driveC.appending(path: "GOG Games/Control"),
                                             buildID: nil, clientID: nil, dlcIDs: [], tasks: try tasks(#"[{"isPrimary":true,"name":"Control","path":"Control.exe","type":"FileTask"}]"#))
        let ghostrunner = GOGStore.InstalledGame(
            id: "1957528513", title: "Ghostrunner", folder: games.driveC.appending(path: "GOG Games/Ghostrunner"), buildID: nil, clientID: nil, dlcIDs: [],
            tasks: try tasks(#"[{"isPrimary":true,"name":"Ghostrunner","path":"Ghostrunner\\Binaries\\Win64\\Ghostrunner-Win64-Shipping.exe","arguments":"-GOG","type":"FileTask"}]"#))
        let quakePin = Pin(name: "Quake II", path: "GOG Games/Quake II RTX/q2rtx.exe", arguments: ["+set", "vid_rtx", "0"])
        let grPin = Pin(name: "Ghostrunner", path: "GOG Games/ghostrunner/Ghostrunner/Binaries/Win64/Ghostrunner-Win64-Shipping.exe", arguments: ["-GOG"])
        let tuned = Pin(name: "Quake tuned", path: "GOG Games/Quake II RTX/q2rtx.exe", environment: ["DXVK_HUD": "1"])
        let other = Pin(name: "Something else", path: "Games/Other/other.exe")
        let lookalike = Pin(name: "Not Quake", path: "GOG Games/Quake II RTX Mod/mod.exe")
        let tool = Pin(name: "Quake setup", path: "GOG Games/Quake II RTX/setup/Quake2RTX-Steam-Setup.exe")
        let dx11 = Pin(name: "Control", path: "GOG Games/Control/Control_DX11.exe")
        let controlTool = Pin(name: "Control settings", path: "GOG Games/Control/ControlConfig.exe")
        games.settings.pins = [quakePin, grPin, tuned, other, lookalike, tool, dx11, controlTool]
        let installs = ["Games": [quake, ghostrunner, control]]

        let covered = LibraryIndex.gogCoveredPins(bottles: [games], gogInstalledByBottle: installs)
        XCTAssertEqual(covered.map(\.pinItemID), ["pin:Games:\(quakePin.id.uuidString)", "pin:Games:\(grPin.id.uuidString)", "pin:Games:\(dx11.id.uuidString)"],
                       "the game's own programs and a variant beside the main one give way; a tool in the folder, a pin with its own variables and a folder that only starts the same keep their tiles")
        XCTAssertEqual(covered[0].gogItemID, "gog:1825786806")
        XCTAssertEqual(covered[0].extraArguments, ["+set", "vid_rtx", "0"], "the pin's arguments go to the GOG tile")
        XCTAssertEqual(covered[1].extraArguments, [], "-GOG is already what the GOG task passes, so it is not added twice")

        let items = LibraryIndex.build(bottles: [games], steamByBottle: [:], epicOwned: [], epicInstalls: [:],
                                       gogInstalledByBottle: installs)
        XCTAssertEqual(items.filter { $0.source == .pin }.map(\.title).sorted(), ["Control settings", "Not Quake", "Quake setup", "Quake tuned", "Something else"])
        XCTAssertEqual(items.filter { $0.source == .gog }.count, 3)
    }

    func testSetupStepCommands() {
        let dir = URL(fileURLWithPath: "/tmp/redist")
        let msi = GOGStore.SetupStep(label: "PhysX", executable: nil, arguments: ["/i", "/tmp/redist/physx.msi", "/qb"], workingDirectory: dir)
        XCTAssertEqual(msi.command, ["msiexec", "/i", "/tmp/redist/physx.msi", "/qb"], "an .msi runtime runs through Wine's own msiexec, by name")
        let exe = GOGStore.SetupStep(label: "VC++", executable: dir.appending(path: "vcredist.exe"), arguments: ["/quiet"], workingDirectory: dir)
        XCTAssertEqual(exe.command, ["/tmp/redist/vcredist.exe", "/quiet"])
    }

    func testGOGSettingsReadAFileWrittenBeforeANewField() throws {
        let old = Data(#"{"cometOff":{"1":"turned off"},"cloudSavesOff":["2"],"launchChoice":{"3":1}}"#.utf8)
        let s = try JSONDecoder().decode(GOGSettings.self, from: old)
        XCTAssertEqual(s.cometOff["1"], GOGSettings.turnedOff)
        XCTAssertEqual(s.cloudSavesOff, ["2"])
        XCTAssertTrue(s.carriedOverPins.isEmpty)
    }

    func testPlayLinkAndUninstallForGOG() {
        let item = LibraryItem(source: .gog, id: "gog:1957528513", title: "Ghostrunner", bottleName: "Games", installed: true, gogID: "1957528513")
        let target = PlayLink.target(for: item)
        XCTAssertEqual(target, .gog(id: "1957528513"))
        let url = PlayLink.url(for: target!, token: "t")
        XCTAssertEqual(url.absoluteString, "highball://play/gog/1957528513?t=t")
        XCTAssertEqual(PlayLink.parse(url)?.target.libraryID, "gog:1957528513")
        XCTAssertNil(PlayLink.parse(URL(string: "highball://play/gog/../../x?t=t")!), "ids are numbers only")
        XCTAssertEqual(Uninstall.route(for: item), .gog(id: "1957528513"))
        let notHere = LibraryItem(source: .gog, id: "gog:7", title: "X", bottleName: nil, installed: false, gogID: "7")
        XCTAssertFalse(Uninstall.isActionable(Uninstall.route(for: notHere)))
    }

    /// comet's unlock lines, as v0.4.0 writes them; a name may hold a comma.
    func testAchievementUnlocksAreReadOffCometsLog() {
        let log = """
        [2026-10-28T14:15:48Z INFO  comet::api::handlers] Uploading new achievements
        [2026-10-28T14:32:50Z INFO  comet::api::handlers::utils] Unlocking achievement HILT_ACHIEVEMENT, Choose to be Chosen
        [2026-10-28T14:40:01Z INFO  comet::api::handlers::utils] Unlocking achievement A_2, Well, That Happened
        """
        let unlocks = GOGAchievements.unlocks(in: log)
        XCTAssertEqual(unlocks.map(\.key), ["HILT_ACHIEVEMENT", "A_2"])
        XCTAssertEqual(unlocks.map(\.name), ["Choose to be Chosen", "Well, That Happened"])
    }

    /// Each read returns only what is new, and a line still being written waits for the next read.
    func testAchievementLogReaderTakesWholeNewLinesOnce() throws {
        let log = FileManager.default.temporaryDirectory.appending(path: "comet-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        try "x Unlocking achievement ONE, First\nx Unlocking achievement TWO, Sec".write(to: log, atomically: true, encoding: .utf8)
        let reader = GOGAchievements.LogReader(log: log)
        XCTAssertEqual(reader.newUnlocks().map(\.key), ["ONE"])
        XCTAssertTrue(reader.newUnlocks().isEmpty)
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("ond\n".utf8))
        try handle.close()
        XCTAssertEqual(reader.newUnlocks().map(\.name), ["Second"])
    }

    /// The pop-up's details come from comet's database, found by client id; a key it lacks keeps
    /// the logged name.
    func testAchievementDetailsComeFromCometsDatabase() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "comet-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appending(path: "Library/Application Support/comet/gameplay/5353/1001")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "gameplay.db")
        let sql = """
        CREATE TABLE achievement (id INTEGER PRIMARY KEY, key TEXT UNIQUE NOT NULL, name TEXT NOT NULL, description TEXT NOT NULL,
          visible_while_locked INTEGER NOT NULL, unlock_time TEXT, image_url_locked TEXT NOT NULL, image_url_unlocked TEXT NOT NULL,
          changed INTEGER NOT NULL, rarity REAL NOT NULL DEFAULT 0.0, rarity_level_description TEXT NOT NULL DEFAULT "",
          rarity_level_slug TEXT NOT NULL DEFAULT "");
        INSERT INTO achievement VALUES (1, 'HARTFELT', 'The Third Thing', 'Defeat Hartman', 0, NULL,
          'https://images.gog.com/a_gac_60.jpg', 'https://images.gog.com/b_gac_60.jpg', 0, 12.1, 'Uncommon', 'uncommon');
        """
        _ = try Shell.capture("/usr/bin/sqlite3", [file.path, sql])
        let db = GOGAchievements.database(home: home, clientID: "5353")
        XCTAssertEqual(db?.lastPathComponent, "gameplay.db")
        XCTAssertNil(GOGAchievements.database(home: home, clientID: "9999"))
        let found = GOGAchievements.details(key: "HARTFELT", name: "logged", database: db)
        XCTAssertEqual(found.name, "The Third Thing")
        XCTAssertEqual(found.description, "Defeat Hartman")
        XCTAssertEqual(found.imageURL?.absoluteString, "https://images.gog.com/b_gac_60.jpg")
        XCTAssertEqual(found.rarity, 12.1, accuracy: 0.001)
        XCTAssertEqual(found.rarityLevel, "Uncommon")
        XCTAssertEqual(GOGAchievements.details(key: "OTHER", name: "logged", database: db), GOGAchievement(key: "OTHER", name: "logged"))
    }
}
