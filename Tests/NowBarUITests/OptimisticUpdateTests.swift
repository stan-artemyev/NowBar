import Foundation
import NowBarCore
import Testing
@testable import NowBarUI

@MainActor
@Suite("Optimistic updates")
struct OptimisticUpdateTests {
    let start = Date(timeIntervalSinceReferenceDate: 10_000)

    func harness(_ snapshot: PlayerSnapshot, now: Date? = nil) -> Harness {
        let harness = Harness()
        if let now { harness.store.now = { now } }
        harness.startAndPush(snapshot)
        return harness
    }

    // MARK: Favorite

    @Test func favoriteFlipsBeforeThePlayerAnswers() async {
        let harness = harness(Fixture.running())

        let task = harness.store.toggleFavorite()
        #expect(harness.store.snapshot.track?.isFavorited == true)   // already, before the player call finished

        await task.value
        #expect(harness.player.calls.last == "setFavorited(true)")
    }

    @Test func favoriteTogglesBackOff() async {
        let harness = harness(Fixture.running(track: Fixture.track(id: "t", favorited: true)))

        await harness.store.toggleFavorite().value
        #expect(harness.store.snapshot.track?.isFavorited == false)
        #expect(harness.player.calls.last == "setFavorited(false)")
    }

    @Test func favoriteLeavesTheRestOfTheSnapshotAlone() async {
        let harness = harness(Fixture.running(.paused, position: 42, capturedAt: start))
        let before = harness.store.snapshot

        await harness.store.toggleFavorite().value
        var expected = before
        expected.track?.isFavorited = true
        #expect(harness.store.snapshot == expected)
    }

    @Test func favoriteDoesNothingWithoutATrack() async {
        let harness = harness(.notRunning)

        await harness.store.toggleFavorite().value
        #expect(harness.player.calls == ["start"])
        #expect(harness.store.snapshot == .notRunning)
    }

    @Test func theControllersAnswerOverridesTheGuessOnceTheHoldIsOver() async {
        let clock = TestClock(start)
        let harness = Harness()
        harness.store.now = { clock.current }
        harness.startAndPush(Fixture.running())

        await harness.store.toggleFavorite().value
        #expect(harness.store.snapshot.track?.isFavorited == true)

        // Music refused (for example the track isn't in the library) and keeps saying so: for a while the guess
        // outranks it (see `FavoriteTests`), then the next push wins.
        clock.advance(by: PlayerStore.favoriteHoldDuration)
        harness.player.push(Fixture.running())
        #expect(harness.store.snapshot.track?.isFavorited == false)
    }

    // MARK: Play / pause

    @Test func pausingFreezesTheProgressWhereItIs() async {
        // Captured 10 s ago at 30 s: the bar is at 40 s when the user pauses.
        let now = start
        let harness = harness(Fixture.running(.playing, position: 30, capturedAt: now.addingTimeInterval(-10)), now: now)

        let task = harness.store.playPause()
        let snapshot = harness.store.snapshot
        #expect(snapshot.state == .paused)
        #expect(snapshot.position == 40)
        #expect(snapshot.capturedAt == now)
        #expect(snapshot.position(at: now.addingTimeInterval(60)) == 40)   // stays put

        await task.value
        #expect(harness.player.calls.last == "pause")
    }

    @Test func resumingRestartsTheClockFromNow() async {
        let now = start
        let harness = harness(Fixture.running(.paused, position: 40, capturedAt: now.addingTimeInterval(-500)), now: now)

        let task = harness.store.playPause()
        let snapshot = harness.store.snapshot
        #expect(snapshot.state == .playing)
        #expect(snapshot.position == 40)
        #expect(snapshot.capturedAt == now)
        #expect(snapshot.position(at: now.addingTimeInterval(5)) == 45)

        await task.value
        #expect(harness.player.calls.last == "play")
    }

    @Test func playPauseNeverTouchesAPlayerThatIsNotRunning() async {
        let harness = harness(.notRunning)

        await harness.store.playPause().value
        #expect(harness.player.calls == ["start"])
        #expect(harness.store.snapshot == .notRunning)
    }

    // MARK: Seek

    @Test func seekingReanchorsThePosition() async {
        let now = start
        let harness = harness(Fixture.running(.playing, position: 30, capturedAt: now.addingTimeInterval(-10)), now: now)

        let task = harness.store.seek(to: 100)
        #expect(harness.store.snapshot.position == 100)
        #expect(harness.store.snapshot.capturedAt == now)
        #expect(harness.store.snapshot.position(at: now) == 100)   // no jump back
        #expect(harness.store.snapshot.state == .playing)

        await task.value
        #expect(harness.player.calls.last == "seek(100.0)")
    }

    @Test func seekingIsClampedToTheTrack() async {
        let harness = harness(Fixture.running())   // duration 217

        await harness.store.seek(to: 9999).value
        #expect(harness.store.snapshot.position == 217)
        #expect(harness.player.calls.last == "seek(217.0)")

        await harness.store.seek(to: -5).value
        #expect(harness.store.snapshot.position == 0)
        #expect(harness.player.calls.last == "seek(0.0)")
    }

    @Test func seekingDoesNotClampWhenTheDurationIsUnknown() async {
        var live = Fixture.track
        live.duration = 0
        let harness = harness(Fixture.running(track: live))

        await harness.store.seek(to: 500).value
        #expect(harness.store.snapshot.position == 500)
    }

    @Test func seekingWithoutATrackDoesNothing() async {
        let harness = harness(PlayerSnapshot(availability: .running, state: .stopped, track: nil, position: 0))

        await harness.store.seek(to: 10).value
        #expect(harness.player.calls == ["start"])
    }

    // MARK: Skipping

    @Test func skippingForwardsToThePlayer() async {
        let harness = harness(Fixture.running())

        await harness.store.next().value
        await harness.store.previous().value
        #expect(harness.player.calls == ["start", "nextTrack", "previousTrack"])
    }
}
