import Foundation
import CoreGraphics
import ImageIO

// The unified library (One Library, Phase 2): every playable thing across all bottles and
// sources as one flat, source-neutral list. The store is a badge and a filter, never a
// section; the bottle is a per-game property, never the navigation.

public enum LibrarySource: String, Sendable, Codable {
    case steam, epic, pin
}

/// A playable item in the unified library. Pure value: no Bottle, no GameDBEntry — the app
/// resolves `bottleName` to a Bottle at action time and joins the db at render time, which
/// keeps this type constructible (and the aggregator testable) without a filesystem.
public struct LibraryItem: Identifiable, Sendable, Hashable {
    public let source: LibrarySource
    /// Stable identity, also the persistence key in library.json — never change its shape:
    /// "steam:<appid>" | "epic:<app_name>" | "pin:<bottle>:<uuid>".
    public let id: String
    public let title: String
    /// Where it lives. nil only for an Epic title owned but not installed in any bottle.
    public let bottleName: String?
    public let installed: Bool
    /// Steam for Mac has its native build installed (MacSteam); Play goes there first.
    public let installedOnMac: Bool
    public let steamAppID: Int?
    public let epicAppName: String?
    public let pinID: UUID?
    public let artworkTall: URL?
    public let artworkWide: URL?
    /// Dedup leftovers: other bottles holding the same Steam game (detail view only).
    public let otherBottles: [String]
    public let sizeOnDisk: Int64
    public let lastPlayed: Date?

    public init(source: LibrarySource, id: String, title: String, bottleName: String?,
                installed: Bool, installedOnMac: Bool = false, steamAppID: Int? = nil, epicAppName: String? = nil,
                pinID: UUID? = nil, artworkTall: URL? = nil, artworkWide: URL? = nil,
                otherBottles: [String] = [], sizeOnDisk: Int64 = 0, lastPlayed: Date? = nil) {
        self.source = source; self.id = id; self.title = title; self.bottleName = bottleName
        self.installed = installed; self.installedOnMac = installedOnMac
        self.steamAppID = steamAppID; self.epicAppName = epicAppName
        self.pinID = pinID; self.artworkTall = artworkTall; self.artworkWide = artworkWide
        self.otherBottles = otherBottles; self.sizeOnDisk = sizeOnDisk; self.lastPlayed = lastPlayed
    }

    /// Playable here in either build: the Windows one in a bottle or the Mac one in Steam for Mac.
    public var installedAnywhere: Bool { installed || installedOnMac }

    /// The same game seen from another environment: the library shows one tile per Steam game,
    /// homed where it was last played (highball#264), and this is how Play reaches a copy in one
    /// of the others, or how Install hands the game to that environment's Steam. Installed when
    /// that environment holds a copy.
    public func homed(in bottle: String) -> LibraryItem {
        guard bottle != bottleName else { return self }
        let holds = otherBottles.contains(bottle)
        let others = (otherBottles.filter { $0 != bottle } + (installed ? [bottleName].compactMap { $0 } : [])).sorted()
        return LibraryItem(source: source, id: id, title: title, bottleName: bottle, installed: holds,
                           installedOnMac: installedOnMac, steamAppID: steamAppID, epicAppName: epicAppName,
                           pinID: pinID, artworkTall: artworkTall, artworkWide: artworkWide,
                           otherBottles: others, sizeOnDisk: holds ? 0 : sizeOnDisk, lastPlayed: lastPlayed)
    }
}

