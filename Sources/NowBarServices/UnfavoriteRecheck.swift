import Foundation
import NowBarCore

/// What to do when NowBar reads Music again after removing a favorite: whether to do it at all, and what the
/// reading means. Pure, so it is unit tested.
///
/// Why NowBar reads it again at all: a removal written by a script reads back as done at once, but Music only
/// schedules its favorites sync (`StoreSyncAppleMusicLoveCache`) exactly 10 seconds later, and the first sync
/// after such a removal restores the favorite. A second removal sent after that sync schedules another sync 10
/// seconds later, and that one removes the favorite for good. So `AppleMusicController` reads Music once the
/// first sync has run and, when the favorite is back, sends the removal once more.
enum UnfavoriteRecheck: Sendable, Equatable {
    /// The clicked song is the current one and Music lists it as a favorite again: send the removal once more.
    case resend
    /// The clicked song is the current one and is still not a favorite: the removal held, nothing to do.
    case held
    /// The clicked song isn't the current one any more, or Music has no song to report (it isn't running, NowBar
    /// isn't allowed to control it, or nothing is loaded): nothing to do. Whatever the user does with another song
    /// is theirs to decide.
    case trackChanged

    /// Whether a write of `favorited` that answered `result` gets a follow-up: only a removal that Music took, that
    /// is one that reached the current track (`matched`). Adding a favorite needs none, because Music applies it
    /// at once and its star turns on, and a write that matched nothing changed nothing. `result` is nil when
    /// there was no usable answer: Music wasn't ready for a script, or the script failed.
    static func isNeeded(afterWriting favorited: Bool, result: MusicFavoriteResult?) -> Bool {
        !favorited && result?.matched == true
    }

    /// `clicked` is the track the removal was requested for, and `fresh` a reading of Music taken after its sync.
    static func decide(clicked: Track, fresh: PlayerSnapshot) -> UnfavoriteRecheck {
        guard fresh.availability == .running, let current = fresh.track, isSameSong(current, clicked) else {
            return .trackChanged
        }
        return current.isFavorited ? .resend : .held
    }

    /// Whether `a` and `b` are the same song: the same ID or, because Music can give a song a new one (favoriting a
    /// streamed song adds it to the library), the same title and artist. A track without a title can't be
    /// recognised by its name. This is the rule of the `nb_favorite` script, so the follow-up applies to the
    /// track that script would have written to.
    static func isSameSong(_ a: Track, _ b: Track) -> Bool {
        a.id == b.id || (!a.title.isEmpty && a.title == b.title && a.artist == b.artist)
    }

    /// The line to log for this outcome. Only fixed words, never a title, an artist or an ID.
    var logLine: String {
        switch self {
        case .resend: return "unfavorite re-sent: Music's sync restored the favorite"
        case .held: return "unfavorite held after Music's sync"
        case .trackChanged: return "unfavorite recheck skipped: track changed"
        }
    }
}

/// The follow-up of an unfavorite that is waiting, if there is one, and the rules that keep it to one at most.
///
/// Every favorite request, an unfavorite or a favorite, begins with `begin()`, which cancels whatever is waiting
/// for an earlier one. An unfavorite that Music took then schedules its follow-up under the number `begin()` gave
/// it, and `schedule` accepts that only while no newer request has begun. That closes a race: two clicks in quick
/// succession run their scripts one after the other, so the first click's script can finish after the second
/// click has begun, and a follow-up scheduled then would remove the favorite that the second click just set.
/// `cancel()` does the same for `stop()` and for Music quitting: it also turns away the requests that are still
/// on their way to schedule something.
@MainActor
final class RecheckSlot {
    /// The number of the newest request. A request that isn't the newest can't schedule anything.
    private var newest = 0
    /// The follow-up that is waiting or running. Internal so tests can wait for it.
    private(set) var task: Task<Void, Never>?

    /// A favorite request of either kind is starting: whatever waits for an older one is obsolete. Returns the
    /// number of this request, to pass to `schedule` when its script has finished.
    func begin() -> Int {
        cancel()
        return newest
    }

    /// Cancels the follow-up that is waiting or running, and makes every request that has begun so far unable to
    /// schedule one. A follow-up that is already running has to look at `Task.isCancelled` itself.
    func cancel() {
        newest &+= 1
        task?.cancel()
        task = nil
    }

    /// Runs `work` once, `delay` from now, as the follow-up of `request`. Does nothing and returns false when a
    /// newer request has begun since `request` did, or `cancel()` has been called.
    @discardableResult
    func schedule(_ request: Int, after delay: Duration, _ work: @escaping @MainActor () async -> Void) -> Bool {
        guard request == newest else { return false }
        task?.cancel()
        task = Task {
            // A cancelled wait ends at once, and then there is nothing to do.
            do { try await Task.sleep(for: delay) } catch { return }
            await work()
        }
        return true
    }
}
