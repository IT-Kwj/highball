import Darwin
import Foundation

/// A Steam game installed in one environment, handed to a new environment's Steam as an APFS clone (2026-10-18).
/// Moving to an engine of the other architecture needs a new environment (an environment never moves between
/// Rosetta and native engines), and that environment used to start empty: Microsoft Flight Simulator 2024's first
/// outside tester downloaded the game again, about 50 GB, to try the native arm64 engine. A clone shares every
/// block with the original until either side writes, so the copy costs no disk and no time, and the original stays
/// exactly as it was. The Steam record (appmanifest) goes beside it, so the new environment's Steam finds the game
/// installed and only fetches what an update changed.
public enum SteamGameCarryOver {
    public enum Outcome: Equatable, Sendable {
        case carried
        /// Why nothing was written, for the log. The new environment's Steam then installs the game as before.
        case skipped(String)
    }

    /// Whether `game` can come along to a new environment made under `bottlesRoot`: fully installed, its folder
    /// there, and on the same volume, which a clone needs (a library on an external drive is not copied in full).
    /// A game with an update waiting comes along too, and the new environment's Steam downloads only the update,
    /// where 0.10.19 and 0.10.20 left it behind and the new environment downloaded the whole game.
    public static func canCarry(_ game: SteamGame, toBottlesRoot bottlesRoot: URL) -> Bool {
        guard game.isFullyInstalled, let folder = game.installFolder?.resolvingSymlinksInPath(),
              FileManager.default.fileExists(atPath: folder.path) else { return false }
        return sameVolume(folder, bottlesRoot)
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let va = (try? a.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject,
              let vb = (try? b.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject else { return false }
        return va.isEqual(vb)
    }

    /// Clones the game's folder into `common/<installdir>` under `destSteamapps` and copies its appmanifest beside
    /// it, the record last, so a Steam that looks never finds a record before its files. Nothing stays behind when
    /// anything is in the way: a source not fully installed, files or record missing, the game already in the new
    /// environment, or a clone the file system refuses (another volume, not APFS). A source folder that is a link to
    /// another environment's copy is resolved first: the new environment gets files of its own, never a second
    /// Steam on a shared folder (a cloned Steam once downgraded a shared Forza Horizon 6 install, 2026-10-06).
    public static func carry(_ game: SteamGame, into destSteamapps: URL,
                             clone: (URL, URL) throws -> Void = SteamGameCarryOver.cloneTree) -> Outcome {
        guard game.isFullyInstalled else { return .skipped("it is not fully installed there (Steam state \(game.stateFlags))") }
        guard let root = game.libraryRoot, let folder = game.installFolder?.resolvingSymlinksInPath() else {
            return .skipped("its install folder is unknown")
        }
        let record = root.appending(path: "steamapps/appmanifest_\(game.appid).acf")
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path), fm.fileExists(atPath: record.path) else {
            return .skipped("its files or its Steam record are missing")
        }
        let destFolder = destSteamapps.appending(path: "common/\(game.installdir)", directoryHint: .isDirectory)
        let destRecord = destSteamapps.appending(path: "appmanifest_\(game.appid).acf")
        guard !fm.fileExists(atPath: destFolder.path), !fm.fileExists(atPath: destRecord.path) else {
            return .skipped("the new environment has it already")
        }
        do {
            try fm.createDirectory(at: destFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
            try clone(folder, destFolder)
        } catch {
            try? fm.removeItem(at: destFolder)
            return .skipped("its folder could not be cloned (\(error.localizedDescription))")
        }
        do {
            try fm.copyItem(at: record, to: destRecord)
        } catch {
            try? fm.removeItem(at: destFolder)
            return .skipped("its Steam record could not be copied (\(error.localizedDescription))")
        }
        return .carried
    }

    /// clonefile(2): the whole tree in one call, every block shared with the source until either side writes. It
    /// refuses across volumes (EXDEV) and off APFS, which is what keeps a carry-over from ever being a full copy.
    public static func cloneTree(_ source: URL, _ destination: URL) throws {
        guard clonefile(source.path, destination.path, UInt32(CLONE_NOOWNERCOPY)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