public enum LibraryIndex {
    /// The installed games in the order the Home row shows them: the ones played most recently
    /// first, then the rest by title, so the row reads as "what you were playing, then what you
    /// have" (highball#252, from PR #230). Owned-but-not-installed games stay out; they belong to
    /// the grid, where the download arrow says what they are.
    public static func installedForHome(_ items: [LibraryItem]) -> [LibraryItem] {
        items.filter(\.installedAnywhere).sorted { a, b in
            switch (a.lastPlayed, b.lastPlayed) {
            case let (x?, y?) where x != y: return x > y
            case (.some, .none): return true
            case (.none, .some): return false
            default: return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }
    }

    /// Launcher pins are infrastructure, not games — they never appear in the library, and
    /// launching one is not "playing" for the Continue shelf. Single source of truth for the
    /// filter BottleView's Programs section shares.
    public static func isLauncherPin(_ pin: Pin) -> Bool {
        let launcherNames = ["steam", "epic games", "battle.net", "gog galaxy", "ea app",
                             "ubisoft connect", "rockstar launcher", "rockstar"]
        return launcherNames.contains(pin.name.lowercased())
    }

    /// Builds the unified item list. Pure: takes exactly what AppState already holds.
    /// Steam games dedup by appid across bottles — one tile per game, never per install;
    /// the primary bottle is where it was last played, then a ready copy, then name order.
    /// `steamOwnedByBottle` adds the account's games that aren't installed anywhere
    /// (SteamOwnedLibrary, highball#199), homed in the first bottle whose Steam owns them.
    /// `macInstalled` is what Steam for Mac has installed (MacSteam): those games count as
    /// installed, and one no bottle knows gets a tile of its own.
    public static func build(bottles: [Bottle],
                             steamByBottle: [String: [SteamGame]],
                             steamOwnedByBottle: [String: [OwnedSteamGame]] = [:],
                             macInstalled: [SteamGame] = [],
                             epicOwned: [EpicStore.Game],
                             epicInstalls: [String: String],
                             plays: [String: LibraryStore.PlayRecord] = [:],
                             defaultBottle: String? = nil,
                             pinExists: (Bottle, Pin) -> Bool = { _, _ in true }) -> [LibraryItem] {
        var items: [LibraryItem] = []
        let onMac = Dictionary(macInstalled.map { ($0.appid, $0) }, uniquingKeysWith: { a, _ in a })
        // Where a game with no other reason to live somewhere goes: the default environment first,
        // then by name. By name alone, a test environment called "Clean" took every owned game
        // from "Games" (highball#264).
        func before(_ a: String, _ b: String) -> Bool {
            if let d = defaultBottle, (a == d) != (b == d) { return a == d }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        let firstBottle = bottles.map(\.name).min(by: before)

        // Steam: group by appid, pick a primary copy, remember the others.
        var byAppID: [Int: [(bottle: String, game: SteamGame)]] = [:]
        for bottle in bottles {
            for game in steamByBottle[bottle.name] ?? [] {
                byAppID[game.appid, default: []].append((bottle.name, game))
            }
        }
        for (appid, copies) in byAppID {
            let id = "steam:\(appid)"
            let lastPlayedBottle = plays[id]?.bottle
            let primary = copies.min { a, b in
                if let lp = lastPlayedBottle, (a.bottle == lp) != (b.bottle == lp) { return a.bottle == lp }
                if a.game.isReady != b.game.isReady { return a.game.isReady }
                return before(a.bottle, b.bottle)
            }!
            let acfPlayed = (copies.compactMap(\.game.lastPlayed) + [onMac[appid]?.lastPlayed].compactMap { $0 }).max()
            let recorded = plays[id]?.lastPlayedAt
            // The client's cached art when it has it (see OwnedSteamGame), the CDN otherwise.
            let owned = steamOwnedByBottle.values.lazy.compactMap { $0.first { $0.appid == appid } }.first
            items.append(LibraryItem(
                source: .steam, id: id, title: primary.game.name, bottleName: primary.bottle,
                installed: primary.game.isReady, installedOnMac: onMac[appid] != nil, steamAppID: appid,
                artworkTall: owned?.localCapsule ?? primary.game.capsuleImage,
                artworkWide: owned?.localHeader ?? primary.game.headerImage,
                otherBottles: copies.map(\.bottle).filter { $0 != primary.bottle }.sorted(),
                sizeOnDisk: primary.game.sizeOnDisk,
                lastPlayed: [acfPlayed, recorded].compactMap { $0 }.max()))
        }

        // Steam games owned but not installed: one tile each, like Epic's, in the first bottle
        // (the default, then by name) whose client lists them, where Install will hand them to Steam.
        var ownedOnly = Set<Int>()
        for bottle in bottles.sorted(by: { before($0.name, $1.name) }) {
            for game in steamOwnedByBottle[bottle.name] ?? [] where byAppID[game.appid] == nil && !ownedOnly.contains(game.appid) {
                ownedOnly.insert(game.appid)
                let id = "steam:\(game.appid)"
                items.append(LibraryItem(
                    source: .steam, id: id, title: game.name, bottleName: bottle.name,
                    installed: false, installedOnMac: onMac[game.appid] != nil, steamAppID: game.appid,
                    artworkTall: game.capsuleImage, artworkWide: game.headerImage,
                    lastPlayed: [onMac[game.appid]?.lastPlayed, plays[id]?.lastPlayedAt].compactMap { $0 }.max()))
            }
        }

        // Installed in Steam for Mac and nowhere else Highball can see (no bottle's Steam signed
        // in yet): still the player's game, homed where a Windows install would go.
        for game in macInstalled where byAppID[game.appid] == nil && !ownedOnly.contains(game.appid) {
            let id = "steam:\(game.appid)"
            items.append(LibraryItem(
                source: .steam, id: id, title: game.name, bottleName: firstBottle,
                installed: false, installedOnMac: true, steamAppID: game.appid,
                artworkTall: game.capsuleImage, artworkWide: game.headerImage,
                lastPlayed: [game.lastPlayed, plays[id]?.lastPlayedAt].compactMap { $0 }.max()))
        }

        // Epic: legendary installs one copy; the owning bottle is whichever drive_c
        // prefixes the install path (see EpicStore.isInstalled).
        for game in epicOwned {
            let id = "epic:\(game.app_name)"
            let home = epicInstalls[game.app_name].flatMap { path in
                bottles.first { EpicStore.isInstalled(path: path, inDriveC: $0.driveC) }?.name
            }
            items.append(LibraryItem(
                source: .epic, id: id, title: game.app_title, bottleName: home,
                installed: home != nil, epicAppName: game.app_name,
                artworkTall: game.artworkTall, artworkWide: game.artworkWide,
                lastPlayed: plays[id]?.lastPlayedAt))
        }

        // Custom pins (dropped exes, preinstalled games), no artwork. Installed when the program's
        // file is there: one on a drive that is unplugged, or deleted since, is not (highball#269,
        // the Installed filter kept listing them). `pinExists` is the app's check of the disk;
        // without one every pin counts, so the index stays testable without a filesystem.
        for bottle in bottles {
            for pin in bottle.settings.pins where !isLauncherPin(pin) {
                let id = "pin:\(bottle.name):\(pin.id.uuidString)"
                items.append(LibraryItem(
                    source: .pin, id: id, title: pin.name, bottleName: bottle.name,
                    installed: pinExists(bottle, pin), pinID: pin.id,
                    lastPlayed: plays[id]?.lastPlayedAt))
            }
        }

        return items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// What an environment holds, for its card in Settings: every Steam game installed in it,
    /// whether or not the library homes that game's tile there (one tile per game, highball#264),
    /// plus the programs and Epic games that live in it. Games the account owns but has not
    /// installed are not in any environment, so they are not counted.
    public static func footprint(of bottle: String, items: [LibraryItem], steamGames: [SteamGame]) -> (count: Int, bytes: Int64) {
        let steam = steamGames.filter(\.isReady)
        let others = items.filter { $0.source != .steam && $0.bottleName == bottle && $0.installed }
        return (steam.count + others.count,
                steam.reduce(Int64(0)) { $0 + $1.sizeOnDisk } + others.reduce(Int64(0)) { $0 + $1.sizeOnDisk })
    }
}

/// Which existing environment a game that needs another engine should use (highball-db#318).
/// The engine ask offers the best one before "New environment", so pressing Play again after
/// making one never makes a second. An environment holding the game comes first, then one
/// with the game's fix applied, then any other on an engine the fix accepts.
public enum EnvironmentFit {
    public struct Candidate: Equatable, Sendable {
        public let name: String
        public let holdsGame: Bool
        public let hasFix: Bool
        public init(name: String, holdsGame: Bool, hasFix: Bool) {
            self.name = name; self.holdsGame = holdsGame; self.hasFix = hasFix
        }
    }

    /// `candidates` are already on an engine the fix accepts, in the order the app lists them.
    public static func best(_ candidates: [Candidate]) -> Candidate? {
        func rank(_ c: Candidate) -> Int { c.holdsGame ? 0 : (c.hasFix ? 1 : 2) }
        return candidates.enumerated().min { a, b in
            rank(a.element) != rank(b.element) ? rank(a.element) < rank(b.element) : a.offset < b.offset
        }?.element
    }
}

/// Last-played persistence for the Continue shelf. Lives in its own library.json at the
/// Highball home — NOT in bottle.json: an Epic item's bottle is derived, dedup makes the
/// timestamp belong to the game identity, and a duplicated bottle must not duplicate play
/// history. Steam items additionally seed from the ACF's own LastPlayed, so the shelf is
/// meaningful on first run and stays right when Steam launches games without us.
public struct LibraryStore: Sendable {
    public struct PlayRecord: Codable, Sendable, Equatable {
        public var lastPlayedAt: Date
        public var bottle: String?
        public init(lastPlayedAt: Date, bottle: String?) {
            self.lastPlayedAt = lastPlayedAt; self.bottle = bottle
        }
    }
    private struct FileShape: Codable {
        var formatVersion: Int = 1
        var items: [String: PlayRecord] = [:]
        /// A graphics mode chosen for one game, by library id: the guided trial's answer (item 1,
        /// #66 and #67 were users stuck on Wine's own Direct3D for old DirectX 9 games with no way
        /// to change one game without changing the whole environment). Optional so files written
        /// before it still decode.
        var overrides: [String: Renderer]?
        /// Launch arguments the player set for one game, by library id, passed after any the
        /// database adds (highball#236: the only ways were Steam's own Launch Options or a program
        /// entry). Optional so older files still decode.
        var launchArgs: [String: [String]]?
        /// The display one game's window is moved to after it opens, by library id (display UUID
        /// string). Optional so older files still decode.
        var displays: [String: String]?
    }

    public let paths: HighballPaths
    public init(paths: HighballPaths = HighballPaths()) { self.paths = paths }

    var fileURL: URL { paths.home.appending(path: "library.json") }

    /// Tolerant load: missing or corrupt file is an empty history, never an error.
    public func load() -> [String: PlayRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let shape = try? JSONDecoder.highball.decode(FileShape.self, from: data) else { return [:] }
        return shape.items
    }

    public func rendererOverrides() -> [String: Renderer] { loadShape().overrides ?? [:] }

    /// Sets, or with nil clears, the graphics mode this one game runs with.
    public func setRendererOverride(_ renderer: Renderer?, for id: String) {
        var shape = loadShape()
        var overrides = shape.overrides ?? [:]
        overrides[id] = renderer
        shape.overrides = overrides.isEmpty ? nil : overrides
        try? paths.ensure()
        if let data = try? JSONEncoder.highball.encode(shape) { try? data.write(to: fileURL, options: .atomic) }
    }

    public func launchArguments() -> [String: [String]] { loadShape().launchArgs ?? [:] }

    /// Sets, or with an empty list clears, the launch arguments of one game.
    public func setLaunchArguments(_ args: [String], for id: String) {
        var shape = loadShape()
        var all = shape.launchArgs ?? [:]
        all[id] = args.isEmpty ? nil : args
        shape.launchArgs = all.isEmpty ? nil : all
        try? paths.ensure()
        if let data = try? JSONEncoder.highball.encode(shape) { try? data.write(to: fileURL, options: .atomic) }
    }

    public func displayChoices() -> [String: String] { loadShape().displays ?? [:] }

    /// Sets, or with nil clears, the display (CoreGraphics UUID string) one game's window moves to.
    public func setDisplay(_ uuid: String?, for id: String) {
        var shape = loadShape()
        var all = shape.displays ?? [:]
        all[id] = uuid
        shape.displays = all.isEmpty ? nil : all
        try? paths.ensure()
        if let data = try? JSONEncoder.highball.encode(shape) { try? data.write(to: fileURL, options: .atomic) }
    }

    private func loadShape() -> FileShape {
        guard let data = try? Data(contentsOf: fileURL),
              let shape = try? JSONDecoder.highball.decode(FileShape.self, from: data) else { return FileShape() }
        return shape
    }

    public func recordPlay(id: String, bottle: String?, date: Date = Date()) {
        var shape = loadShape()
        shape.items[id] = PlayRecord(lastPlayedAt: date, bottle: bottle)
        try? paths.ensure()
        if let data = try? JSONEncoder.highball.encode(shape) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Drops records whose items no longer exist (uninstalled games, deleted pins).
    public func prune(validIDs: Set<String>) {
        var whole = loadShape()
        let keptItems = whole.items.filter { validIDs.contains($0.key) }
        let keptOverrides = (whole.overrides ?? [:]).filter { validIDs.contains($0.key) }
        let keptArgs = (whole.launchArgs ?? [:]).filter { validIDs.contains($0.key) }
        let keptDisplays = (whole.displays ?? [:]).filter { validIDs.contains($0.key) }
        guard keptItems.count != whole.items.count
                || keptOverrides.count != (whole.overrides ?? [:]).count
                || keptArgs.count != (whole.launchArgs ?? [:]).count
                || keptDisplays.count != (whole.displays ?? [:]).count else { return }
        whole.items = keptItems
        whole.overrides = keptOverrides.isEmpty ? nil : keptOverrides
        whole.launchArgs = keptArgs.isEmpty ? nil : keptArgs
        whole.displays = keptDisplays.isEmpty ? nil : keptDisplays
        if let data = try? JSONEncoder.highball.encode(whole) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// User-chosen cover art (Phase 3): a local image per library item, overriding the store's
/// artwork. Pure files under covers/ at the Highball home — no API, no keys; the automatic
/// pipeline (SteamGridDB) stays a deliberate non-feature until its ToS/key story is decided.
public struct CoverStore: Sendable {
    public let paths: HighballPaths
    public init(paths: HighballPaths = HighballPaths()) { self.paths = paths }

    var dir: URL { paths.home.appending(path: "covers", directoryHint: .isDirectory) }

    /// Item ids contain ':'; filenames must not. Deterministic and collision-safe for our
    /// id shapes (bottle names already reject path characters — issue #12).
    static func filename(for id: String) -> String {
        id.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
    }

    static let extensions = ["png", "jpg", "jpeg", "heic", "webp"]

    /// The stored override for an item, if any. A program's cover is found by its own id when
    /// the environment it lives in was renamed since (PinID).
    public func coverURL(for id: String) -> URL? {
        let base = dir.appending(path: Self.filename(for: id))
        for ext in Self.extensions {
            let url = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        guard let uuid = PinID.uuid(in: id) else { return nil }
        let suffix = "_" + uuid
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { Self.extensions.contains($0.pathExtension.lowercased()) }
            .filter { $0.deletingPathExtension().lastPathComponent.hasPrefix("pin_") && $0.deletingPathExtension().lastPathComponent.hasSuffix(suffix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    /// Copies the chosen image in (replacing any previous override).
    /// The tile's aspect and the stored cover's cap. Covers are normalized at import: centre-
    /// cropped to 2:3, capped at `maxHeight` pixels tall, written as PNG, orientation applied.
    /// The crop belongs here and not to a layout: a macOS 27 beta drew nothing for a tile image
    /// of any other aspect (#64), and a 20 MB photo should not travel the library as a texture.
    public static let aspect: Double = 2.0 / 3.0
    public static let maxHeight = 900

    public func setCover(for id: String, from source: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = try Self.normalized(imageAt: source)
        clearCover(for: id)
        let dest = dir.appending(path: Self.filename(for: id)).appendingPathExtension("png")
        try png.write(to: dest, options: .atomic)
    }

    /// Same, from image bytes rather than a file. An image dragged out of a browser arrives as
    /// data with no file behind it, and refusing that would make the drop look broken (#175).
    public func setCover(for id: String, imageData: Data) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = try Self.normalized(imageData: imageData)
        clearCover(for: id)
        try png.write(to: dir.appending(path: Self.filename(for: id)).appendingPathExtension("png"), options: .atomic)
    }

    public static func normalized(imageData: Data) throws -> Data {
        guard let src = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 4096] as CFDictionary) else {
            throw HighballError.invalid("That is not an image Highball can read. Drop a PNG, JPEG or HEIC file.")
        }
        return try normalized(image)
    }

    /// The stored form of an image file: 2:3, capped, PNG. Refuses what ImageIO cannot read.
    public static func normalized(imageAt url: URL) throws -> Data {
        // A thumbnail request applies the EXIF orientation and pre-shrinks a huge photo before
        // any pixel is touched; the max size keeps the crop below at full quality for covers.
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 4096] as CFDictionary) else {
            throw HighballError.invalid("\(url.lastPathComponent) is not an image Highball can read. Choose a PNG, JPEG or HEIC file.")
        }
        return try normalized(image)
    }

    static func normalized(_ image: CGImage) throws -> Data {
        let w = image.width, h = image.height
        var cropW = w, cropH = h
        if Double(w) / Double(h) > aspect { cropW = max(1, Int((Double(h) * aspect).rounded())) }
        else { cropH = max(1, Int((Double(w) / aspect).rounded())) }
        let rect = CGRect(x: (w - cropW) / 2, y: (h - cropH) / 2, width: cropW, height: cropH)
        guard let cropped = image.cropping(to: rect) else { throw HighballError.invalid("could not crop the cover") }
        let scale = min(1, Double(maxHeight) / Double(cropped.height))
        let outW = max(1, Int((Double(cropped.width) * scale).rounded()))
        let outH = max(1, Int((Double(cropped.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw HighballError.invalid("could not prepare the cover")
        }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        let data = NSMutableData()
        guard let out = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw HighballError.invalid("could not encode the cover")
        }
        CGImageDestinationAddImage(dest, out, nil)
        guard CGImageDestinationFinalize(dest) else { throw HighballError.invalid("could not encode the cover") }
        return data as Data
    }

    /// Removes the item's override, and for a program every copy kept under an earlier name of
    /// its environment, so Reset cover really resets.
    public func clearCover(for id: String) {
        for _ in 0..<8 {
            guard let existing = coverURL(for: id) else { return }
            guard (try? FileManager.default.removeItem(at: existing)) != nil else { return }
        }
    }
}

/// A program's library id carries its environment's name ("pin:<bottle>:<uuid>"), so renaming or
/// swapping environments changes it, and the cover and name chosen for the program went missing
/// although the files were still there (highball#258, 2026-10-05). The uuid is the program's own
/// and never changes, so covers and names fall back to it when the full id finds nothing.
enum PinID {
    static func uuid(in id: String) -> String? {
        guard id.hasPrefix("pin:"), let last = id.split(separator: ":").last,
              UUID(uuidString: String(last)) != nil else { return nil }
        return String(last)
    }
}

/// The names people give library entries themselves, beside the covers they choose: a Steam
/// title in a language they do not read, a program added by hand under its file name, a game
/// they call something else (asked for on Discord, 2026-10-01). One JSON file in the home,
/// keyed by the library item's id, so a rename survives rebuilds of the library and never
/// touches the store's own title, which the database lookup and Steam itself keep using.
public struct NameStore: Sendable {
    public let paths: HighballPaths
    public init(paths: HighballPaths = HighballPaths()) { self.paths = paths }

    var file: URL { paths.home.appending(path: "names.json") }

    /// Every custom name, by item id. An unreadable file reads as no names, never as an error.
    public func names() -> [String: String] {
        guard let d = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: d)) ?? [:]
    }

    public func name(for id: String) -> String? { Self.name(for: id, in: names()) }

    /// The name for an id in a loaded table: the id itself, or for a program the name kept under
    /// an earlier name of its environment (PinID).
    public static func name(for id: String, in names: [String: String]) -> String? {
        if let exact = names[id] { return exact }
        guard let uuid = PinID.uuid(in: id) else { return nil }
        return names.filter { $0.key.hasPrefix("pin:") && $0.key.hasSuffix(":" + uuid) }.sorted { $0.key < $1.key }.first?.value
    }

    /// Sets a name, or clears it when the name is empty once trimmed: a blank is a reset, not a
    /// game called nothing.
    public func setName(_ name: String?, for id: String) throws {
        var all = names()
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A program's name kept under an earlier name of its environment goes, whether this sets
        // a new name or resets it, or the reset would show the old one again.
        if let uuid = PinID.uuid(in: id) {
            for key in all.keys where key != id && key.hasPrefix("pin:") && key.hasSuffix(":" + uuid) { all.removeValue(forKey: key) }
        }
        if trimmed.isEmpty { all.removeValue(forKey: id) } else { all[id] = trimmed }
        if all.isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(all).write(to: file, options: .atomic)
    }
}
