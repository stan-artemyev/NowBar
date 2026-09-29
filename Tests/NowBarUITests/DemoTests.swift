import AppKit
import Foundation
import NowBarCore
import SwiftUI
import Testing
@testable import NowBarUI

@MainActor
@Suite("Demo player")
struct DemoPlayerTests {
    let now = Date(timeIntervalSinceReferenceDate: 50_000)

    @Test func playlistMatchesThePrototype() {
        let playlist = DemoPlayerController.playlist
        #expect(playlist.map(\.title) == ["Midnight Circuit", "Paper Satellites", "Glasshouse", "Northbound", "Honey & Static"])
        #expect(playlist.map(\.artist) == ["Neon Harbor", "The Quiet Radios", "Mara Vey", "Lumen Drive", "Velvet Tides"])
        #expect(playlist.map(\.album) == ["Afterglow City", "Low Orbit", "Soft Machines", "Coastlines", "Honey & Static"])
        #expect(playlist.map(\.duration) == [217, 252, 185, 301, 168])   // 3:37 4:12 3:05 5:01 2:48
        #expect(Set(playlist.map(\.id)).count == playlist.count)
    }

    @Test func aFixedStateReportsExactlyWhatItWasGiven() async {
        let player = DemoPlayerController(availability: .running, state: .paused, trackIndex: 2, position: 62, isFavorited: true, capturedAt: now)
        let snapshot = await player.refresh()
        #expect(snapshot.availability == .running)
        #expect(snapshot.state == .paused)
        #expect(snapshot.track?.title == "Glasshouse")
        #expect(snapshot.track?.isFavorited == true)
        #expect(snapshot.position == 62)
        #expect(snapshot.capturedAt == now)
    }

    @Test func fixedStatesWithoutATrack() async {
        let closed = DemoPlayerController(availability: .notRunning, state: .stopped)
        #expect(await closed.refresh() == .notRunning)

        let denied = DemoPlayerController(availability: .notAuthorized, state: .stopped)
        #expect(await denied.refresh() == .notAuthorized)

        let idle = await DemoPlayerController(availability: .running, state: .stopped).refresh()
        #expect(idle.availability == .running)
        #expect(idle.track == nil)
    }

    @Test func startDeliversTheInitialSnapshotAndPushesAfterActions() async {
        let player = DemoPlayerController(availability: .running, state: .playing, capturedAt: now)
        var pushed: [PlayerSnapshot] = []
        player.onChange = { pushed.append($0) }

        player.start()
        #expect(pushed.count == 1)
        await player.playPause()
        #expect(pushed.count == 2)
        #expect(pushed.last?.state == .paused)
        player.stop()
    }

    @Test func playPauseFreezesAndResumes() async {
        let player = DemoPlayerController(availability: .running, state: .playing, position: 30, capturedAt: Date().addingTimeInterval(-10))
        await player.playPause()
        let paused = await player.refresh()
        #expect(paused.state == .paused)
        #expect(abs(paused.position - 40) < 1)   // 30 s plus the 10 s that passed

        await player.playPause()
        #expect(await player.refresh().state == .playing)
    }

    @Test func nextWrapsAroundThePlaylist() async {
        let player = DemoPlayerController(availability: .running, state: .playing, trackIndex: 4, position: 10, capturedAt: now)
        await player.nextTrack()
        let snapshot = await player.refresh()
        #expect(snapshot.track?.title == "Midnight Circuit")
        #expect(snapshot.position == 0)
    }

    @Test func previousRestartsTheTrackUnlessItJustBegan() async {
        let player = DemoPlayerController(availability: .running, state: .paused, trackIndex: 1, position: 84, capturedAt: now)
        await player.previousTrack()
        var snapshot = await player.refresh()
        #expect(snapshot.track?.title == "Paper Satellites")   // restarted
        #expect(snapshot.position == 0)

        await player.previousTrack()
        snapshot = await player.refresh()
        #expect(snapshot.track?.title == "Midnight Circuit")   // went back

        await player.previousTrack()
        #expect(await player.refresh().track?.title == "Honey & Static")   // and wrapped
    }

    @Test func seekingIsClampedToTheTrack() async {
        let player = DemoPlayerController(availability: .running, state: .paused, trackIndex: 0, position: 0, capturedAt: now)
        await player.seek(to: 100)
        #expect(await player.refresh().position == 100)
        await player.seek(to: 9999)
        #expect(await player.refresh().position == 217)
        await player.seek(to: -4)
        #expect(await player.refresh().position == 0)
    }

    @Test func favoritesStickToTheirTrack() async {
        let player = DemoPlayerController(availability: .running, state: .paused, trackIndex: 0, position: 0, capturedAt: now)
        await player.setFavorited(true)
        #expect(await player.refresh().track?.isFavorited == true)

        await player.nextTrack()
        #expect(await player.refresh().track?.isFavorited == false)

        await player.previousTrack()   // back to the first track
        #expect(await player.refresh().track?.isFavorited == true)

        await player.setFavorited(false)
        #expect(await player.refresh().track?.isFavorited == false)
    }

    @Test func openingTheAppLaunchesItPaused() async {
        let player = DemoPlayerController(availability: .notRunning, state: .stopped)
        player.openApp()
        let snapshot = await player.refresh()
        #expect(snapshot.availability == .running)
        #expect(snapshot.state == .paused)
        #expect(snapshot.track?.title == "Midnight Circuit")
    }

