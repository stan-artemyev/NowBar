import AppKit
import Foundation
import NowBarCore
import Testing
@testable import NowBarUI

@MainActor
@Suite("Settings")
struct SettingsTests {
    @Test func startsWithTheDocumentedDefaults() {
        let harness = Harness()
        #expect(harness.store.layout == .large)
        #expect(harness.store.showTitleInMenuBar == false)
        #expect(harness.store.mediaKeysEnabled == true)
    }

    @Test func persistsChangesAndReadsThemBackAfterARelaunch() {
        let harness = Harness()
        harness.store.layout = .compact
        harness.store.showTitleInMenuBar = true
        harness.store.mediaKeysEnabled = false

        #expect(harness.defaults.string(forKey: SettingsKey.panelLayout) == "compact")
        #expect(harness.defaults.bool(forKey: SettingsKey.showTitleInMenuBar) == true)
        #expect(harness.defaults.bool(forKey: SettingsKey.mediaKeysEnabled) == false)

        let relaunched = harness.relaunch().store
        #expect(relaunched.layout == .compact)
        #expect(relaunched.showTitleInMenuBar == true)
        #expect(relaunched.mediaKeysEnabled == false)
    }

    @Test func ignoresAnUnknownStoredLayout() {
        let harness = Harness(configure: { $0.set("sideways", forKey: SettingsKey.panelLayout) })
        #expect(harness.store.layout == .large)
    }

    @Test func mediaKeysSettingIsForwardedToTheTap() {
        let harness = Harness()
        harness.store.start()
        #expect(harness.mediaKeys.isEnabled == true)

        harness.store.mediaKeysEnabled = false
        #expect(harness.mediaKeys.isEnabled == false)
        harness.store.mediaKeysEnabled = true
        #expect(harness.mediaKeys.isEnabled == true)
    }
}

@MainActor
@Suite("Launch at login")
struct LaunchAtLoginTests {
    @Test func startsFromTheSystemsState() {
        let on = Harness(launchAtLogin: true)
        #expect(on.store.launchAtLogin == true)

        let off = Harness(launchAtLogin: false)
        #expect(off.store.launchAtLogin == false)
    }

    @Test func togglesTheLoginItem() {
        let harness = Harness()

        harness.store.launchAtLogin = true
        #expect(harness.login.attempts == [true])
        #expect(harness.login.isEnabled == true)
        #expect(harness.store.launchAtLogin == true)

        harness.store.launchAtLogin = false
        #expect(harness.login.attempts == [true, false])
        #expect(harness.store.launchAtLogin == false)
    }

    @Test func revertsTheToggleWhenTheSystemRefuses() {
        let harness = Harness()
        harness.login.error = TestError()

        harness.store.launchAtLogin = true
        #expect(harness.login.attempts == [true])
        #expect(harness.store.launchAtLogin == false)   // reverted, and no retry loop
    }

    @Test func revertsAFailedDisableToo() {
        let harness = Harness(launchAtLogin: true)
        harness.login.error = TestError()

        harness.store.launchAtLogin = false
        #expect(harness.login.attempts == [false])
        #expect(harness.store.launchAtLogin == true)
    }

    @Test func picksUpChangesMadeInSystemSettingsWhenThePanelOpens() {
        let harness = Harness(launchAtLogin: false)
        harness.store.start()

        harness.login.isEnabled = true   // the user switched it on in System Settings
        harness.store.isPanelVisible = true
        #expect(harness.store.launchAtLogin == true)
        #expect(harness.login.attempts.isEmpty)   // syncing must not write back
        harness.store.isPanelVisible = false
    }
}

@MainActor
@Suite("Start-up")
struct StartupTests {
    @Test func wiresAndStartsTheServices() {
        let harness = Harness()
        harness.volume.current = SystemVolume(level: 0.3, isMuted: true, isAdjustable: true)

        harness.store.start()
        #expect(harness.store.hasMediaKeyTap == true)
        #expect(harness.player.calls == ["start"])
        #expect(harness.volume.started == true)
        #expect(harness.mediaKeys.handler != nil)
        #expect(harness.mediaKeys.isEnabled == true)
        #expect(harness.store.volume == SystemVolume(level: 0.3, isMuted: true, isAdjustable: true))
    }

    @Test func startingTwiceDoesNothingTheSecondTime() {
        let harness = Harness()
        harness.store.start()
        harness.store.start()
        #expect(harness.player.calls == ["start"])
    }

