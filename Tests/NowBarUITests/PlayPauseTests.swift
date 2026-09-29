import Foundation
import NowBarCore
import Testing
@testable import NowBarUI

/// The store tells the player exactly what the user wants (`play()` or `pause()`, never a toggle), ignores a
/// request that follows the last one too closely, and for a moment doesn't believe a snapshot that contradicts it.
@MainActor
@Suite("Play and pause")
struct PlayPauseTests {
    /// The store's clock, moved by hand.
    let clock = TestClock(Date(timeIntervalSinceReferenceDate: 10_000))

    func harness(_ snapshot: PlayerSnapshot) -> Harness {
        let harness = Harness()
        let clock = self.clock
        harness.store.now = { clock.current }
        harness.startAndPush(snapshot)
        return harness
    }

    // MARK: Intent

    @Test func pausesWhatIsPlaying() async {
        let harness = harness(Fixture.running(.playing))

        await harness.store.playPause().value
        #expect(harness.player.calls == ["start", "pause"])
        #expect(harness.store.snapshot.state == .paused)
    }

    @Test func playsWhatIsPaused() async {
        let harness = harness(Fixture.running(.paused))

        await harness.store.playPause().value
        #expect(harness.player.calls == ["start", "play"])
        #expect(harness.store.snapshot.state == .playing)
    }

    @Test func playsWhatIsStopped() async {
        let harness = harness(Fixture.running(.stopped))

        await harness.store.playPause().value
        #expect(harness.player.calls == ["start", "play"])
        #expect(harness.store.snapshot.state == .playing)
    }

    @Test func playsWhenNothingIsLoaded() async {
        // Music is open with nothing queued: there is nothing on screen to update, but "play" still goes out.
        let idle = PlayerSnapshot(availability: .running, state: .stopped, track: nil, position: 0)
        let harness = harness(idle)

        await harness.store.playPause().value
        #expect(harness.player.calls == ["start", "play"])
        #expect(harness.store.snapshot == idle)
    }

    // MARK: Debounce

    @Test func aSecondRequestWithinTheDebounceWindowIsIgnored() async {
        let harness = harness(Fixture.running(.playing))

        await harness.store.playPause().value   // pauses
        clock.advance(by: 0.3)
        await harness.store.playPause().value   // too soon after the first: ignored
        #expect(harness.player.calls == ["start", "pause"])
        #expect(harness.store.snapshot.state == .paused)

        clock.advance(by: 0.6)   // 0.9 s after the request that counted
        await harness.store.playPause().value
        #expect(harness.player.calls == ["start", "pause", "play"])
        #expect(harness.store.snapshot.state == .playing)
    }

    @Test func aRequestJustInsideTheWindowIsIgnored() async {
        let harness = harness(Fixture.running(.playing))

        await harness.store.playPause().value
        clock.advance(by: 0.39)
        await harness.store.playPause().value
        #expect(harness.player.calls == ["start", "pause"])
    }

    @Test func aRequestJustOutsideTheWindowGoesThrough() async {
        let harness = harness(Fixture.running(.playing))

        await harness.store.playPause().value
        clock.advance(by: 0.41)
        await harness.store.playPause().value
        #expect(harness.player.calls == ["start", "pause", "play"])
    }

    @Test func skippingIsNeverDebounced() async {
        let harness = harness(Fixture.running(.playing))

        await harness.store.next().value
        await harness.store.next().value
        await harness.store.previous().value
        await harness.store.previous().value
        #expect(harness.player.calls == ["start", "nextTrack", "nextTrack", "previousTrack", "previousTrack"])
    }

    @Test func skippingDoesNotUseUpThePlayPauseWindow() async {
        let harness = harness(Fixture.running(.playing))

        await harness.store.next().value
        await harness.store.playPause().value   // the same instant, but only play/pause requests count
        #expect(harness.player.calls == ["start", "nextTrack", "pause"])
    }

    @Test func aRequestThatWasNeverActedOnDoesNotStartTheWindow() async {
        let harness = harness(.notRunning)
        await harness.store.playPause().value   // nothing to control: not a request

        harness.player.push(Fixture.running(.paused))
        await harness.store.playPause().value   // the same instant, and it goes through
        #expect(harness.player.calls == ["start", "play"])
    }

    // MARK: Hold

    @Test func aStalePlayingSnapshotRightAfterPausingDoesNotFlipTheState() async {
        // Captured 10 s ago at 30 s: the bar is at 40 s when the user pauses.
        let harness = harness(Fixture.running(.playing, position: 30, capturedAt: clock.current.addingTimeInterval(-10)))
        await harness.store.playPause().value
        let paused = harness.store.snapshot
        #expect(paused.state == .paused)
        #expect(paused.position == 40)

        // What the player does after the request: push a reading, which can still say "playing".
        clock.advance(by: 0.1)
        harness.player.push(Fixture.running(.playing, position: 40.1, capturedAt: clock.current))
        #expect(harness.store.snapshot == paused)
        #expect(harness.store.snapshot.position(at: clock.current.addingTimeInterval(60)) == 40)   // still frozen
    }

    @Test func aStalePollRightAfterPausingIsHeldOffToo() async {
        let harness = harness(Fixture.running(.playing, position: 30, capturedAt: clock.current))
        await harness.store.playPause().value
        let paused = harness.store.snapshot

        clock.advance(by: 0.5)
        harness.player.refreshResult = Fixture.running(.playing, position: 30.5, capturedAt: clock.current)
        await harness.store.pollOnce()
        #expect(harness.store.snapshot == paused)
    }

