import Foundation
import Testing
import NowBarCore
@testable import NowBarServices

/// What NowBar does when it reads Music again after removing a favorite (`UnfavoriteRecheck`): it sends the removal
/// once more only when the clicked song is still the current one and Music lists it as a favorite again. Nothing
/// here talks to Music.
@Suite struct UnfavoriteRecheckTests {
    let clicked = Track(id: "A1B2C3D4E5F60708", title: "Midnight Circuit", artist: "Neon Harbor", album: "Afterglow City", duration: 217, isFavorited: true)

    /// What a reading of Music says about `track`.
    func reading(
        _ track: Track?,
        availability: PlayerAvailability = .running,
        state: PlaybackState = .playing
    ) -> PlayerSnapshot {
        PlayerSnapshot(availability: availability, state: state, track: track, position: 42, capturedAt: Date(timeIntervalSinceReferenceDate: 5_000))
    }

    /// The clicked track as Music reports it now: the same in everything that isn't given.
    func current(
        id: String? = nil,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        favorited: Bool
    ) -> Track {
        Track(
            id: id ?? clicked.id, title: title ?? clicked.title, artist: artist ?? clicked.artist,
            album: album ?? clicked.album, duration: clicked.duration, isFavorited: favorited
        )
    }

    func decision(_ fresh: PlayerSnapshot) -> UnfavoriteRecheck {
        UnfavoriteRecheck.decide(clicked: clicked, fresh: fresh)
    }

    // MARK: Whether to look again at all

    @Test func aRemovalThatMusicTookGetsAFollowUp() {
        for after in [false, true, nil] as [Bool?] {   // whatever Music read back right after the write
            let took = MusicFavoriteResult(matched: true, favoritedAfter: after)
            #expect(UnfavoriteRecheck.isNeeded(afterWriting: false, result: took), "favoritedAfter: \(String(describing: after))")
        }
    }

    @Test func aRemovalThatReachedNoTrackDoesNot() {
        // The script wrote nothing: the current track wasn't the one clicked.
        #expect(!UnfavoriteRecheck.isNeeded(afterWriting: false, result: MusicFavoriteResult(matched: false, favoritedAfter: nil)))
    }

    @Test func aRemovalWithoutAUsableAnswerDoesNot() {
        // Music wasn't running or wasn't ready for a script, or the script failed.
        #expect(!UnfavoriteRecheck.isNeeded(afterWriting: false, result: nil))
    }

    @Test func addingAFavoriteNeverGetsOne() {
        // Music applies a favorite at once, as a cloud edit, and its star turns on: there is nothing to check.
        for result in [
            MusicFavoriteResult(matched: true, favoritedAfter: true),
            MusicFavoriteResult(matched: true, favoritedAfter: false),
            MusicFavoriteResult(matched: true, favoritedAfter: nil),
            MusicFavoriteResult(matched: false, favoritedAfter: nil),
            nil,
        ] as [MusicFavoriteResult?] {
            #expect(!UnfavoriteRecheck.isNeeded(afterWriting: true, result: result))
        }
    }

    // MARK: Resend or not

    @Test func sendsTheRemovalAgainWhenTheSameSongIsAFavoriteAgain() {
        #expect(decision(reading(current(favorited: true))) == .resend)
    }

    @Test func doesNothingWhenTheSameSongIsStillNotAFavorite() {
        #expect(decision(reading(current(favorited: false))) == .held)
    }

    @Test func doesNothingWhenAnotherSongIsCurrent() {
        // Even a favorite: what the user does with another song is theirs to decide.
        let other = current(id: "0F0E0D0C0B0A0908", title: "Paper Satellites", artist: "The Quiet Radios", album: "Low Orbit", favorited: true)
        #expect(decision(reading(other)) == .trackChanged)
        #expect(decision(reading(current(id: other.id, title: other.title, artist: other.artist, favorited: false))) == .trackChanged)
    }

    @Test func recognisesASongThatMusicHasGivenANewID() {
        // Favoriting a streamed song adds it to the library, and it can come back under another ID.
        #expect(decision(reading(current(id: "NEWID", favorited: true))) == .resend)
        #expect(decision(reading(current(id: "NEWID", favorited: false))) == .held)
    }

    @Test func aSongWithoutATitleIsNotRecognisedByItsName() {
        let nameless = Track(id: "A1", title: "", artist: "", album: "", duration: 0, isFavorited: true)
        let other = Track(id: "B2", title: "", artist: "", album: "", duration: 0, isFavorited: true)
        #expect(UnfavoriteRecheck.decide(clicked: nameless, fresh: reading(other)) == .trackChanged)
        // The same ID still is the same song, whatever it is called.
        #expect(UnfavoriteRecheck.decide(clicked: nameless, fresh: reading(nameless)) == .resend)

        // An artist alone doesn't do either.
        let untitled = Track(id: "A1", title: "", artist: "Neon Harbor", album: "", duration: 0, isFavorited: true)
        let sameArtist = Track(id: "B2", title: "", artist: "Neon Harbor", album: "", duration: 0, isFavorited: true)
        #expect(UnfavoriteRecheck.decide(clicked: untitled, fresh: reading(sameArtist)) == .trackChanged)
    }

