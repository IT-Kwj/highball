import Foundation

/// Presence follows the sessions Highball already tracks. It never enumerates processes.
public enum DiscordSessions {
    public static func games(_ sessions: [GameSession]) -> [DiscordRunningGame] {
        sessions.map { session in
            DiscordRunningGame(identity: session.id.uuidString, title: session.title, steamID: session.appid,
                               executable: session.markers.first { $0.lowercased().hasSuffix(".exe") },
                               started: session.started)
        }
    }

    /// Reuse a session watcher's existing `ps` snapshot, then read only matching game PIDs.
    /// The prefix check keeps similarly named games in different environments apart.
    public static func environment(for session: GameSession, prefix: URL, processList: String) -> [String: String]? {
        let root = prefix.resolvingSymlinksInPath().path
        for line in processList.split(whereSeparator: \.isNewline) {
            guard session.markers.contains(where: { line.contains($0) }), !session.excluding.contains(where: { line.contains($0) }),
                  let first = line.split(whereSeparator: \.isWhitespace).first,
                  let pid = Int32(first),
                  let command = ProcessTable.commandLineAndEnvironment(of: pid),
                  let winePrefix = command.environment["WINEPREFIX"],
                  URL(fileURLWithPath: winePrefix).resolvingSymlinksInPath().path == root else { continue }
            return command.environment
        }
        return nil
    }
}
