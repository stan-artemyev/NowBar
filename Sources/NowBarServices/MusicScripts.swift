import NowBarCore

/// The AppleScript that talks to Music. Every handler:
/// - does nothing unless Music is already running, so a script can never launch it, and
/// - runs inside `with timeout of 3 seconds`, so an unresponsive Music can't stall the script queue for two minutes.
///
/// The terms come from Music's own scripting dictionary (`player state`, `current track`, `persistent ID`,
/// `favorited`, `raw data`, `play`, `pause`, `next track`, `back track`).
enum MusicScripts {
    // Failures that mean "stop now" (Music quit, isn't answering, or we aren't allowed) are re-raised so one
    // timeout doesn't turn into one timeout per property. Any other failure only leaves that property empty:
    // a radio stream has no duration, for example.
    private static let helpers = """
    on nb_rethrow(errMsg, errNum)
        if errNum is in {-1743, -1744, -1712, -609, -600, -10004} then error errMsg number errNum
    end nb_rethrow

    """

    /// `nb_query()` -> {state, persistent ID, name, artist, album, duration, player position, favorited},
    /// with `missing value` for anything unavailable, or `missing value` alone when Music isn't running.
    /// State is `player state as text`: "playing", "paused", "stopped", "fast forwarding" or "rewinding".
    /// A stopped player is not asked for its track.
    static let query = helpers + """
    on nb_query()
        with timeout of 3 seconds
            if application id "\(MusicApp.bundleIdentifier)" is running then
                tell application id "\(MusicApp.bundleIdentifier)"
                    set stateText to (player state as text)
                    set trackID to missing value
                    set trackName to missing value
                    set trackArtist to missing value
                    set trackAlbum to missing value
                    set trackDuration to missing value
                    set trackPosition to missing value
                    set trackFavorited to missing value
                    if stateText is not "stopped" then
                        try
                            set t to current track
                            try
                                set trackID to persistent ID of t
                            on error errMsg number errNum
                                my nb_rethrow(errMsg, errNum)
                            end try
                            try
                                set trackName to name of t
                            on error errMsg number errNum
                                my nb_rethrow(errMsg, errNum)
                            end try
                            try
                                set trackArtist to artist of t
                            on error errMsg number errNum
                                my nb_rethrow(errMsg, errNum)
                            end try
                            try
                                set trackAlbum to album of t
                            on error errMsg number errNum
                                my nb_rethrow(errMsg, errNum)
                            end try
                            try
                                set trackDuration to duration of t
                            on error errMsg number errNum
                                my nb_rethrow(errMsg, errNum)
                            end try
                            try
                                set trackFavorited to favorited of t
                            on error errMsg number errNum
                                my nb_rethrow(errMsg, errNum)
                            end try
                            try
                                set trackPosition to player position
                            on error errMsg number errNum
                                my nb_rethrow(errMsg, errNum)
                            end try
                        on error errMsg number errNum
                            my nb_rethrow(errMsg, errNum)
                        end try
                    end if
                    return {stateText, trackID, trackName, trackArtist, trackAlbum, trackDuration, trackPosition, trackFavorited}
                end tell
            end if
        end timeout
        return missing value
    end nb_query
    """

    /// `nb_artwork(expectedID)` -> the image bytes of the current track's first artwork, or `missing value`
    /// when the current track is no longer `expectedID` or has no artwork. The ID check and the read happen
    /// in the same script, so the track can't change in between.
    static let artwork = helpers + """
    on nb_artwork(expectedID)
        with timeout of 3 seconds
            if application id "\(MusicApp.bundleIdentifier)" is running then
                tell application id "\(MusicApp.bundleIdentifier)"
                    set t to current track
                    if (persistent ID of t) is not expectedID then return missing value
                    try
                        return (raw data of artwork 1 of t)
                    on error errMsg number errNum
                        my nb_rethrow(errMsg, errNum)
                    end try
                    try
                        return (data of artwork 1 of t)
                    on error errMsg number errNum
                        my nb_rethrow(errMsg, errNum)
                    end try
                end tell
            end if
        end timeout
        return missing value
    end nb_artwork
    """

    /// The transport and favorite commands. Positions, flags and track IDs arrive as typed arguments.
    ///
    /// Play and pause are two commands, never Music's `playpause` toggle: a repeated or late toggle flips
    /// playback back, while `play` while playing and `pause` while paused change nothing.
    ///
    /// `nb_favorite(shouldFavorite, expectedID)` only touches the current track if its persistent ID is
    /// `expectedID`, so a click that races a track change never favorites the next song.
    static let control = """
    on nb_play()
        with timeout of 3 seconds
            if application id "\(MusicApp.bundleIdentifier)" is running then
                tell application id "\(MusicApp.bundleIdentifier)"
                    -- Only when not already playing, so a stale request can never restart the track.
                    if player state is not playing then play
                end tell
            end if
        end timeout
    end nb_play

    on nb_pause()
        with timeout of 3 seconds
            if application id "\(MusicApp.bundleIdentifier)" is running then
                tell application id "\(MusicApp.bundleIdentifier)" to pause
            end if
        end timeout
    end nb_pause

    on nb_next()
        with timeout of 3 seconds
            if application id "\(MusicApp.bundleIdentifier)" is running then
                tell application id "\(MusicApp.bundleIdentifier)" to next track
            end if
        end timeout
    end nb_next

    on nb_previous()
        with timeout of 3 seconds
            if application id "\(MusicApp.bundleIdentifier)" is running then
                tell application id "\(MusicApp.bundleIdentifier)" to back track
            end if
        end timeout
    end nb_previous

    on nb_seek(targetSeconds)
        with timeout of 3 seconds
            if application id "\(MusicApp.bundleIdentifier)" is running then
                tell application id "\(MusicApp.bundleIdentifier)" to set player position to targetSeconds
            end if
        end timeout
    end nb_seek

    on nb_favorite(shouldFavorite, expectedID)
        with timeout of 3 seconds
            if application id "\(MusicApp.bundleIdentifier)" is running then
                tell application id "\(MusicApp.bundleIdentifier)"
                    -- Only the track the user clicked on. The ID check and the write use the same track
                    -- reference, so a track change in between can't redirect the write to the next song.
                    set t to current track
                    if (persistent ID of t) is expectedID then set favorited of t to shouldFavorite
                end tell
            end if
        end timeout
    end nb_favorite
    """
}
