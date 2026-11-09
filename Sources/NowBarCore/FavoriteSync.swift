import Foundation

/// How Apple Music applies a favorite change made by a script, and the timings NowBar builds on it.
///
/// Adding a favorite is a cloud edit that takes a few seconds, and Music answers "not favorited" until it is
/// done. Removing one reads back as done at once, but Music only runs its favorites sync 10 seconds later, and
/// the first sync after a removal restores the favorite; a second removal sent after that sync sticks.
///
/// So the player controller reads Music again after an unfavorite and sends the removal once more if the
/// favorite is back, and the store keeps the star as the user set it until Music has caught up.
public enum FavoriteSync {
    /// Seconds after an unfavorite until Music is read again: its 10 second sync, plus a margin for it to finish.
    public static let recheckDelay: TimeInterval = 12
    /// Seconds after a first look that found the removal in place until the second look: the sync can run late.
    public static let secondLookDelay: TimeInterval = 13
    /// Seconds the star stays on after a favorite click, unless Music confirms sooner.
    public static let favoriteHold: TimeInterval = 10
    /// Seconds the star stays off after an unfavorite click. Longer than both looks together, so a removal that
    /// is sent again at the second look is never shown as a favorite in between.
    public static let unfavoriteHold: TimeInterval = recheckDelay + secondLookDelay + 3
}
