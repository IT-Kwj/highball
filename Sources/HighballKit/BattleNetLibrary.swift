import Foundation

/// A game Battle.net installed in an environment, read from Battle.net's own records in
/// `ProgramData/Battle.net/Agent` (highball#417): `product.db`, where the update agent keeps one
/// install record per product, and `aggregate.json`, the client's list of what it shows as
/// installed. Nothing here names a game: titles, folders and launchers all come from those files.
public struct BattleNetGame: Sendable, Hashable {
    /// Blizzard's product code, the install record's second field ("pro", "wow", "hsb"). The key
    /// everything joins on: the uid beside it varies ("prometheus", "hs_beta") and the client's
    /// own list keys on the code too.
    public let productCode: String
    public let uid: String
    /// The client's own name for the game when its list has it, else the install folder's name,
    /// which Battle.net names after the game.
    public let title: String
    /// The install folder as Battle.net wrote it ("C:/Program Files (x86)/Overwatch").
    public let installPath: String
    /// The same folder on the Mac.
    public let folder: URL
    /// The game's own Battle.net launcher in its folder ("Overwatch Launcher.exe"), what the
    /// desktop and Start menu shortcuts Battle.net creates point at. nil when there is none.
    public let launcher: URL?
    public let version: String
    /// The installed build's size as the agent recorded it when the download completed, 0 unknown.
    public let sizeOnDisk: Int64
    public let lastPlayed: Date?
    /// The client's box art for the game, when its list carries one.
    public let boxArt: URL?

    public init(productCode: String, uid: String, title: String, installPath: String, folder: URL, launcher: URL?,
                version: String = "", sizeOnDisk: Int64 = 0, lastPlayed: Date? = nil, boxArt: URL? = nil) {
        self.productCode = productCode; self.uid = uid; self.title = title; self.installPath = installPath
        self.folder = folder; self.launcher = launcher; self.version = version; self.sizeOnDisk = sizeOnDisk
        self.lastPlayed = lastPlayed; self.boxArt = boxArt
    }

    /// The library id, "battlenet:<product code>": one tile per game, whatever environment holds it.
    public var libraryID: String { "battlenet:\(productCode)" }
}

public enum BattleNetLibrary {
    /// Battle.net's own products, the update agent and the client. Every record that is not one of
    /// them is a game or a game's edition.
    static let clientProducts: Set<String> = ["agent", "bna"]

    /// Where the update agent keeps its records. The install watcher follows this folder: the agent
    /// rewrites product.db when an install, update or removal ends.
    public static func agentDirectory(of bottle: Bottle) -> URL {
        bottle.driveC.appending(path: "ProgramData/Battle.net/Agent", directoryHint: .isDirectory)
    }

    /// The games Battle.net has installed in a bottle: records the agent marks installed and
    /// playable whose folder is there. A game still downloading, or one whose folder was deleted
    /// behind Battle.net's back, is left out. Empty for a bottle without Battle.net.
    public static func games(in bottle: Bottle) -> [BattleNetGame] {
        let agent = agentDirectory(of: bottle)
        guard let db = try? Data(contentsOf: agent.appending(path: "product.db")),
              let installs = try? ProductDB.installs(in: db) else { return [] }
        let aggregate = (try? Data(contentsOf: agent.appending(path: "aggregate.json"))).map(Aggregate.entries) ?? [:]
        return games(installs: installs, aggregate: aggregate, bottle: bottle)
    }

