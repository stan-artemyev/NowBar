import Foundation
import Testing
@testable import NowBarCore

@Suite struct PlayerSnapshotTests {
    let track = Track(id: "A", title: "Title", artist: "Artist", album: "Album", duration: 200, isFavorited: false)
    let start = Date(timeIntervalSinceReferenceDate: 1_000)

    func snapshot(_ state: PlaybackState, at position: TimeInterval, track: Track? = nil) -> PlayerSnapshot {
        PlayerSnapshot(availability: .running, state: state, track: track ?? self.track, position: position, capturedAt: start)
    }

    @Test func advancesWhilePlaying() {
        #expect(snapshot(.playing, at: 10).position(at: start.addingTimeInterval(5)) == 15)
    }

    @Test func holdsWhilePaused() {
        #expect(snapshot(.paused, at: 10).position(at: start.addingTimeInterval(5)) == 10)
    }

    @Test func clampsToDuration() {
        #expect(snapshot(.playing, at: 198).position(at: start.addingTimeInterval(30)) == 200)
    }

    @Test func doesNotClampUnknownDuration() {
        var live = track
        live.duration = 0
        #expect(snapshot(.playing, at: 10, track: live).position(at: start.addingTimeInterval(30)) == 40)
    }

    @Test func ignoresClockGoingBackwards() {
        #expect(snapshot(.playing, at: 10).position(at: start.addingTimeInterval(-5)) == 10)
    }
}
