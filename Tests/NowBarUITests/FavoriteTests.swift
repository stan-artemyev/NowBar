import Foundation
import NowBarCore
import Testing
@testable import NowBarUI

/// The star. The store shows a click at once and tells the player exactly what the user wants, and for which
/// track (`setFavorited(true, trackID:)` or `(false, trackID:)`, never a toggle). Music makes the change as a
/// cloud edit that takes seconds and says "not favorited" until it is done, so for a while the store doesn't
/// believe a snapshot that contradicts the click.
@MainActor
@Suite("Favorite")
struct FavoriteTests {
    /// The store's clock, moved by hand.
    let clock = TestClock(Date(timeIntervalSinceReferenceDate: 10_000))

    func harness(_ snapshot: PlayerSnapshot) -> Harness {
        let harness = Harness()
        let clock = self.clock
        harness.store.now = { clock.current }
        harness.startAndPush(snapshot)
        return harness
    }

    /// What Music says at the moment on `id`, playing at 30 s unless told otherwise.
    func music(_ state: PlaybackState = .playing, id: String = "a", favorited: Bool) -> PlayerSnapshot {
        Fixture.running(state, track: Fixture.track(id: id, favorited: favorited), position: 30, capturedAt: clock.current)
    }

    // MARK: Which track

    @Test func aFavoriteRequestNamesTheTrackOnDisplay() async {
        let harness = harness(music(id: "a", favorited: false))
        await harness.store.toggleFavorite().value
        #expect(harness.player.calls == ["start", "setFavorited(true, trackID: a)"])
    }

    @Test func anUnfavoriteRequestNamesItToo() async {
        let harness = harness(music(id: "b", favorited: true))
        await harness.store.toggleFavorite().value
        #expect(harness.player.calls == ["start", "setFavorited(false, trackID: b)"])
    }

    @Test func theRequestKeepsNamingTheTrackThatWasClickedWhenMusicMovesOnBeforeItIsSent() async {
        let harness = harness(music(id: "a", favorited: false))

        let task = harness.store.toggleFavorite()                  // the click, on "a"; the player hasn't been called yet
        harness.player.push(music(id: "b", favorited: false))      // Music changes track in the meantime
        #expect(harness.store.snapshot.track?.id == "b")
        await task.value

        // The player is told which track the click was on, so it can refuse instead of favoriting "b".
        #expect(harness.player.calls == ["start", "setFavorited(true, trackID: a)"])
        #expect(harness.store.snapshot.track?.id == "b")
        #expect(harness.store.snapshot.track?.isFavorited == false)
    }

    // MARK: Hold

    @Test func theHoldLastsTenSeconds() {
        #expect(PlayerStore.favoriteHoldDuration == 10)
    }

    @Test func aStaleAnswerRightAfterTheClickDoesNotTurnTheStarOff() async {
        let harness = harness(music(favorited: false))
        await harness.store.toggleFavorite().value
        #expect(harness.store.snapshot.track?.isFavorited == true)

        // What the controller does after the request: read the track again and push what Music still says.
        clock.advance(by: 0.3)
        harness.player.push(music(favorited: false))
        #expect(harness.store.snapshot.track?.isFavorited == true)
    }

    @Test func everyPollWhileTheCloudEditIsRunningIsHeldOffToo() async {
        let harness = harness(music(favorited: false))
        await harness.store.toggleFavorite().value

        // The panel polls every 2 s while it is open, and Music keeps saying "not favorited".
        for _ in 1...4 {
            clock.advance(by: 2)
            harness.player.refreshResult = music(favorited: false)
            await harness.store.pollOnce()
            #expect(harness.store.snapshot.track?.isFavorited == true)
        }
    }

    @Test func aHeldAnswerStillBringsInEverythingButTheStar() async {
        let harness = harness(music(favorited: false))
        await harness.store.toggleFavorite().value

        var renamed = Fixture.track(id: "a", favorited: false)
        renamed.title = "Renamed"
        clock.advance(by: 0.2)
        harness.player.push(Fixture.running(.paused, track: renamed, position: 31, capturedAt: clock.current))

        let snapshot = harness.store.snapshot
        #expect(snapshot.track?.isFavorited == true)   // held
        #expect(snapshot.track?.title == "Renamed")    // taken from the snapshot
        #expect(snapshot.state == .paused)             // and so is the rest
        #expect(snapshot.position == 31)
    }

    @Test func aConfirmingAnswerEndsTheHold() async {
        let harness = harness(music(favorited: false))
        await harness.store.toggleFavorite().value

        clock.advance(by: 3)
        harness.player.push(music(favorited: true))   // the cloud edit landed
        #expect(harness.store.snapshot.track?.isFavorited == true)

        // Well inside the old window the user unfavorites in Music itself: that is real, not stale.
        clock.advance(by: 1)
        harness.player.push(music(favorited: false))
        #expect(harness.store.snapshot.track?.isFavorited == false)
    }

