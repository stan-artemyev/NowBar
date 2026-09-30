import Foundation
import NowBarCore
import Testing
@testable import NowBarUI

/// The star. The store shows a click at once and tells the player exactly what the user wants, and for which
/// track (`setFavorited(true, track:)` or `(false, track:)`, never a toggle). Music makes the change as a
/// cloud edit that takes seconds and says "not favorited" until it is done, so for a while the store doesn't
/// believe a snapshot that contradicts the click. Removing a favorite is held longer and differently: Music says
/// "not favorited" at once, but its favorites sync 10 seconds later restores the favorite (see "Unfavorite hold").
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

    /// A track with a title and an artist of its own. Two tracks are the same song when they have the same `song`
    /// (their ID unless told otherwise), whatever their IDs: the hold recognises a song by its ID or by its title
    /// and artist, so tracks with different IDs must not share those unless a test means them to.
    func track(id: String, song: String? = nil, favorited: Bool) -> Track {
        let name = song ?? id
        return Fixture.track(id: id, title: "Song \(name)", artist: "Artist \(name)", favorited: favorited)
    }

    /// What Music says at the moment on `id`, playing at 30 s unless told otherwise. `song` names the song under
    /// another ID: `music(id: "a2", song: "a", …)` is song "a" after Music has given it a new ID.
    func music(_ state: PlaybackState = .playing, id: String = "a", song: String? = nil, favorited: Bool) -> PlayerSnapshot {
        Fixture.running(state, track: track(id: id, song: song, favorited: favorited), position: 30, capturedAt: clock.current)
    }

    // MARK: Which track

    @Test func aFavoriteRequestNamesTheTrackOnDisplay() async {
        let harness = harness(music(id: "a", favorited: false))
        await harness.store.toggleFavorite().value
        #expect(harness.player.calls == ["start", "setFavorited(true, track: a)"])
    }

    @Test func anUnfavoriteRequestNamesItToo() async {
        let harness = harness(music(id: "b", favorited: true))
        await harness.store.toggleFavorite().value
        #expect(harness.player.calls == ["start", "setFavorited(false, track: b)"])
    }

    @Test func theRequestCarriesTheWholeTrackOnDisplay() async {
        // Music can give a song a new ID when favoriting adds it to the library, so the player also gets the title
        // and artist to recognise it by.
        let shown = Fixture.track(id: "a", title: "Midnight Circuit", artist: "Neon Harbor", favorited: false)
        let harness = harness(Fixture.running(.playing, track: shown, position: 30, capturedAt: clock.current))

        await harness.store.toggleFavorite().value
        #expect(harness.player.favoriteRequests.count == 1)
        let request = harness.player.favoriteRequests.first
        #expect(request?.favorited == true)
        #expect(request?.track.id == "a")
        #expect(request?.track.title == "Midnight Circuit")
        #expect(request?.track.artist == "Neon Harbor")
    }

    @Test func anUnfavoriteRequestCarriesTheWholeTrackToo() async {
        let shown = Fixture.track(id: "b", title: "Paper Satellites", artist: "The Quiet Radios", favorited: true)
        let harness = harness(Fixture.running(.paused, track: shown, position: 30, capturedAt: clock.current))

        await harness.store.toggleFavorite().value
        #expect(harness.player.favoriteRequests.count == 1)
        let request = harness.player.favoriteRequests.first
        #expect(request?.favorited == false)
        #expect(request?.track.id == "b")
        #expect(request?.track.title == "Paper Satellites")
        #expect(request?.track.artist == "The Quiet Radios")
    }

    @Test func theRequestKeepsNamingTheTrackThatWasClickedWhenMusicMovesOnBeforeItIsSent() async {
        let clicked = Fixture.track(id: "a", title: "Clicked Song", artist: "Clicked Artist", favorited: false)
        let next = Fixture.track(id: "b", title: "Next Song", artist: "Next Artist", favorited: false)
        let harness = harness(Fixture.running(.playing, track: clicked, position: 30, capturedAt: clock.current))

        let task = harness.store.toggleFavorite()                  // the click, on "a"; the player hasn't been called yet
        harness.player.push(Fixture.running(.playing, track: next, position: 0, capturedAt: clock.current))   // Music changes track in the meantime
        #expect(harness.store.snapshot.track?.id == "b")
        await task.value

        // The player is told which track the click was on (its ID, title and artist), so it can refuse instead of
        // favoriting "b".
        #expect(harness.player.calls == ["start", "setFavorited(true, track: a)"])
        #expect(harness.player.favoriteRequests.first?.track.title == "Clicked Song")
        #expect(harness.player.favoriteRequests.first?.track.artist == "Clicked Artist")
        #expect(harness.store.snapshot.track?.id == "b")
        #expect(harness.store.snapshot.track?.isFavorited == false)
    }

    // MARK: Favorite hold

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

    // MARK: Unfavorite hold
    //
    // Music reads "not favorited" back as soon as a removal is written, but only runs its favorites sync 10 s later,
    // and the first sync after a removal restores the favorite. `AppleMusicController` then sends the removal once
    // more, which takes effect with the sync after that, some 22 s after the click. The star stays off through all
    // of it, so an answer that agrees with the click doesn't end the hold.

    /// A store that has just been told to unfavorite song "a" (t = 0): the star is off, held until t = 25.
    func harnessAfterAnUnfavorite(id: String = "a") async -> Harness {
        let harness = harness(music(id: id, favorited: true))
        await harness.store.toggleFavorite().value
        return harness
    }

    @Test func theUnfavoriteHoldLastsTwentyFiveSeconds() {
        #expect(PlayerStore.unfavoriteHoldDuration == 25)
        // Long enough for both syncs: the first at 10 s, then the resend at 12 s and the sync 10 s after it.
        #expect(PlayerStore.unfavoriteHoldDuration > 12 + 10)
    }

    @Test func anUnfavoriteTurnsTheStarOffAtOnce() async {
        let harness = harness(music(favorited: true))
        let task = harness.store.toggleFavorite()
        #expect(harness.store.snapshot.track?.isFavorited == false)   // before the player call has finished
        await task.value
        #expect(harness.player.calls == ["start", "setFavorited(false, track: a)"])
    }

    @Test func anAgreeingAnswerDoesNotEndTheHoldSoTheRestoredFavoriteNeverShows() async {
        let harness = await harnessAfterAnUnfavorite()   // t = 0

        // What the controller does after the write: read the track again. Music already says "not favorited".
        clock.advance(by: 0.3)
        harness.player.push(music(favorited: false))
        #expect(harness.store.snapshot.track?.isFavorited == false)

        // t = 10: Music's favorites sync runs, and the first sync after a removal restores the favorite.
        clock.advance(by: 9.7)
        harness.player.push(music(favorited: true))
        #expect(harness.store.snapshot.track?.isFavorited == false)   // the star stays off

        // The panel polls every 2 s, and Music keeps saying "favorited" until the resend's sync (t = 22).
        for _ in 1...6 {
            clock.advance(by: 2)
            harness.player.refreshResult = music(favorited: true)
            await harness.store.pollOnce()
            #expect(harness.store.snapshot.track?.isFavorited == false)
        }
        harness.player.push(music(favorited: false))   // t = 22: the removal has taken effect
        #expect(harness.store.snapshot.track?.isFavorited == false)
    }

    @Test func aHeldUnfavoriteStillBringsInEverythingButTheStar() async {
        let harness = await harnessAfterAnUnfavorite()

        var renamed = track(id: "a", favorited: true)
        renamed.title = "Renamed"
        clock.advance(by: 10)
        harness.player.push(Fixture.running(.paused, track: renamed, position: 40, capturedAt: clock.current))

        let snapshot = harness.store.snapshot
        #expect(snapshot.track?.isFavorited == false)   // held
        #expect(snapshot.track?.title == "Renamed")     // taken from the snapshot
        #expect(snapshot.state == .paused)              // and so is the rest
        #expect(snapshot.position == 40)
    }

    @Test func afterTwentyFiveSecondsMusicsValueWins() async {
        let harness = await harnessAfterAnUnfavorite()   // t = 0

        clock.advance(by: 24.5)
        harness.player.push(music(favorited: true))
        #expect(harness.store.snapshot.track?.isFavorited == false)   // still on hold

        clock.advance(by: 0.5)   // t = 25
        harness.player.push(music(favorited: true))
        #expect(harness.store.snapshot.track?.isFavorited == true)    // Music never removed it: the panel follows it again
    }

    @Test func afterTheUnfavoriteHoldEveryAnswerIsTakenAsItComes() async {
        let harness = await harnessAfterAnUnfavorite()

        clock.advance(by: 26)
        harness.player.push(music(favorited: true))
        #expect(harness.store.snapshot.track?.isFavorited == true)
        harness.player.push(music(favorited: false))
        #expect(harness.store.snapshot.track?.isFavorited == false)
        harness.player.push(music(favorited: true))
        #expect(harness.store.snapshot.track?.isFavorited == true)
    }

    @Test func aFavoriteHoldStillEndsWhenMusicAgrees() async {
        // The difference between the two kinds, side by side: the same agreeing answer, then the opposite one.
        let favorite = harness(music(favorited: false))
        await favorite.store.toggleFavorite().value
        clock.advance(by: 1)
        favorite.player.push(music(favorited: true))
        clock.advance(by: 1)
        favorite.player.push(music(favorited: false))
        #expect(favorite.store.snapshot.track?.isFavorited == false)   // ended: Music is believed again

        let unfavorite = await harnessAfterAnUnfavorite()
        clock.advance(by: 1)
        unfavorite.player.push(music(favorited: false))
        clock.advance(by: 1)
        unfavorite.player.push(music(favorited: true))
        #expect(unfavorite.store.snapshot.track?.isFavorited == false)   // not ended: still held
    }

    // MARK: The same song
    //
    // Music can give a song a new ID (favoriting a streamed song adds it to the library), so a hold recognises the song
    // it was made on by its ID or by its title and artist, as the `nb_favorite` script does.

    @Test func aReidentifiedSongKeepsAnUnfavoriteHold() async {
        let harness = await harnessAfterAnUnfavorite()   // song "a", t = 0

        clock.advance(by: 1)
        harness.player.push(music(id: "a2", song: "a", favorited: false))   // Music agrees, under a new ID
        #expect(harness.store.snapshot.track?.id == "a2")
        #expect(harness.store.snapshot.track?.isFavorited == false)

        clock.advance(by: 9)
        harness.player.push(music(id: "a2", song: "a", favorited: true))    // the sync restores the favorite
        #expect(harness.store.snapshot.track?.id == "a2")
        #expect(harness.store.snapshot.track?.isFavorited == false)         // still held
    }

    @Test func aReidentifiedSongKeepsAFavoriteHoldToo() async {
        let harness = harness(music(id: "a", favorited: false))
        await harness.store.toggleFavorite().value   // favorite song "a"

        // Favoriting a streamed song adds it to the library under a new ID, and Music still says "not favorited".
        clock.advance(by: 1)
        harness.player.push(music(id: "a2", song: "a", favorited: false))
        #expect(harness.store.snapshot.track?.id == "a2")
        #expect(harness.store.snapshot.track?.isFavorited == true)   // held

        clock.advance(by: 2)
        harness.player.push(music(id: "a2", song: "a", favorited: true))   // the cloud edit landed: that ends the hold
        #expect(harness.store.snapshot.track?.isFavorited == true)
        clock.advance(by: 1)
        harness.player.push(music(id: "a2", song: "a", favorited: false))
        #expect(harness.store.snapshot.track?.isFavorited == false)
    }

    @Test func theHoldKeepsRecognisingTheSongThroughFurtherNewIDs() async {
        let harness = await harnessAfterAnUnfavorite()

        clock.advance(by: 1)
        harness.player.push(music(id: "a2", song: "a", favorited: true))
        #expect(harness.store.snapshot.track?.isFavorited == false)
        clock.advance(by: 1)
        harness.player.push(music(id: "a3", song: "a", favorited: true))
        #expect(harness.store.snapshot.track?.isFavorited == false)
        clock.advance(by: 1)
        harness.player.push(music(id: "a", song: "a", favorited: true))   // and the original ID again
        #expect(harness.store.snapshot.track?.isFavorited == false)
    }

    @Test func aDifferentSongEndsAnUnfavoriteHold() async {
        let harness = await harnessAfterAnUnfavorite()

        clock.advance(by: 1)
        harness.player.push(music(id: "b", favorited: true))   // "b" is a favorite of its own
        #expect(harness.store.snapshot.track?.id == "b")
        #expect(harness.store.snapshot.track?.isFavorited == true)

        // Nothing is held against "a" when it comes back a moment later, well inside the 25 s.
        clock.advance(by: 1)
        harness.player.push(music(id: "a", favorited: true))
        #expect(harness.store.snapshot.track?.isFavorited == true)
    }

    @Test func aSongWithTheSameTitleByAnotherArtistIsAnotherSong() async {
        let harness = harness(Fixture.running(.playing, track: Fixture.track(id: "a", title: "Echoes", artist: "First Band", favorited: true), position: 30, capturedAt: clock.current))
        await harness.store.toggleFavorite().value   // unfavorite "Echoes" by "First Band"

        clock.advance(by: 1)
        let cover = Fixture.track(id: "b", title: "Echoes", artist: "Second Band", favorited: true)
        harness.player.push(Fixture.running(.playing, track: cover, position: 0, capturedAt: clock.current))
        #expect(harness.store.snapshot.track?.id == "b")
        #expect(harness.store.snapshot.track?.isFavorited == true)   // not held: another song
    }

    @Test func aSongByTheSameArtistWithAnotherTitleIsAnotherSong() async {
        let harness = harness(Fixture.running(.playing, track: Fixture.track(id: "a", title: "Echoes", artist: "First Band", favorited: true), position: 30, capturedAt: clock.current))
        await harness.store.toggleFavorite().value

        clock.advance(by: 1)
        let next = Fixture.track(id: "b", title: "Shadows", artist: "First Band", favorited: true)
        harness.player.push(Fixture.running(.playing, track: next, position: 0, capturedAt: clock.current))
        #expect(harness.store.snapshot.track?.isFavorited == true)
    }

    @Test func aTrackWithoutATitleIsNotRecognisedByItsName() async {
        // Two untitled tracks by the same artist are not the same song; only an equal ID makes them one.
        let untitled = Fixture.track(id: "a", title: "", artist: "First Band", favorited: true)
        let harness = harness(Fixture.running(.playing, track: untitled, position: 30, capturedAt: clock.current))
        await harness.store.toggleFavorite().value

        clock.advance(by: 1)
        let other = Fixture.track(id: "b", title: "", artist: "First Band", favorited: true)
        harness.player.push(Fixture.running(.playing, track: other, position: 0, capturedAt: clock.current))
        #expect(harness.store.snapshot.track?.id == "b")
        #expect(harness.store.snapshot.track?.isFavorited == true)   // not held

        // The hold ended with that, so even the original ID isn't held any more.
        clock.advance(by: 1)
        harness.player.push(Fixture.running(.playing, track: untitled, position: 0, capturedAt: clock.current))
        #expect(harness.store.snapshot.track?.isFavorited == true)
    }

    @Test func theSameIDIsTheSameSongWhateverItIsCalled() async {
        // The hold was made on the track as it was clicked; the metadata changed underneath it.
        let harness = await harnessAfterAnUnfavorite()

        clock.advance(by: 1)
        let edited = Fixture.track(id: "a", title: "A Better Title", artist: "Another Artist", favorited: true)
        harness.player.push(Fixture.running(.playing, track: edited, position: 30, capturedAt: clock.current))
        #expect(harness.store.snapshot.track?.title == "A Better Title")
        #expect(harness.store.snapshot.track?.isFavorited == false)   // still held
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
        #expect(harness.player.calls == ["start", "setFavorited(true, track: a)", "setFavorited(false, track: a)"])
        #expect(harness.store.snapshot.track?.isFavorited == false)
    }

    @Test func theHoldFollowsTheSecondClick() async {
        let harness = harness(music(favorited: false))
        await harness.store.toggleFavorite().value   // t = 0: favorite, held until t = 10
        clock.advance(by: 2)
        await harness.store.toggleFavorite().value   // t = 2: unfavorite, held until t = 27

        // The first cloud edit lands: Music says "favorited". That answers the first click, not the second.
        clock.advance(by: 3)   // t = 5
        harness.player.push(music(favorited: true))
        #expect(harness.store.snapshot.track?.isFavorited == false)

        // The first hold would have run out by now; the second hasn't.
        clock.advance(by: 6)   // t = 11
        harness.player.push(music(favorited: true))
        #expect(harness.store.snapshot.track?.isFavorited == false)

        // And it lasts as long as an unfavorite hold does, counted from the second click.
        clock.advance(by: 15.5)   // t = 26.5
        harness.player.push(music(favorited: true))
        #expect(harness.store.snapshot.track?.isFavorited == false)

        clock.advance(by: 1)   // t = 27.5
        harness.player.push(music(favorited: true))
        #expect(harness.store.snapshot.track?.isFavorited == true)
    }

    @Test func aFavoriteClickAfterAnUnfavoriteHoldsAsAFavoriteDoes() async {
        let harness = harness(music(favorited: true))
        await harness.store.toggleFavorite().value   // t = 0: unfavorite, held until t = 25
        clock.advance(by: 1)
        harness.player.push(music(favorited: false))
        #expect(harness.store.snapshot.track?.isFavorited == false)

        // The user sees an empty star and clicks it: a favorite request, on its own terms (10 s, ended by Music agreeing).
        await harness.store.toggleFavorite().value   // t = 1
        #expect(harness.player.calls == ["start", "setFavorited(false, track: a)", "setFavorited(true, track: a)"])
        #expect(harness.store.snapshot.track?.isFavorited == true)

        clock.advance(by: 1)
        harness.player.push(music(favorited: false))   // stale: the unfavorite is still on its way out
        #expect(harness.store.snapshot.track?.isFavorited == true)
        clock.advance(by: 1)
        harness.player.push(music(favorited: true))    // the cloud edit landed: that ends the hold
        #expect(harness.store.snapshot.track?.isFavorited == true)

        // Nothing is held any more, and the old unfavorite hold is gone with the click that replaced it.
        clock.advance(by: 1)
        harness.player.push(music(favorited: false))
        #expect(harness.store.snapshot.track?.isFavorited == false)
    }

    @Test func aNewUnfavoriteAfterTheHoldRanOutStartsAFreshHold() async {
        let harness = await harnessAfterAnUnfavorite()   // t = 0: held until t = 25
        clock.advance(by: 26)
        harness.player.push(music(favorited: true))      // Music never removed it, and the hold is over
        #expect(harness.store.snapshot.track?.isFavorited == true)

        await harness.store.toggleFavorite().value       // t = 26: unfavorite again, held until t = 51
        #expect(harness.player.calls == ["start", "setFavorited(false, track: a)", "setFavorited(false, track: a)"])
        #expect(harness.store.snapshot.track?.isFavorited == false)

        clock.advance(by: 24)   // t = 50
        harness.player.push(music(favorited: true))
        #expect(harness.store.snapshot.track?.isFavorited == false)
        clock.advance(by: 1)    // t = 51
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

    @Test func theTrackDisappearingEndsAnUnfavoriteHold() async {
        let harness = await harnessAfterAnUnfavorite()

        let idle = PlayerSnapshot(availability: .running, state: .stopped, track: nil, position: 0, capturedAt: clock.current)
        clock.advance(by: 1)
        harness.player.push(idle)
        #expect(harness.store.snapshot == idle)

        // Nothing is held against the song when it is back, well inside the 25 s.
        clock.advance(by: 1)
        harness.player.push(music(favorited: true))
        #expect(harness.store.snapshot.track?.isFavorited == true)
    }

    @Test func musicQuittingEndsAnUnfavoriteHold() async {
        let harness = await harnessAfterAnUnfavorite()

        harness.player.push(.notRunning)
        #expect(harness.store.snapshot == .notRunning)

        clock.advance(by: 1)
        harness.player.push(music(favorited: true))
        #expect(harness.store.snapshot.track?.isFavorited == true)
    }

    @Test func anythingButRunningEndsAnUnfavoriteHold() async {
        let harness = await harnessAfterAnUnfavorite()

        // Not something Music sends with a track, but the rule is about availability alone.
        let denied = PlayerSnapshot(
            availability: .notAuthorized, state: .playing, track: track(id: "a", favorited: true),
            position: 50, capturedAt: clock.current
        )
        harness.player.push(denied)
        #expect(harness.store.snapshot == denied)

        clock.advance(by: 1)
        harness.player.push(music(favorited: true))
        #expect(harness.store.snapshot.track?.isFavorited == true)
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