    @Test func theTitleAndTheArtistMustBothMatchWhenTheIDDoesNot() {
        #expect(decision(reading(current(id: "NEWID", artist: "Someone Else", favorited: true))) == .trackChanged)
        #expect(decision(reading(current(id: "NEWID", title: "Another Song", favorited: true))) == .trackChanged)
    }

    @Test func theSameIDIsTheSameSongWhateverItIsCalledNow() {
        #expect(decision(reading(current(title: "Renamed", artist: "Renamed Too", favorited: true))) == .resend)
    }

    @Test func onlyTheIDTheTitleAndTheArtistPlayAPart() {
        // Not the album, not the length, not the star the clicked track had when it was clicked, not the state.
        let unstarred = Track(id: clicked.id, title: clicked.title, artist: clicked.artist, album: "Other", duration: 1, isFavorited: false)
        #expect(UnfavoriteRecheck.decide(clicked: unstarred, fresh: reading(current(album: "A Different Album", favorited: true), state: .paused)) == .resend)
        #expect(UnfavoriteRecheck.decide(clicked: unstarred, fresh: reading(current(album: "A Different Album", favorited: false), state: .paused)) == .held)
    }

    @Test func doesNothingWhenMusicHasNoSongToReport() {
        #expect(decision(reading(nil)) == .trackChanged)                                  // stopped: nothing loaded
        #expect(decision(.notRunning) == .trackChanged)
        #expect(decision(.notAuthorized) == .trackChanged)
        // Availability decides on its own, whatever else the reading holds.
        #expect(decision(reading(current(favorited: true), availability: .notRunning)) == .trackChanged)
        #expect(decision(reading(current(favorited: true), availability: .notAuthorized)) == .trackChanged)
    }

    // MARK: What is logged

    @Test func logsFixedWordsForEachOutcome() {
        #expect(UnfavoriteRecheck.resend.logLine == "unfavorite re-sent: Music's sync restored the favorite")
        #expect(UnfavoriteRecheck.held.logLine == "unfavorite held after Music's sync")
        #expect(UnfavoriteRecheck.trackChanged.logLine == "unfavorite recheck skipped: track changed")
    }

    // MARK: When

    @Test func theRecheckComesTwelveSecondsAfterTheRemoval() {
        // Music's favorites sync runs 10 seconds after the removal was written, and this leaves it time to finish.
        #expect(AppleMusicController.unfavoriteRecheckDelay == .seconds(12))
    }
}

/// The delay of a follow-up that a test means to cancel while it waits. No test waits it out: if the code under test
/// fails to cancel the follow-up, the test fails after this long, instead of hanging.
private let aLongWait = Duration.seconds(5)

/// Records what the follow-ups did, in order.
@MainActor
private final class Record {
    private(set) var entries: [String] = []

    func add(_ entry: String) { entries.append(entry) }
}

/// Holds a follow-up where it is until the test lets it go on.
@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

/// The bookkeeping that keeps the follow-up of an unfavorite to one at most (`RecheckSlot`): only the newest request
/// can schedule one, and a newer request, `stop()` or Music quitting cancels the one that waits. The delay is a
/// parameter, so a test doesn't wait long for a follow-up (and one that it wants cancelled while it waits gets a long one).
@MainActor
@Suite struct RecheckSlotTests {
    let slot = RecheckSlot()
    private let record = Record()

    @Test func aFollowUpRunsOnceAfterItsDelay() async {
        let scheduled = slot.schedule(slot.begin(), after: .milliseconds(20)) { [record] in record.add("ran") }
        #expect(scheduled)
        #expect(record.entries.isEmpty)   // not before its delay

        await slot.task?.value
        #expect(record.entries == ["ran"])
    }

    @Test func aNewRequestCancelsTheFollowUpThatIsWaiting() async {
        // A second `setFavorited`, whichever way it goes, begins by cancelling what the first left waiting.
        let scheduled = slot.schedule(slot.begin(), after: aLongWait) { [record] in record.add("first") }
        #expect(scheduled)
        let waiting = slot.task

        _ = slot.begin()
        #expect(waiting?.isCancelled == true)
        #expect(slot.task == nil)
        await waiting?.value   // a cancelled wait ends at once
        #expect(record.entries.isEmpty)
    }

    @Test func theNewRequestsOwnFollowUpRunsInsteadOfTheOldOne() async {
        _ = slot.schedule(slot.begin(), after: aLongWait) { [record] in record.add("first") }
        let first = slot.task

        let scheduled = slot.schedule(slot.begin(), after: .milliseconds(20)) { [record] in record.add("second") }
        #expect(scheduled)
        await first?.value
        await slot.task?.value
        #expect(record.entries == ["second"])
    }