    @Test func aStalePausedSnapshotRightAfterPlayingDoesNotFlipTheStateEither() async {
        let harness = harness(Fixture.running(.paused, position: 40, capturedAt: clock.current.addingTimeInterval(-500)))
        await harness.store.playPause().value
        let playing = harness.store.snapshot
        #expect(playing.state == .playing)

        clock.advance(by: 0.5)
        harness.player.push(Fixture.running(.paused, position: 40, capturedAt: clock.current))   // Music hasn't started yet
        #expect(harness.store.snapshot == playing)
        #expect(harness.store.snapshot.position(at: clock.current) == 40.5)   // the bar keeps moving
    }

    @Test func aHeldSnapshotStillBringsInEverythingButTheStateAndPosition() async {
        let harness = harness(Fixture.running(.playing, position: 30, capturedAt: clock.current))
        await harness.store.playPause().value

        var renamed = Fixture.track
        renamed.title = "Renamed"
        renamed.isFavorited = true
        clock.advance(by: 0.2)
        harness.player.push(Fixture.running(.playing, track: renamed, position: 30.2, capturedAt: clock.current))

        let snapshot = harness.store.snapshot
        #expect(snapshot.state == .paused)   // held
        #expect(snapshot.position == 30)     // held
        #expect(snapshot.track == renamed)   // taken from the snapshot
    }

    @Test func aContradictingSnapshotIsHeldOffUntilTheHoldExpires() async {
        let harness = harness(Fixture.running(.playing, position: 30, capturedAt: clock.current))
        await harness.store.playPause().value   // t = 0
        let paused = harness.store.snapshot

        clock.advance(by: 1.4)
        harness.player.push(Fixture.running(.playing, position: 31.4, capturedAt: clock.current))
        #expect(harness.store.snapshot == paused)   // still inside the hold

        clock.advance(by: 0.2)   // t = 1.6 s
        let later = Fixture.running(.playing, position: 31.6, capturedAt: clock.current)
        harness.player.push(later)
        #expect(harness.store.snapshot == later)   // Music never paused: the panel follows it again
    }

    @Test func aConfirmingSnapshotEndsTheHold() async {
        let harness = harness(Fixture.running(.playing, position: 30, capturedAt: clock.current))
        await harness.store.playPause().value

        clock.advance(by: 0.2)
        let confirmed = Fixture.running(.paused, position: 30.2, capturedAt: clock.current)
        harness.player.push(confirmed)
        #expect(harness.store.snapshot == confirmed)   // Music's own reading now

        // Well inside the old window the user resumes in Music itself: that is real, not stale.
        clock.advance(by: 0.3)
        let resumed = Fixture.running(.playing, position: 30.2, capturedAt: clock.current)
        harness.player.push(resumed)
        #expect(harness.store.snapshot == resumed)
    }

    @Test func aTrackChangeDuringTheHoldIsAcceptedAtOnce() async {
        let harness = harness(Fixture.running(.playing, track: Fixture.track(id: "a")))
        await harness.store.playPause().value

        // Music moved on to another track and is playing it: what the user asked for "a" no longer applies.
        clock.advance(by: 0.2)
        let next = Fixture.running(.playing, track: Fixture.track(id: "b"), position: 0, capturedAt: clock.current)
        harness.player.push(next)
        #expect(harness.store.snapshot == next)

        // Nothing is held against "b" either.
        clock.advance(by: 0.1)
        let paused = Fixture.running(.paused, track: Fixture.track(id: "b"), position: 1, capturedAt: clock.current)
        harness.player.push(paused)
        #expect(harness.store.snapshot == paused)
    }

    @Test func theTrackDisappearingEndsTheHold() async {
        let harness = harness(Fixture.running(.playing))
        await harness.store.playPause().value

        let cleared = PlayerSnapshot(availability: .running, state: .stopped, track: nil, position: 0, capturedAt: clock.current)
        harness.player.push(cleared)
        #expect(harness.store.snapshot == cleared)
    }

    @Test func theHoldEndsWhenMusicQuits() async {
        let harness = harness(Fixture.running(.playing))
        await harness.store.playPause().value

        harness.player.push(.notRunning)
        #expect(harness.store.snapshot == .notRunning)

        // Music is back and playing the same track: nothing is held against it.
        clock.advance(by: 0.2)
        harness.player.push(Fixture.running(.playing))
        #expect(harness.store.snapshot.state == .playing)
    }

    @Test func anythingButRunningEndsTheHold() async {
        let harness = harness(Fixture.running(.playing))
        await harness.store.playPause().value

        // Not something Music sends (no track goes with it), but the rule is about availability alone.
        let denied = PlayerSnapshot(availability: .notAuthorized, state: .playing, track: Fixture.track, position: 50, capturedAt: clock.current)
        harness.player.push(denied)
        #expect(harness.store.snapshot == denied)
    }

    @Test func aNewRequestReplacesTheHold() async {
        let harness = harness(Fixture.running(.playing, position: 30, capturedAt: clock.current))
        await harness.store.playPause().value   // pauses at t = 0
        clock.advance(by: 0.6)
        await harness.store.playPause().value   // plays at t = 0.6
        #expect(harness.player.calls == ["start", "pause", "play"])

        // The late answer to the pause must not undo the play.
        clock.advance(by: 0.1)
        harness.player.push(Fixture.running(.paused, position: 30, capturedAt: clock.current))
        #expect(harness.store.snapshot.state == .playing)
    }

    @Test func withoutARequestEverySnapshotIsTakenAsItComes() async {
        let harness = harness(Fixture.running(.playing))

        let paused = Fixture.running(.paused, position: 12, capturedAt: clock.current)
        harness.player.push(paused)
        #expect(harness.store.snapshot == paused)
    }
}