    @Test func actionsDoNothingWhileTheAppIsClosed() async {
        let player = DemoPlayerController(availability: .notRunning, state: .stopped)
        await player.playPause()
        await player.nextTrack()
        await player.setFavorited(true)
        #expect(await player.refresh() == .notRunning)
    }

    @Test func theLiveSimulationStartsPlayingAndCanBeStopped() async {
        let player = DemoPlayerController()
        let snapshot = await player.refresh()
        #expect(snapshot.state == .playing)
        #expect(snapshot.track?.title == "Midnight Circuit")
        #expect(abs(snapshot.position - 84) < 1)
        player.start()
        player.stop()
    }

    @Test func everyTrackHasDistinctArtwork() async throws {
        var seen: [Data] = []
        for track in DemoPlayerController.playlist {
            let player = DemoPlayerController(availability: .running, state: .paused)
            let data = try #require(await player.artwork(for: track), "no artwork for \(track.title)")
            #expect(Array(data.prefix(4)) == [0x89, 0x50, 0x4E, 0x47], "\(track.title) isn't a PNG")
            let image = try #require(ArtworkDecoder.makeCGImage(from: data))
            #expect(image.width == DemoArtwork.pixelSize)
            #expect(!seen.contains(data), "\(track.title) repeats an earlier cover")
            seen.append(data)
        }
        #expect(seen.count == 5)
    }

    @Test func unknownTracksHaveNoArtwork() async {
        let player = DemoPlayerController(availability: .running, state: .paused)
        #expect(await player.artwork(for: Fixture.track) == nil)
    }
}

@MainActor
@Suite("Demo volume")
struct DemoVolumeTests {
    @Test func behavesLikeTheSystemVolume() {
        let volume = DemoSystemVolume(level: 0.6)
        var seen: [SystemVolume] = []
        volume.onChange = { seen.append($0) }

        volume.setMuted(true)
        #expect(volume.current.isMuted == true)
        volume.setLevel(0.3)   // raising the level unmutes
        #expect(volume.current == SystemVolume(level: 0.3, isMuted: false, isAdjustable: true))
        volume.setLevel(4)
        #expect(volume.current.level == 1)
        #expect(seen.count == 3)
    }

    @Test func ignoresChangesWhenNotAdjustable() {
        let volume = DemoSystemVolume(level: 0.6, isMuted: false, isAdjustable: false)
        volume.setLevel(0.1)
        volume.setMuted(true)
        #expect(volume.current == SystemVolume(level: 0.6, isMuted: false, isAdjustable: false))
    }
}

@Suite("Panel content")
struct PanelContentTests {
    @Test func mapsSnapshotsToWhatThePanelShows() {
        #expect(PanelContent(.notRunning).hasTrack == false)
        #expect(PanelContent(.notRunning).title == "Not Playing")
        #expect(PanelContent(.notRunning).detail(compact: false) == "Apple Music isn't open")

        #expect(PanelContent(.notAuthorized).title == "Can't Control Apple Music")
        #expect(PanelContent(.notAuthorized).detail(compact: false).contains("Privacy & Security → Automation"))

        let idle = PanelContent(PlayerSnapshot(availability: .running, state: .stopped, track: nil, position: 0))
        #expect(idle.title == "Not Playing")
        #expect(idle.detail(compact: false) == "Choose something to play in Apple Music")

        let playing = PanelContent(Fixture.running())
        #expect(playing.hasTrack)
        #expect(playing.title == "Midnight Circuit")
    }

    @Test func largeLayoutShowsArtistAndAlbumCompactShowsTheArtist() {
        let content = PanelContent(Fixture.running())
        #expect(content.detail(compact: false) == "Neon Harbor — Afterglow City")
        #expect(content.detail(compact: true) == "Neon Harbor")
    }

    @Test func leavesOutMissingParts() {
        let noAlbum = Track(id: "x", title: "T", artist: "Artist", album: "", duration: 10, isFavorited: false)
        #expect(PanelContent(Fixture.running(track: noAlbum)).detail(compact: false) == "Artist")

        let noArtist = Track(id: "x", title: "T", artist: "", album: "Album", duration: 10, isFavorited: false)
        #expect(PanelContent(Fixture.running(track: noArtist)).detail(compact: false) == "Album")
    }
}

@MainActor
@Suite("Snapshot rendering")
struct SnapshotRendererTests {
    @Test func scenariosCoverTheRequiredStatesInLightAndDark() {
        let names = SnapshotRenderer.scenarioNames
        for required in ["large-playing", "large-paused", "large-favorited", "compact-playing", "not-running", "not-authorized", "nothing-playing"] {
            #expect(names.contains(required), "missing scenario \(required)")
        }
        #expect(Set(names).count == names.count)
    }

    @Test func rendersThePanelAtTwiceItsSize() async throws {
        let data = try #require(await SnapshotRenderer.render(.largePlaying, scheme: .dark, now: Date()))
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(bitmap.pixelsWide == 600)     // 300 pt at 2x
        #expect(bitmap.pixelsHigh == 1008)    // 504 pt at 2x: header, artwork, title, progress, transport, volume
    }

    @Test func compactIsShorterThanLarge() async throws {
        let compact = try #require(await SnapshotRenderer.render(.compactPlaying, scheme: .light, now: Date()))
        let large = try #require(await SnapshotRenderer.render(.largePlaying, scheme: .light, now: Date()))
        let compactHeight = try #require(NSBitmapImageRep(data: compact)).pixelsHigh
        let largeHeight = try #require(NSBitmapImageRep(data: large)).pixelsHigh
        #expect(compactHeight < largeHeight)
    }
}
