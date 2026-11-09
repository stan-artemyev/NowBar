import Foundation
import NowBarCore

/// The play/pause and favorite requests the player hasn't caught up with yet, and what they do to its readings.
///
/// Music can still answer "playing" for a moment after it was told to pause, and its favorites lag by seconds
/// (see `FavoriteSync`), so a reading taken after a request can contradict what the user just did, and the panel
/// would flip back. While a request is on hold, a reading of the same song that contradicts it is treated as
/// stale: the fields the request set stay as they are displayed, and everything else comes from the reading.
///
/// A hold ends when the song or the availability changes (whatever the user asked for no longer applies), when
/// its time runs out (Music didn't do it, and the panel goes back to what Music says), and when a newer request
/// of its kind replaces it. A reading that confirms the request ends a play/pause or a favorite hold, but not an
/// unfavorite hold: Music says "not favorited" from the moment of the write, and can still restore the favorite
/// with its sync. The two kinds are independent, and each only touches its own fields.
///
/// A value with no clock of its own, so it is unit tested through the store with a fake one.
struct RequestHolds {
    /// How many seconds after a play/pause request a reading that contradicts it is treated as stale.
    static let playbackDuration: TimeInterval = 1.5

    private struct Hold<Target: Equatable> {
        /// What the request asked for.
        var target: Target
        /// The song it was made on (see `Track.isSameSong(as:)`).
        var track: Track
        /// When the request stops outranking readings.
        var until: Date
        var endsWhenConfirmed = true
    }

    private var playback: Hold<PlaybackState>?
    private var favorite: Hold<Bool>?

    mutating func holdPlayback(_ target: PlaybackState, on track: Track, from moment: Date) {
        playback = Hold(target: target, track: track, until: moment.addingTimeInterval(Self.playbackDuration))
    }

    mutating func holdFavorite(_ target: Bool, on track: Track, from moment: Date) {
        let duration = target ? FavoriteSync.favoriteHold : FavoriteSync.unfavoriteHold
        favorite = Hold(target: target, track: track, until: moment.addingTimeInterval(duration), endsWhenConfirmed: target)
    }

    /// `incoming` as the panel should show it: the fields a hold protects stay as they are in `displayed` (the
    /// snapshot on screen, which the request already changed), and the rest is new.
    mutating func reconcile(_ incoming: PlayerSnapshot, displayed: PlayerSnapshot, now: Date) -> PlayerSnapshot {
        var result = incoming
        if Self.target(of: &playback, overruling: incoming, now: now, where: { $0.state }) != nil {
            result.state = displayed.state
            result.position = displayed.position
            result.capturedAt = displayed.capturedAt
        }
        if let favorited = Self.target(of: &favorite, overruling: incoming, now: now, where: { $0.track?.isFavorited }) {
            result.track?.isFavorited = favorited
        }
        return result
    }

    /// What `hold` asked for, when it still applies to `incoming` and `incoming` says something else; nil otherwise.
    /// Ends the hold when it no longer applies, and when `incoming` confirms it (unless it outlasts that).
    private static func target<Target: Equatable>(
        of hold: inout Hold<Target>?,
        overruling incoming: PlayerSnapshot,
        now: Date,
        where reading: (PlayerSnapshot) -> Target?
    ) -> Target? {
        guard let active = hold else { return nil }
        guard now < active.until, incoming.availability == .running,
              let track = incoming.track, track.isSameSong(as: active.track) else {
            hold = nil
            return nil
        }
        guard reading(incoming) != active.target else {
            if active.endsWhenConfirmed { hold = nil }
            return nil
        }
        return active.target
    }
}