    @Test func afterTenSecondsMusicsValueWins() async {
        let harness = harness(music(favorited: false))
        await harness.store.toggleFavorite().value   // t = 0

        clock.advance(by: 9.5)
        harness.player.push(music(favorited: false))
        #expect(harness.store.snapshot.track?.isFavorited == true)   // still on hold

        clock.advance(by: 0.5)   // t = 10
        harness.player.push(music(favorited: false))
        #expect(harness.store.snapshot.track?.isFavorited == false)   // Music never did it: the panel follows it again
    }

    @Test func afterTheHoldEveryAnswerIsTakenAsItComes() async {
        let harness = harness(music(favorited: false))
        await harness.store.toggleFavorite().value

        clock.advance(by: 11)
        harness.player.push(music(favorited: true))
        #expect(harness.store.snapshot.track?.isFavorited == true)
        harness.player.push(music(favorited: false))
        #expect(harness.store.snapshot.track?.isFavorited == false)
        harness.player.push(music(favorited: true))
        #expect(harness.store.snapshot.track?.isFavorited == true)
    }

    @Test func withoutAClickEveryAnswerIsTakenAsItComes() async {
        let harness = harness(music(favorited: false))

        harness.player.push(music(favorited: true))
        #expect(harness.store.snapshot.track?.isFavorited == true)
        harness.player.push(music(favorited: false))
        #expect(harness.store.snapshot.track?.isFavorited == false)
    }

    // MARK: Clicking again

    @Test func aSecondClickInsideTheHoldUnfavoritesAndTheStarTurnsOff() async {
        let harness = harness(music(favorited: false))
        await harness.store.toggleFavorite().value   // t = 0
        clock.advance(by: 1)
        harness.player.push(music(favorited: false))   // stale
        #expect(harness.store.snapshot.track?.isFavorited == true)

        // The user sees a filled star and clicks it: that is an unfavorite request, and nothing debounces it.
        await harness.store.toggleFavorite().value
        #expect(harness.player.calls == ["start", "setFavorited(true, trackID: a)", "setFavorited(false, trackID: a)"])
        #expect(harness.store.snapshot.track?.isFavorited == false)
    }

    @Test func theHoldFollowsTheSecondClick() async {
        let harness = harness(music(favorited: false))
        await harness.store.toggleFavorite().value   // t = 0: favorite, held until t = 10
        clock.advance(by: 2)
        await harness.store.toggleFavorite().value   // t = 2: unfavorite, held until t = 12

        // The first cloud edit lands: Music says "favorited". That answers the first click, not the second.
        clock.advance(by: 3)   // t = 5
        harness.player.push(music(favorited: true))
        #expect(harness.store.snapshot.track?.isFavorited == false)

        // The first hold would have run out by now; the second hasn't.
        clock.advance(by: 6)   // t = 11
        harness.player.push(music(favorited: true))
        #expect(harness.store.snapshot.track?.isFavorited == false)

        clock.advance(by: 1.5)   // t = 12.5
        harness.player.push(music(favorited: true))
        #expect(harness.store.snapshot.track?.isFavorited == true)
    }

    @Test func anAnswerThatAgreesWithTheSecondClickEndsTheHold() async {
        let harness = harness(music(favorited: false))
        await harness.store.toggleFavorite().value
        clock.advance(by: 1)
        await harness.store.toggleFavorite().value   // unfavorite

        clock.advance(by: 1)
        harness.player.push(music(favorited: false))   // Music agrees
        #expect(harness.store.snapshot.track?.isFavorited == false)

        // Nothing is held any more: the user favorites in Music itself and that is taken at once.
        clock.advance(by: 1)
        harness.player.push(music(favorited: true))
        #expect(harness.store.snapshot.track?.isFavorited == true)
    }

    // MARK: What ends the hold

    @Test func aTrackChangeEndsTheHold() async {
        let harness = harness(music(id: "a", favorited: false))
        await harness.store.toggleFavorite().value

        // Music moved on: what the user asked for "a" doesn't apply to "b", which is taken as it is.
        clock.advance(by: 1)
        harness.player.push(music(id: "b", favorited: false))
        #expect(harness.store.snapshot.track?.id == "b")
        #expect(harness.store.snapshot.track?.isFavorited == false)

        // Nothing is held against "a" any more either, well inside the old ten seconds.
        clock.advance(by: 1)
        harness.player.push(music(id: "a", favorited: false))
        #expect(harness.store.snapshot.track?.isFavorited == false)
    }

    @Test func aFavoritedTrackChangeIsTakenAsItIs() async {
        let harness = harness(music(id: "a", favorited: false))
        await harness.store.toggleFavorite().value

        clock.advance(by: 1)
        harness.player.push(music(id: "b", favorited: true))   // "b" already was a favorite
        #expect(harness.store.snapshot.track?.isFavorited == true)

        clock.advance(by: 1)
        harness.player.push(music(id: "b", favorited: false))   // and the user removed it in Music
        #expect(harness.store.snapshot.track?.isFavorited == false)
    }