    @Test func mirrorsPlayerPushes() {
        let harness = Harness()
        harness.store.start()
        #expect(harness.store.snapshot == .notRunning)

        harness.player.push(Fixture.running())
        #expect(harness.store.snapshot.track == Fixture.track)
        #expect(harness.store.snapshot.availability == .running)
    }

    @Test func mirrorsSystemVolumeChanges() {
        let harness = Harness()
        harness.store.start()

        // The keyboard volume and mute keys change the Mac's volume; the row follows.
        harness.volume.simulateSystemChange(SystemVolume(level: 0.8, isMuted: false, isAdjustable: true))
        #expect(harness.store.volume.level == 0.8)
        harness.volume.simulateSystemChange(SystemVolume(level: 0.8, isMuted: true, isAdjustable: true))
        #expect(harness.store.volume.isMuted == true)
        harness.volume.simulateSystemChange(.unavailable)
        #expect(harness.store.volume.isAdjustable == false)
    }

    @Test func mirrorsAccessibilityPermissionChanges() {
        let harness = Harness(mediaKeysTrusted: false)
        harness.store.start()
        #expect(harness.store.mediaKeysTrusted == false)

        harness.mediaKeys.isTrusted = true
        harness.mediaKeys.onTrustChange?(true)
        #expect(harness.store.mediaKeysTrusted == true)
        harness.mediaKeys.onTrustChange?(false)
        #expect(harness.store.mediaKeysTrusted == false)
    }

    @Test func asksForAccessibilityOnceWhenMediaKeysAreOnWithoutPermission() {
        let harness = Harness(mediaKeysTrusted: false)

        harness.store.start()
        #expect(harness.mediaKeys.requestTrustCount == 1)
        #expect(harness.defaults.bool(forKey: SettingsKey.didRequestMediaKeyAccess) == true)

        // A relaunch must not prompt again.
        let relaunched = harness.relaunch(mediaKeysTrusted: false)
        relaunched.store.start()
        #expect(relaunched.mediaKeys.requestTrustCount == 0)
    }

    @Test func doesNotAskWhenTrustedOrDisabled() {
        let trusted = Harness(mediaKeysTrusted: true)
        trusted.store.start()
        #expect(trusted.mediaKeys.requestTrustCount == 0)

        let disabled = Harness(mediaKeysTrusted: false, configure: { $0.set(false, forKey: SettingsKey.mediaKeysEnabled) })
        disabled.store.start()
        #expect(disabled.mediaKeys.requestTrustCount == 0)
        #expect(disabled.mediaKeys.isEnabled == false)
    }

    @Test func enablingMediaKeysLaterAsksForAccessTheFirstTimeOnly() {
        let harness = Harness(mediaKeysTrusted: false, configure: { $0.set(false, forKey: SettingsKey.mediaKeysEnabled) })
        harness.store.start()

        harness.store.mediaKeysEnabled = true
        #expect(harness.mediaKeys.requestTrustCount == 1)
        harness.store.mediaKeysEnabled = false
        harness.store.mediaKeysEnabled = true
        #expect(harness.mediaKeys.requestTrustCount == 1)
    }

    @Test func theMenuItemAsksExplicitly() {
        let harness = Harness(mediaKeysTrusted: false)
        harness.store.start()
        harness.store.requestMediaKeyAccess()
        #expect(harness.mediaKeys.requestTrustCount == 2)   // once automatically, once on request
    }

    @Test func worksWithoutMediaKeys() {
        // `--demo` runs without a media key tap.
        let player = FakePlayer()
        let store = PlayerStore(player: player, volume: FakeVolume(), mediaKeys: nil, defaults: EphemeralDefaults(), launchAtLoginService: FakeLaunchAtLogin())
        store.start()
        player.push(Fixture.running())
        #expect(store.hasMediaKeyTap == false)
        #expect(store.mediaKeysTrusted == false)
        #expect(store.handleMediaKey(.playPause) == true)   // routing still works if something calls it
    }

    @Test func openMusicGoesThroughThePlayer() {
        let harness = Harness()
        harness.store.openMusic()
        #expect(harness.player.calls == ["openApp"])
    }
}

@MainActor
@Suite("Volume")
struct VolumeTests {
    @Test func settingTheLevelUpdatesAtOnceAndReachesTheSystem() {
        let harness = Harness()
        harness.store.start()

        harness.store.setVolume(0.4)
        #expect(harness.store.volume.level == 0.4)
        #expect(harness.volume.levelCalls == [0.4])
    }

