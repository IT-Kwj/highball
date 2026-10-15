import Foundation

/// Keeps Steam's registry keys visible to 32-bit lookups in an environment whose user hive has a
/// `Software\Wow6432Node` key (Red Dead Redemption 2 stopping with Rockstar launcher error 113,
/// found and fixed by a player, crêpe on Discord, 2026-10-13).
///
/// Windows shares HKCU\Software between the 32-bit and 64-bit registry views. Wine treats it as
/// redirected as soon as any `HKCU\Software\Wow6432Node` key exists, and a lookup in the 32-bit
/// view then goes into that subtree, where Steam's keys are not. The Rockstar Games Launcher
/// reads HKCU\Software\Valve that way, concludes Steam is not running and stops with error 113
/// (LAUNCHER_ERR_STEAM_FAILED). Measured on the default Wine 10 engine (r26) and the Wine 11
/// engine (r23): with a `Wow6432Node\Probe` key present, `reg query HKCU\Software\Valve\Steam
/// /reg:32` fails, and a registry link from `Wow6432Node\Valve` to `Software\Valve` brings it
/// back and survives the server saving the hive again. In the reported environment the subtree
/// came from an early Wine 11 engine's first boot (r7, 2026-09-29); moving a Wine 10 environment
/// to r8 or r23 does not create it, but anything that writes such a key does.
///
/// The link goes into user.reg, so the repair runs only while no wineserver holds the
/// environment, and only when the hive has the subtree, has Steam's keys and has no
/// `Wow6432Node\Valve` of its own. It appends and never rewrites what is there.
public enum SteamRegistryView {
    /// The current user's key as Wine names it (the fixed SID of Wine's server/token.c).
    static let userKey = #"\REGISTRY\User\S-1-5-21-0-0-0-1000"#

    /// The text to append to a user.reg, or nil when the hive needs nothing.
    static func linkBlock(for hive: String, now: Date = Date()) -> String? {
        let subtree = hive.contains("\n[Software\\\\Wow6432Node]") || hive.contains("\n[Software\\\\Wow6432Node\\\\")
        guard subtree, hive.contains("\n[Software\\\\Valve"),
              !hive.contains("\n[Software\\\\Wow6432Node\\\\Valve]") else { return nil }
        let target = userKey + #"\Software\Valve"#
        let hex = target.utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
            .map { String(format: "%02x", $0) }.joined(separator: ",")
        let lead = hive.hasSuffix("\n") ? "\n" : "\n\n"
        return lead + "[Software\\\\Wow6432Node\\\\Valve] \(Int(now.timeIntervalSince1970))\n#link\n\"SymbolicLinkValue\"=hex(6):\(hex)\n"
    }

    /// Links the key in a stopped environment. True when it changed the hive.
    @discardableResult
    public static func repair(prefix: URL) throws -> Bool {
        guard ProcessTable.liveServer(forPrefix: prefix) == nil else { return false }
        let hive = prefix.appending(path: "user.reg")
        guard let data = try? Data(contentsOf: hive),
              let block = linkBlock(for: String(decoding: data, as: UTF8.self)) else { return false }
        let handle = try FileHandle(forWritingTo: hive)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(block.utf8))
        return true
    }
}
