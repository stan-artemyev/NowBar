import Foundation

/// What the `nb_favorite` script returned: `{matched, favoritedAfter}`, two booleans. Pure, so it is unit tested.
struct MusicFavoriteResult: Sendable, Equatable {
    /// Whether the current track was the one that was clicked, by its ID or by its title and artist. When it
    /// wasn't, the script wrote nothing.
    var matched: Bool
    /// The favorite flag as Music reported it right after the write. nil when nothing was written or the flag
    /// couldn't be read. It can still be the old value for a moment: Music applies a favorite as a cloud edit that
    /// takes a few seconds, so this is what to look at when a click seems to do nothing.
    var favoritedAfter: Bool?

    init(matched: Bool, favoritedAfter: Bool?) {
        self.matched = matched
        self.favoritedAfter = matched ? favoritedAfter : nil
    }

    /// Reads the list `nb_favorite` returns. nil for anything else: `missing value` (Music wasn't running), or a
    /// value that isn't a pair starting with a boolean. A second item of another type counts as "couldn't be read".
    init?(_ value: ScriptValue) {
        guard case .list(let items) = value, items.count == 2, case .bool(let matched) = items[0] else { return nil }
        var after: Bool?
        if case .bool(let flag) = items[1] { after = flag }
        self.init(matched: matched, favoritedAfter: after)
    }

    /// The line to log. Only fixed words and booleans, never a title, an artist or an ID.
    var logLine: String {
        guard matched else { return "favorite skipped: the current track isn't the one clicked" }
        let flag = favoritedAfter.map { $0 ? "true" : "false" } ?? "unknown"
        return "favorite write: matched=true favoritedAfter=\(flag)"
    }

    /// The line to log for whatever the script returned, including an answer that can't be read.
    static func logLine(for value: ScriptValue) -> String {
        MusicFavoriteResult(value)?.logLine ?? "favorite write: no usable answer from Music"
    }
}