    @Test func settingTheLevelIsClamped() {
        let harness = Harness()
        harness.store.start()

        harness.store.setVolume(1.7)
        harness.store.setVolume(-0.2)
        #expect(harness.volume.levelCalls == [1, 0])
        #expect(harness.store.volume.level == 0)
    }

    @Test func raisingTheLevelUnmutes() {
        let harness = Harness()
        harness.volume.current = SystemVolume(level: 0.5, isMuted: true, isAdjustable: true)
        harness.store.start()
        #expect(harness.store.volume.isMuted == true)

        harness.store.setVolume(0.6)
        #expect(harness.store.volume.isMuted == false)
    }

    @Test func togglingMuteFlipsAtOnceAndReachesTheSystem() {
        let harness = Harness()
        harness.store.start()

        harness.store.toggleMute()
        #expect(harness.store.volume.isMuted == true)
        harness.store.toggleMute()
        #expect(harness.store.volume.isMuted == false)
        #expect(harness.volume.muteCalls == [true, false])
    }

    @Test func doesNothingWhenTheOutputHasNoAdjustableVolume() {
        let harness = Harness()
        harness.volume.current = .unavailable
        harness.store.start()

        harness.store.setVolume(0.9)
        harness.store.toggleMute()
        #expect(harness.volume.levelCalls.isEmpty)
        #expect(harness.volume.muteCalls.isEmpty)
        #expect(harness.store.volume == .unavailable)
    }
}

@MainActor
@Suite("Polling")
struct PollingTests {
    func harness() -> Harness {
        let harness = Harness()
        harness.store.pollInterval = .milliseconds(20)
        harness.store.start()
        return harness
    }

    @Test func pollsImmediatelyAndRepeatedlyWhileThePanelIsVisible() async {
        let harness = harness()
        #expect(harness.player.refreshCount == 0)   // nothing while the panel is closed

        harness.store.isPanelVisible = true
        #expect(await eventually { harness.player.refreshCount >= 1 })
        #expect(await eventually { harness.player.refreshCount >= 4 })
        harness.store.isPanelVisible = false
    }

    @Test func stopsWhenThePanelCloses() async {
        let harness = harness()

        harness.store.isPanelVisible = true
        await eventually { harness.player.refreshCount >= 2 }
        harness.store.isPanelVisible = false

        try? await Task.sleep(for: .milliseconds(80))   // let an in-flight query finish
        let settled = harness.player.refreshCount
        try? await Task.sleep(for: .milliseconds(150))
        #expect(harness.player.refreshCount == settled)
    }

    @Test func resumesWhenThePanelOpensAgain() async {
        let harness = harness()

        harness.store.isPanelVisible = true
        await eventually { harness.player.refreshCount >= 1 }
        harness.store.isPanelVisible = false
        try? await Task.sleep(for: .milliseconds(80))
        let before = harness.player.refreshCount

        harness.store.isPanelVisible = true
        #expect(await eventually { harness.player.refreshCount > before })
        harness.store.isPanelVisible = false
    }

    @Test func appliesWhatThePlayerReports() async {
        let harness = harness()
        harness.player.refreshResult = Fixture.running(.paused, position: 12)

        harness.store.isPanelVisible = true
        #expect(await eventually { harness.store.snapshot.state == .paused })
        #expect(harness.store.snapshot.position == 12)
        harness.store.isPanelVisible = false
    }

    @Test func dropsAnAnswerThatWasOvertakenByALocalChange() async {
        let harness = Harness()
        harness.store.pollInterval = .seconds(30)   // only the first poll runs
        harness.store.start()
        harness.player.push(Fixture.running())

        // The poll is in flight when the user seeks (not a favorite: a favorite request is held against stale
        // answers anyway, which would hide whether this one is dropped)...
        harness.player.holdRefresh = true
        harness.store.isPanelVisible = true
        #expect(await eventually { harness.player.heldRefresh != nil })
        harness.store.seek(to: 100)
        #expect(harness.store.snapshot.position == 100)

        // ...and the answer (read before the change) arrives afterwards: it must not undo it.
        harness.player.holdRefresh = false
        harness.player.refreshResult = Fixture.running()   // still at 84 s
        harness.player.releaseHeldRefresh()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(harness.store.snapshot.position == 100)
        harness.store.isPanelVisible = false
    }
}

