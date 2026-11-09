import NowBarCore

/// The AppleScript that talks to Music. Every handler is built by `handler(_:returnsValue:_:)`, so it:
/// - does nothing unless Music is already running, so a script can never launch it, and
/// - runs inside `with timeout of 3 seconds`, so an unresponsive Music can't stall the script queue for two minutes.
///
/// The terms come from Music's own scripting dictionary (`player state`, `current track`, `persistent ID`,
/// `favorited`, `raw data`, `play`, `pause`, `next track`, `back track`). The variables avoid every one of them:
/// `matched`, for one, is one of Music's cloud status values, so inside a `tell` it can't serve as a variable name.
enum MusicScripts {
    // MARK: Scripts

    /// `nb_query()` -> {state, persistent ID, name, artist, album, duration, player position, favorited}: the
    /// state, then `trackReads` in order, which is the order `MusicRawFields` reads them in. Anything unavailable
    /// is `missing value`, and so is the whole answer when Music isn't running. State is `player state as text`:
    /// "playing", "paused", "stopped", "fast forwarding" or "rewinding". A stopped player is not asked for its track.
    static let query = helpers + handler("nb_query()", returnsValue: true, lines(
        "set stateText to (player state as text)",
        lines(trackReads.map { "set \($0.variable) to missing value" }),
        "if stateText is not \"stopped\" then",
        indented(attempt(lines(
            "set t to current track",
            lines(trackReads.map { attempt("set \($0.variable) to \($0.property)") })
        ))),
        "end if",
        "return {stateText, \(trackReads.map(\.variable).joined(separator: ", "))}"
    ))

    /// `nb_artwork(expectedID)` -> the image bytes of the current track's first artwork, or `missing value`
    /// when the current track is no longer `expectedID` or has no artwork. The ID check and the read happen
    /// in the same script, so the track can't change in between.
    static let artwork = helpers + handler("nb_artwork(expectedID)", returnsValue: true, lines(
        "set t to current track",
        "if (persistent ID of t) is not expectedID then return missing value",
        attempt("return (raw data of artwork 1 of t)"),
        attempt("return (data of artwork 1 of t)")
    ))

    /// The transport and favorite commands. Positions, flags and the clicked track's ID, name and artist arrive as
    /// typed arguments, never as text spliced into the script.
    ///
    /// Play and pause are two commands, never Music's `playpause` toggle: a repeated or late toggle flips
    /// playback back, while `play` while playing and `pause` while paused change nothing.
    ///
    /// `nb_favorite(shouldFavorite, expectedID, expectedName, expectedArtist)` only writes if the current track is
    /// the one that was clicked (`Track.isSameSong(as:)`: its persistent ID, or its name and artist), so a click
    /// that races a track change never favorites the next song. It returns `{matched, favoritedAfter}`: whether the
    /// track was recognised, and the favorite flag as Music reports it right after the write (`missing value` when
    /// nothing was written). Like the other handlers it returns `missing value` alone when Music isn't running.
    static let control = helpers + [
        handler("nb_play()", lines(
            "-- Only when not already playing, so a stale request can never restart the track.",
            "if player state is not playing then play"
        )),
        handler("nb_pause()", "pause"),
        handler("nb_next()", "next track"),
        handler("nb_previous()", "back track"),
        handler("nb_seek(targetSeconds)", "set player position to targetSeconds"),
        handler("nb_favorite(shouldFavorite, expectedID, expectedName, expectedArtist)", returnsValue: true, lines(
            "-- Each property is read in a try of its own, so one that can't be read (or a current track that",
            "-- doesn't exist) is just no match, and an ID that can't be read doesn't rule out the name.",
            "set isClicked to false",
            attempt("if (persistent ID of current track) is expectedID then set isClicked to true"),
            "if (not isClicked) and (expectedName is not \"\") then",
            indented(attempt(
                "if ((name of current track) is expectedName) and ((artist of current track) is expectedArtist) then set isClicked to true"
            )),
            "end if",
            "if not isClicked then return {false, missing value}",
            "-- The write is the one that works when typed by hand, on the current track itself.",
            "set favorited of current track to shouldFavorite",
            "-- What Music says right after the write. It can still say the old value for a moment.",
            "set favoritedAfter to missing value",
            attempt("set favoritedAfter to favorited of current track"),
            "return {true, favoritedAfter}"
        )),
    ].joined(separator: "\n\n")

    // MARK: Building blocks

    /// What `nb_query` reads about the current track, in the order it returns them after the state. `MusicRawFields`
    /// reads the answer by position, so the two must change together.
    private static let trackReads: [(variable: String, property: String)] = [
        ("trackID", "persistent ID of t"),
        ("trackName", "name of t"),
        ("trackArtist", "artist of t"),
        ("trackAlbum", "album of t"),
        ("trackDuration", "duration of t"),
        ("trackPosition", "player position"),
        ("trackFavorited", "favorited of t"),
    ]

    // Failures that mean "stop now" (Music quit, isn't answering, or we aren't allowed) are re-raised so one
    // timeout doesn't turn into one timeout per property. Any other failure only leaves that property empty:
    // a radio stream has no duration, for example.
    private static let helpers = """
    on nb_rethrow(errMsg, errNum)
        if errNum is in {-1743, -1744, -1712, -609, -600, -10004} then error errMsg number errNum
    end nb_rethrow


    """

    /// A handler whose `body`, statements addressed to Music, only runs while Music is running and within the
    /// timeout. One that returns a value answers `missing value` when Music isn't running.
    private static func handler(_ signature: String, returnsValue: Bool = false, _ body: String) -> String {
        let music = "application id \"\(MusicApp.bundleIdentifier)\""
        return lines(
            "on \(signature)",
            indented(lines(
                "with timeout of 3 seconds",
                indented(lines(
                    "if \(music) is running then",
                    indented(lines("tell \(music)", indented(body), "end tell")),
                    "end if"
                )),
                "end timeout"
            )),
            returnsValue ? indented("return missing value") : nil,
            "end \(signature.prefix { $0 != "(" })"
        )
    }

    /// `statements` in a `try` that swallows every failure except the ones `nb_rethrow` re-raises.
    private static func attempt(_ statements: String) -> String {
        lines(
            "try",
            indented(statements),
            "on error errMsg number errNum",
            indented("my nb_rethrow(errMsg, errNum)"),
            "end try"
        )
    }

    private static func lines(_ parts: String?...) -> String {
        lines(parts.compactMap { $0 })
    }

    private static func lines(_ parts: [String]) -> String {
        parts.joined(separator: "\n")
    }

    private static func indented(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
    }
}