    static func games(installs: [ProductDB.Install], aggregate: [String: Aggregate.Entry], bottle: Bottle) -> [BattleNetGame] {
        let fm = FileManager.default
        var games: [BattleNetGame] = []
        for install in installs {
            let code = install.productCode
            guard !code.isEmpty, !clientProducts.contains(code.lowercased()), install.installed, install.playable,
                  !install.installPath.isEmpty, !games.contains(where: { $0.productCode == code }),
                  let folder = macURL(forWindowsPath: install.installPath, in: bottle) else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let listed = aggregate[code]
            let folderName = folder.lastPathComponent
            let title = listed?.name ?? (folderName.isEmpty ? code : folderName)
            games.append(BattleNetGame(
                productCode: code, uid: install.uid, title: title, installPath: install.installPath, folder: folder,
                launcher: launcher(listed: listed?.iconPath, folder: folder, bottle: bottle),
                version: install.version, sizeOnDisk: install.totalBytes, lastPlayed: listed?.lastPlayed,
                boxArt: listed?.boxArt))
        }
        // Two editions in one folder (World of Warcraft and its Classic share it) would read alike
        // when the client's list does not name them: the product code tells them apart.
        let titles = Dictionary(grouping: games, by: { $0.title.lowercased() })
        return games.map { game in
            guard (titles[game.title.lowercased()]?.count ?? 0) > 1 else { return game }
            return BattleNetGame(productCode: game.productCode, uid: game.uid, title: "\(game.title) (\(game.productCode))",
                                 installPath: game.installPath, folder: game.folder, launcher: game.launcher,
                                 version: game.version, sizeOnDisk: game.sizeOnDisk, lastPlayed: game.lastPlayed, boxArt: game.boxArt)
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// The game's own launcher: the one the client's list names, else the one file in the game's
    /// folder whose name ends in " Launcher.exe", the name Blizzard gives every game's launcher.
    static func launcher(listed: String?, folder: URL, bottle: Bottle) -> URL? {
        let fm = FileManager.default
        if let listed, listed.lowercased().hasSuffix(".exe"), let url = macURL(forWindowsPath: listed, in: bottle),
           fm.fileExists(atPath: url.path) { return url }
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        let launchers = names.filter { $0.lowercased().hasSuffix(" launcher.exe") }
        return launchers.count == 1 ? folder.appending(path: launchers[0]) : nil
    }

    /// The Battle.net client itself, from the client's own install record, at the default folder
    /// when that record is missing. nil when neither holds the client.
    public static func client(in bottle: Bottle) -> URL? {
        let agent = agentDirectory(of: bottle)
        let recorded = (try? Data(contentsOf: agent.appending(path: "product.db")))
            .flatMap { try? ProductDB.installs(in: $0) }?
            .first { $0.productCode.lowercased() == "bna" }
            .flatMap { macURL(forWindowsPath: $0.installPath, in: bottle) }
        let folders = [recorded, bottle.driveC.appending(path: "Program Files (x86)/Battle.net", directoryHint: .isDirectory)].compactMap { $0 }
        for folder in folders {
            for name in ["Battle.net Launcher.exe", "Battle.net.exe"] where FileManager.default.fileExists(atPath: folder.appending(path: name).path) {
                return folder.appending(path: name)
            }
        }
        return nil
    }

    /// How Play starts a game, the way Battle.net's own shortcut does: the game's launcher with
    /// `--productcode=<code>`, the argument Blizzard's shortcuts pass it to pick the edition (one
    /// launcher serves World of Warcraft and its Classic). The launcher opens Battle.net, or hands
    /// over to a running one, which then starts the game. Without a launcher, Battle.net opens and
    /// its Play button starts the game.
    public struct Launch: Equatable, Sendable {
        public let executable: URL
        public let arguments: [String]
        /// True when this only opens Battle.net, so the player presses Play there.
        public let throughClient: Bool
    }

    public static func launch(_ game: BattleNetGame, client: URL?) -> Launch? {
        if let launcher = game.launcher {
            return Launch(executable: launcher, arguments: ["--productcode=\(game.productCode)"], throughClient: false)
        }
        return client.map { Launch(executable: $0, arguments: [], throughClient: true) }
    }

    /// What tells a running game apart in `ps`: its folder, in the two spellings Wine's command
    /// lines use, as for Steam games. The launcher in that folder exits once Battle.net has the
    /// request, so it is not the game.
    public static func sessionMarkers(for game: BattleNetGame) -> (markers: [String], excluding: [String]) {
        var windows = game.installPath.replacingOccurrences(of: "/", with: "\\")
        if windows.count >= 2, windows.dropFirst().first == ":" { windows = String(windows.dropFirst(2)) }
        if !windows.hasPrefix("\\") { windows = "\\" + windows }
        if !windows.hasSuffix("\\") { windows += "\\" }
        let unix = game.folder.path.hasSuffix("/") ? game.folder.path : game.folder.path + "/"
        return ([windows, unix], game.launcher.map { [$0.lastPathComponent] } ?? [])
    }

    /// A Windows path as Battle.net writes it ("C:/Program Files (x86)/Overwatch", either slash) on
    /// the Mac. C: is the bottle's drive_c; any other letter is the environment's link for it (a
    /// drive the player added, Z: for the Mac's own root). nil for a path without a drive letter.
    static func macURL(forWindowsPath path: String, in bottle: Bottle) -> URL? {
        let p = path.replacingOccurrences(of: "\\", with: "/")
        guard p.count >= 2, p.dropFirst().first == ":", let letter = p.first?.lowercased(), letter.count == 1,
              letter.first!.isLetter else { return nil }
        let rest = String(p.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let drive = letter == "c" ? bottle.driveC
            : bottle.url.appending(path: "dosdevices/\(letter):", directoryHint: .isDirectory).resolvingSymlinksInPath()
        return rest.isEmpty ? drive : drive.appending(path: rest)
    }
}

/// The client's list of installed games (`Agent/aggregate.json`): name, launcher, box art and last
/// play per product code. It can list a game before its download ends, so product.db decides what
/// is installed and this only adds what that file lacks.
enum Aggregate {
    struct Entry: Equatable {
        var name: String?
        var iconPath: String?
        var boxArt: URL?
        var lastPlayed: Date?
    }

    static func entries(_ data: Data) -> [String: Entry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let installed = root["installed"] as? [[String: Any]] else { return [:] }
        var out: [String: Entry] = [:]
        for item in installed {
            guard let code = item["product_id"] as? String, !code.isEmpty else { continue }
            let name = (item["name"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            let art = (item["box_art_uri"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
            // Milliseconds since 1970; 0 for never played.
            let played = (item["last_played_timestamp"] as? NSNumber).map(\.doubleValue).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
            out[code] = Entry(name: name, iconPath: item["icon_path"] as? String, boxArt: art, lastPlayed: played)
        }
        return out
    }
}

/// The few fields Highball needs from the update agent's `product.db`, a protocol buffer: a list of
/// install records (field 1), each with uid (1), product code (2), settings (3: install path 1)
/// and cached state (4: base state 1 with installed 1, playable 2, version 7; update progress 4
/// with the build's total bytes 4). The layout is the one Battle.net has used for years and the
/// open readers (Lutris, the GOG Galaxy plugin) document. Fields not listed are skipped by wire
/// type, so fields the agent adds later change nothing.
enum ProductDB {
    struct Install: Equatable {
        var uid = ""
        var productCode = ""
        var installPath = ""
        var installed = false
        var playable = false
        var version = ""
        var totalBytes: Int64 = 0
    }

    static func installs(in data: Data) throws -> [Install] {
        try Protobuf.fields(in: [UInt8](data)).compactMap { field, value in
            guard field == 1, case .bytes(let record) = value else { return nil }
            return try install(record)
        }
    }

    private static func install(_ bytes: [UInt8]) throws -> Install {
        var install = Install()
        for (field, value) in try Protobuf.fields(in: bytes) {
            switch (field, value) {
            case (1, .bytes(let b)): install.uid = String(decoding: b, as: UTF8.self)
            case (2, .bytes(let b)): install.productCode = String(decoding: b, as: UTF8.self)
            case (3, .bytes(let settings)):
                for case (1, .bytes(let b)) in try Protobuf.fields(in: settings) { install.installPath = String(decoding: b, as: UTF8.self) }
            case (4, .bytes(let cached)):
                for (f, v) in try Protobuf.fields(in: cached) {
                    switch (f, v) {
                    case (1, .bytes(let base)):
                        for (g, w) in try Protobuf.fields(in: base) {
                            switch (g, w) {
                            case (1, .varint(let n)): install.installed = n != 0
                            case (2, .varint(let n)): install.playable = n != 0
                            case (7, .bytes(let b)): install.version = String(decoding: b, as: UTF8.self)
                            default: break
                            }
                        }
                    case (4, .bytes(let progress)):
                        for case (4, .varint(let n)) in try Protobuf.fields(in: progress) { install.totalBytes = Int64(clamping: n) }
                    default: break
                    }
                }
            default: break
            }
        }
        return install
    }
}

/// A minimal protocol buffer wire-format reader: the fields of one message, in order, without a
/// schema. Groups (wire types 3 and 4, long deprecated) and anything cut short are an error.
enum Protobuf {
    enum Value: Equatable {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes([UInt8])
        case fixed32(UInt32)
    }

    struct Malformed: Error {}

    static func fields(in bytes: [UInt8]) throws -> [(Int, Value)] {
        var out: [(Int, Value)] = []
        var i = 0
        func varint() throws -> UInt64 {
            var result: UInt64 = 0, shift: UInt64 = 0
            while true {
                guard i < bytes.count, shift < 64 else { throw Malformed() }
                let b = bytes[i]; i += 1
                result |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
            }
        }
        func take(_ n: Int) throws -> [UInt8] {
            guard n >= 0, n <= bytes.count - i else { throw Malformed() }
            defer { i += n }
            return Array(bytes[i..<i + n])
        }
        while i < bytes.count {
            let key = try varint()
            let field = Int(key >> 3)
            guard field > 0 else { throw Malformed() }
            switch key & 7 {
            case 0: out.append((field, .varint(try varint())))
            case 1: out.append((field, .fixed64(try take(8).reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) })))
            case 2:
                let n = try varint()
                guard n <= UInt64(Int.max) else { throw Malformed() }
                out.append((field, .bytes(try take(Int(n)))))
            case 5: out.append((field, .fixed32(try take(4).reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) })))
            default: throw Malformed()
            }
        }
        return out
    }
}