@MainActor
@Suite("Artwork")
struct ArtworkTests {
    @Test func loadsArtworkForTheCurrentTrack() async {
        let harness = Harness()
        harness.player.artworkByTrackID["a"] = Fixture.png(size: 50)
        harness.startAndPush(Fixture.running(track: Fixture.track(id: "a")))

        #expect(await eventually { harness.store.artwork != nil })
        #expect(harness.store.artwork?.size.width == 50)
        #expect(harness.player.artworkRequests == ["a"])
    }

    @Test func doesNotReloadWhileTheTrackStaysTheSame() async {
        let harness = Harness()
        harness.player.artworkByTrackID["a"] = Fixture.png(size: 50)
        harness.startAndPush(Fixture.running(track: Fixture.track(id: "a")))
        await eventually { harness.store.artwork != nil }

        harness.player.push(Fixture.running(.paused, track: Fixture.track(id: "a"), position: 10))
        harness.player.push(Fixture.running(.playing, track: Fixture.track(id: "a", favorited: true), position: 11))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.player.artworkRequests == ["a"])
    }

    @Test func swapsInTheNextTracksArtwork() async {
        let harness = Harness()
        harness.player.artworkByTrackID["a"] = Fixture.png(size: 50)
        harness.player.artworkByTrackID["b"] = Fixture.png(size: 60)
        harness.startAndPush(Fixture.running(track: Fixture.track(id: "a")))
        await eventually { harness.store.artwork?.size.width == 50 }

        harness.player.push(Fixture.running(track: Fixture.track(id: "b")))
        #expect(await eventually { harness.store.artwork?.size.width == 60 })
    }

    @Test func aTrackWithoutArtworkShowsThePlaceholder() async {
        let harness = Harness()
        harness.player.artworkByTrackID["a"] = Fixture.png(size: 50)
        harness.startAndPush(Fixture.running(track: Fixture.track(id: "a")))
        await eventually { harness.store.artwork != nil }

        harness.player.push(Fixture.running(track: Fixture.track(id: "no-art")))   // the player has none for it
        #expect(await eventually { harness.store.artwork == nil })
    }

    @Test func clearsTheArtworkWhenThereIsNoTrack() async {
        let harness = Harness()
        harness.player.artworkByTrackID["a"] = Fixture.png(size: 50)
        harness.startAndPush(Fixture.running(track: Fixture.track(id: "a")))
        await eventually { harness.store.artwork != nil }

        harness.player.push(.notRunning)
        #expect(harness.store.artwork == nil)
    }

    @Test func aSlowLoadForAnOldTrackNeverOverwritesTheNewOne() async {
        let harness = Harness()
        harness.player.artworkByTrackID["slow"] = Fixture.png(size: 50)
        harness.player.artworkDelays["slow"] = .milliseconds(150)
        harness.player.artworkByTrackID["fast"] = Fixture.png(size: 60)
        harness.startAndPush(Fixture.running(track: Fixture.track(id: "slow")))
        harness.player.push(Fixture.running(track: Fixture.track(id: "fast")))

        #expect(await eventually { harness.store.artwork?.size.width == 60 })
        try? await Task.sleep(for: .milliseconds(250))   // long enough for the stale load to have finished
        #expect(harness.store.artwork?.size.width == 60)
    }

    @Test func retriesMissingArtworkWhenThePanelOpens() async {
        let harness = Harness()
        harness.store.pollInterval = .seconds(30)
        harness.player.refreshResult = Fixture.running(track: Fixture.track(id: "late"))   // what the poll on opening reads
        harness.startAndPush(Fixture.running(track: Fixture.track(id: "late")))
        await eventually { harness.player.artworkRequests.count == 1 }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(harness.store.artwork == nil)   // not ready yet

        harness.player.artworkByTrackID["late"] = Fixture.png(size: 50)   // it arrived in the meantime
        harness.store.isPanelVisible = true
        #expect(await eventually { harness.store.artwork != nil })
        harness.store.isPanelVisible = false
    }

    @Test func shrinksOversizedArtwork() async {
        let harness = Harness()
        harness.player.artworkByTrackID["big"] = Fixture.png(size: 2000)
        harness.startAndPush(Fixture.running(track: Fixture.track(id: "big")))

        #expect(await eventually { harness.store.artwork != nil })
        #expect(harness.store.artwork?.size.width == CGFloat(ArtworkDecoder.maxPixelSize))
    }

    @Test func ignoresDataThatIsNotAnImage() async {
        #expect(await ArtworkDecoder.decode(Data("not an image".utf8)) == nil)
        #expect(await ArtworkDecoder.decode(Data()) == nil)
        #expect(await ArtworkDecoder.decode(nil) == nil)
    }
}