    @Test func theTrackDisappearingEndsTheHold() async {
        let harness = harness(music(favorited: false))
        await harness.store.toggleFavorite().value

        let idle = PlayerSnapshot(availability: .running, state: .stopped, track: nil, position: 0, capturedAt: clock.current)
        clock.advance(by: 1)
        harness.player.push(idle)
        #expect(harness.store.snapshot == idle)

        clock.advance(by: 1)
        harness.player.push(music(favorited: false))
        #expect(harness.store.snapshot.track?.isFavorited == false)
    }

    @Test func musicQuittingEndsTheHold() async {
        let harness = harness(music(favorited: false))
        await harness.store.toggleFavorite().value

        harness.player.push(.notRunning)
        #expect(harness.store.snapshot == .notRunning)

        // Music is back with the same track, and nothing is held against it.
        clock.advance(by: 1)
        harness.player.push(music(favorited: false))
        #expect(harness.store.snapshot.track?.isFavorited == false)
    }

    @Test func anythingButRunningEndsTheHold() async {
        let harness = harness(music(favorited: false))
        await harness.store.toggleFavorite().value

        // Not something Music sends with a track, but the rule is about availability alone.
        let denied = PlayerSnapshot(
            availability: .notAuthorized, state: .playing, track: Fixture.track(id: "a", favorited: false),
            position: 50, capturedAt: clock.current
        )
        harness.player.push(denied)
        #expect(harness.store.snapshot == denied)

        clock.advance(by: 1)
        harness.player.push(music(favorited: false))
        #expect(harness.store.snapshot.track?.isFavorited == false)
    }

    // MARK: Alongside the play/pause hold

    @Test func bothHoldsCanBeActiveAtOnce() async {
        let harness = harness(music(.playing, favorited: false))
        await harness.store.playPause().value        // pauses: held for 1.5 s
        await harness.store.toggleFavorite().value   // favorites: held for 10 s
        let requested = harness.store.snapshot
        #expect(requested.state == .paused)
        #expect(requested.track?.isFavorited == true)

        // One stale reading contradicts both requests at once.
        clock.advance(by: 0.2)
        harness.player.push(music(.playing, favorited: false))
        #expect(harness.store.snapshot == requested)
    }

    @Test func confirmingThePauseLeavesTheStarOnHold() async {
        let harness = harness(music(.playing, favorited: false))
        await harness.store.playPause().value
        await harness.store.toggleFavorite().value

        clock.advance(by: 0.5)
        harness.player.push(music(.paused, favorited: false))   // Music paused; the star is still on its way
        #expect(harness.store.snapshot.state == .paused)
        #expect(harness.store.snapshot.track?.isFavorited == true)

        // The pause hold ended with its confirmation: playing again in Music itself is real, not stale.
        clock.advance(by: 0.5)
        harness.player.push(music(.playing, favorited: false))
        #expect(harness.store.snapshot.state == .playing)
        #expect(harness.store.snapshot.track?.isFavorited == true)   // the star hold carries on
    }

    @Test func confirmingTheStarLeavesThePauseOnHold() async {
        let harness = harness(music(.playing, favorited: false))
        await harness.store.playPause().value
        await harness.store.toggleFavorite().value

        clock.advance(by: 0.5)
        harness.player.push(music(.playing, favorited: true))   // the cloud edit landed; the pause hasn't yet
        #expect(harness.store.snapshot.track?.isFavorited == true)
        #expect(harness.store.snapshot.state == .paused)

        // The star hold ended with its confirmation: unfavoriting in Music itself is real, not stale.
        clock.advance(by: 0.5)
        harness.player.push(music(.playing, favorited: false))
        #expect(harness.store.snapshot.track?.isFavorited == false)
        #expect(harness.store.snapshot.state == .paused)   // the pause hold carries on
    }

    @Test func eachHoldRunsOutOnItsOwn() async {
        let harness = harness(music(.playing, favorited: false))
        await harness.store.playPause().value
        await harness.store.toggleFavorite().value

        // The pause was held for 1.5 s, the star for 10 s.
        clock.advance(by: 2)
        harness.player.push(music(.playing, favorited: false))
        #expect(harness.store.snapshot.state == .playing)                // Music is believed about playback again
        #expect(harness.store.snapshot.track?.isFavorited == true)       // but not yet about the star

        clock.advance(by: 9)   // t = 11
        harness.player.push(music(.playing, favorited: false))
        #expect(harness.store.snapshot.track?.isFavorited == false)
    }

    @Test func aTrackChangeEndsBothHolds() async {
        let harness = harness(music(.playing, id: "a", favorited: false))
        await harness.store.playPause().value
        await harness.store.toggleFavorite().value

        clock.advance(by: 0.2)
        let next = music(.playing, id: "b", favorited: false)
        harness.player.push(next)
        #expect(harness.store.snapshot == next)

        // Nothing is held against "a" when it comes back a moment later.
        clock.advance(by: 0.2)
        let back = music(.playing, id: "a", favorited: false)
        harness.player.push(back)
        #expect(harness.store.snapshot == back)
    }
}
