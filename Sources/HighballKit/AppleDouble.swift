import Foundation

/// macOS keeps a file's extended attributes in a `._name` file beside it on a volume with no native
/// place for them (exFAT, FAT, some network shares), and Windows programs take those files for their
/// own. GStreamer tried to load an engine's `._libgst*.dylib` files as plugins (a player with
/// Highball's home on a non-APFS drive, on Discord, 2026-10-11). Alice: Madness Returns failed on the
/// 4,407 beside its files in a Steam library on an exFAT drive until they were deleted, and a
/// reinstall brought them all back (highball-db#429).
public enum AppleDouble {
    /// True when the volume holding `url` keeps extended attributes in `._` files: it reports native
    /// extended attributes as a capability it knows of and lacks. Measured 2026-10-23 on a disk image:
    /// exFAT reports it valid and off, APFS valid and on, and a value written to a file on the exFAT
    /// volume appeared as `._name` beside it.
    public static func volumeKeepsTwins(_ url: URL) -> Bool {
        var fs = statfs()
        guard statfs(url.path, &fs) == 0 else { return false }
        // Volume attributes are only answered for the volume's root.
        let mount = withUnsafePointer(to: fs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_CAPABILITIES)
        var reply = VolumeCapabilities()
        guard getattrlist(mount, &request, &reply, MemoryLayout<VolumeCapabilities>.size, 0) == 0 else { return false }
        let bit = UInt32(VOL_CAP_INT_EXTENDED_ATTR)
        // Element 1 of each set is VOL_CAPABILITIES_INTERFACES.
        return reply.caps.valid.1 & bit != 0 && reply.caps.capabilities.1 & bit == 0
    }

    /// getattrlist's reply to ATTR_VOL_CAPABILITIES alone: its length, then the capability sets.
    private struct VolumeCapabilities {
        var length: UInt32 = 0
        var caps = vol_capabilities_attr_t()
    }

    /// A game's folder before its launch: on a volume that keeps `._` files, each one beside a file
    /// of the game goes. A folder on APFS is not walked at all. Returns how many went.
    public static func cleanGameFolder(_ folder: URL) -> Int {
        guard volumeKeepsTwins(folder) else { return 0 }
        return removeTwins(in: folder, recursive: true)
    }

    /// Removes each `._name` whose `name` sits beside it, nothing else, and returns how many went.
    /// A walk asks the file system nothing beyond its directory listings: a game folder can hold
    /// tens of thousands of files, and this runs before every launch from such a drive.
    @discardableResult
    public static func removeTwins(in dir: URL, recursive: Bool) -> Int {
        let fm = FileManager.default
        var removed = 0
        func clean(_ folder: URL) {
            // readdir, not FileManager: Foundation's directory listing leaves `._` files out.
            guard let entries = rawEntries(in: folder) else { return }
            let present = Set(entries.map(\.name))
            for (name, _) in entries where name.hasPrefix("._") && present.contains(String(name.dropFirst(2))) {
                if (try? fm.removeItem(at: folder.appending(path: name))) != nil { removed += 1 }
            }
            guard recursive else { return }
            for (name, type) in entries where !name.hasPrefix("._") {
                let child = folder.appending(path: name)
                switch Int32(type) {
                case DT_DIR:
                    clean(child)
                case DT_UNKNOWN:
                    let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if values?.isDirectory == true, values?.isSymbolicLink != true { clean(child) }
                default:
                    continue   // files, and links, which are never followed
                }
            }
        }
        clean(dir)
        return removed
    }

    /// Every entry of a directory as the file system lists it, `.` and `..` aside.
    static func rawNames(in dir: URL) -> [String]? { rawEntries(in: dir)?.map(\.name) }

    /// The same with each entry's type as the listing gives it (DT_DIR, DT_REG, DT_LNK, or
    /// DT_UNKNOWN from a file system that does not say).
    static func rawEntries(in dir: URL) -> [(name: String, type: UInt8)]? {
        guard let handle = opendir(dir.path) else { return nil }
        defer { closedir(handle) }
        var entries: [(name: String, type: UInt8)] = []
        while let entry = readdir(handle) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name != "." && name != ".." { entries.append((name, entry.pointee.d_type)) }
        }
        return entries
    }
}