    @Test func aRequestThatWasOvertakenCannotScheduleAFollowUp() async {
        // Two quick clicks run their scripts one after the other, so the first click's script can finish after the
        // second click has begun. Its follow-up would remove the favorite that the second click just set.
        let first = slot.begin()    // click 1, an unfavorite: its script is still running
        let second = slot.begin()   // click 2 begins

        let overtaken = slot.schedule(first, after: .milliseconds(1)) { [record] in record.add("first") }
        #expect(!overtaken)
        #expect(slot.task == nil)   // nothing was scheduled

        // The newest request still can.
        let scheduled = slot.schedule(second, after: .milliseconds(1)) { [record] in record.add("second") }
        #expect(scheduled)
        await slot.task?.value
        #expect(record.entries == ["second"])
    }

    @Test func schedulingAgainForTheSameRequestReplacesTheFollowUp() async {
        let request = slot.begin()
        _ = slot.schedule(request, after: aLongWait) { [record] in record.add("first") }
        let first = slot.task

        _ = slot.schedule(request, after: .milliseconds(20)) { [record] in record.add("second") }
        #expect(first?.isCancelled == true)   // never two at a time
        await first?.value
        await slot.task?.value
        #expect(record.entries == ["second"])
    }

    @Test func cancellingEndsTheFollowUpThatIsWaiting() async {
        // What `stop()` and Music quitting do.
        _ = slot.schedule(slot.begin(), after: aLongWait) { [record] in record.add("waiting") }
        let waiting = slot.task

        slot.cancel()
        #expect(waiting?.isCancelled == true)
        #expect(slot.task == nil)
        await waiting?.value
        #expect(record.entries.isEmpty)
    }

    @Test func cancellingAlsoTurnsAwayARequestThatIsStillOnItsWay() async {
        // An unfavorite has been written, and Music quits before its script has come back.
        let request = slot.begin()
        slot.cancel()

        let scheduled = slot.schedule(request, after: .milliseconds(1)) { [record] in record.add("late") }
        #expect(!scheduled)
        #expect(slot.task == nil)
        // A request that begins afterwards is a fresh start.
        let fresh = slot.schedule(slot.begin(), after: .milliseconds(1)) { [record] in record.add("fresh") }
        #expect(fresh)
        await slot.task?.value
        #expect(record.entries == ["fresh"])
    }

    @Test func aFollowUpThatIsAlreadyRunningSeesTheCancellation() async {
        // It was past its wait, reading Music, when the newer request came. Every step it takes after that has to
        // look, and this is what it sees.
        let started = Gate()
        let released = Gate()
        _ = slot.schedule(slot.begin(), after: .milliseconds(1)) { [record] in
            started.open()
            await released.wait()
            record.add(Task.isCancelled ? "cancelled" : "not cancelled")
        }
        let running = slot.task
        await started.wait()

        _ = slot.begin()
        released.open()
        await running?.value
        #expect(record.entries == ["cancelled"])
    }

    @Test func aFinishedFollowUpLeavesNothingBehindThatCouldRunAgain() async {
        _ = slot.schedule(slot.begin(), after: .milliseconds(1)) { [record] in record.add("ran") }
        await slot.task?.value

        slot.cancel()   // Music quits long afterwards
        try? await Task.sleep(for: .milliseconds(20))
        #expect(record.entries == ["ran"])   // once, and never again
    }
}

/// `stop()` and Music quitting end a follow-up that is waiting, along with whatever else they do. The controller is
/// never started here and no script is sent, so nothing talks to Music.
@MainActor
@Suite struct ControllerRecheckTests {
    let controller = AppleMusicController()
    private let record = Record()

    /// Schedules a follow-up that is waiting, as one that has just been scheduled would be, and returns its task.
    func scheduleWaitingFollowUp() -> Task<Void, Never>? {
        let request = controller.pendingRecheck.begin()
        controller.pendingRecheck.schedule(request, after: aLongWait) { [record] in record.add("ran") }
        return controller.pendingRecheck.task
    }

    @Test func stoppingTheControllerCancelsTheFollowUp() async {
        let waiting = scheduleWaitingFollowUp()
        controller.stop()
        #expect(waiting?.isCancelled == true)
        await waiting?.value
        #expect(record.entries.isEmpty)
    }

    @Test func musicQuittingCancelsTheFollowUp() async {
        let waiting = scheduleWaitingFollowUp()
        controller.musicDidTerminate()
        #expect(waiting?.isCancelled == true)
        await waiting?.value
        #expect(record.entries.isEmpty)
    }

    @Test func aRequestOnItsWayWhenMusicQuitsCannotScheduleAFollowUp() {
        let request = controller.pendingRecheck.begin()
        controller.musicDidTerminate()
        let scheduled = controller.pendingRecheck.schedule(request, after: aLongWait) { [record] in record.add("ran") }
        #expect(!scheduled)
        #expect(controller.pendingRecheck.task == nil)
    }

    @Test func aRequestOnItsWayWhenTheControllerStopsCannotScheduleAFollowUp() {
        let request = controller.pendingRecheck.begin()
        controller.stop()
        let scheduled = controller.pendingRecheck.schedule(request, after: aLongWait) { [record] in record.add("ran") }
        #expect(!scheduled)
        #expect(controller.pendingRecheck.task == nil)
    }
}
