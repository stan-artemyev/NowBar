import Foundation
import NowBarCore
import Testing
@testable import NowBarUI

@MainActor
@Suite("Media key routing")
struct MediaKeyRoutingTests {
    /// A store with Media Keys Control Apple Music switched on. A new install starts with it off, so every test of
    /// what the keys do once NowBar has them begins here.
    func harnessWithMediaKeysOn(trusted: Bool = true) -> Harness {
        Harness(mediaKeysTrusted: trusted, configure: { $0.set(true, forKey: SettingsKey.mediaKeysEnabled) })
    }

    @Test func aNewInstallLeavesEveryKeyToMacOS() {
        let harness = Harness()   // nothing stored: the option is off
        harness.startAndPush(Fixture.running())

        for key in MediaKey.allCases {
            #expect(harness.store.handleMediaKey(key) == false, "\(key) must pass through until the user turns the option on")
        }
        #expect(harness.player.calls == ["start"])
    }

    @Test func returnsFalseForEveryKeyWhenMediaKeysAreDisabled() {
        let harness = Harness(configure: { $0.set(false, forKey: SettingsKey.mediaKeysEnabled) })
        harness.startAndPush(Fixture.running())

        for key in MediaKey.allCases {
            #expect(harness.store.handleMediaKey(key) == false, "\(key) must pass through when the setting is off")
        }
        #expect(harness.player.calls == ["start"])
    }

    @Test func returnsFalseWhenTheMusicAppIsNotRunning() {
        let harness = harnessWithMediaKeysOn()
        harness.startAndPush(.notRunning)

        for key in MediaKey.allCases {
            #expect(harness.store.handleMediaKey(key) == false, "\(key) must pass through while Music is closed")
        }
        #expect(harness.player.calls == ["start"])
    }

    @Test func returnsFalseWhenAutomationIsNotAuthorized() {
        let harness = harnessWithMediaKeysOn()
        harness.startAndPush(.notAuthorized)

        for key in MediaKey.allCases {
            #expect(harness.store.handleMediaKey(key) == false)
        }
    }

    @Test func leavesTheVolumeKeysToMacOS() async {
        let harness = harnessWithMediaKeysOn()
        harness.startAndPush(Fixture.running())

        #expect(harness.store.handleMediaKey(.mute) == false)
        #expect(harness.store.handleMediaKey(.volumeUp) == false)
        #expect(harness.store.handleMediaKey(.volumeDown) == false)

        try? await Task.sleep(for: .milliseconds(30))
        #expect(harness.player.calls == ["start"])
        #expect(harness.volume.levelCalls.isEmpty)
        #expect(harness.volume.muteCalls.isEmpty)
    }

    @Test func consumesTransportKeysAndForwardsThemToThePlayer() async {
        let harness = harnessWithMediaKeysOn()
        harness.startAndPush(Fixture.running())   // playing, so play/pause pauses

        #expect(harness.store.handleMediaKey(.playPause) == true)
        #expect(harness.store.handleMediaKey(.next) == true)
        #expect(harness.store.handleMediaKey(.previous) == true)

        await eventually { harness.player.calls.count == 4 }
        #expect(harness.player.calls == ["start", "pause", "nextTrack", "previousTrack"])
    }

    @Test func transportKeysAreNotConsumedUntilThePlayerIsRunning() async {
        let harness = harnessWithMediaKeysOn()
        harness.startAndPush(.notRunning)
        #expect(harness.store.handleMediaKey(.playPause) == false)

        harness.player.push(Fixture.running(.paused))
        #expect(harness.store.handleMediaKey(.playPause) == true)
        await eventually { harness.player.calls.contains("play") }
    }

    @Test func playPauseKeyPausesWhatIsPlayingAndPlaysWhatIsNot() async {
        let playing = harnessWithMediaKeysOn()
        playing.startAndPush(Fixture.running(.playing))
        #expect(playing.store.handleMediaKey(.playPause) == true)
        await eventually { playing.player.calls.contains("pause") }
        #expect(playing.player.calls == ["start", "pause"])

        let paused = harnessWithMediaKeysOn()
        paused.startAndPush(Fixture.running(.paused))
        #expect(paused.store.handleMediaKey(.playPause) == true)
        await eventually { paused.player.calls.contains("play") }
        #expect(paused.player.calls == ["start", "play"])

        let stopped = harnessWithMediaKeysOn()
        stopped.startAndPush(Fixture.running(.stopped))
        #expect(stopped.store.handleMediaKey(.playPause) == true)
        await eventually { stopped.player.calls.contains("play") }
        #expect(stopped.player.calls == ["start", "play"])
    }

    @Test func aQuickSecondPlayPauseKeyIsConsumedButDoesNothing() async {
        let harness = harnessWithMediaKeysOn()
        let moment = Date(timeIntervalSinceReferenceDate: 10_000)
        harness.store.now = { moment }   // both presses at the same instant
        harness.startAndPush(Fixture.running(.playing))

        #expect(harness.store.handleMediaKey(.playPause) == true)
        #expect(harness.store.handleMediaKey(.playPause) == true)   // still ours, so macOS never sees it

        await eventually { harness.player.calls.contains("pause") }
        try? await Task.sleep(for: .milliseconds(30))   // give a wrongly sent second call time to show up
        #expect(harness.player.calls == ["start", "pause"])
    }

    @Test func theInstalledHandlerRoutesThroughTheStore() async {
        let harness = harnessWithMediaKeysOn()
        harness.startAndPush(Fixture.running())

        #expect(harness.mediaKeys.press(.next) == true)
        #expect(harness.mediaKeys.press(.volumeUp) == false)
        await eventually { harness.player.calls.contains("nextTrack") }
    }

    @Test func turningTheSettingOnStartsConsumingKeys() {
        let harness = Harness()   // trusted, and off as on a new install
        harness.startAndPush(Fixture.running())
        #expect(harness.store.handleMediaKey(.next) == false)
        #expect(harness.mediaKeys.isEnabled == false)

        harness.store.mediaKeysEnabled = true
        #expect(harness.mediaKeys.isEnabled == true)
        #expect(harness.store.handleMediaKey(.next) == true)
    }

    @Test func turningTheSettingOffStopsConsumingKeys() {
        let harness = harnessWithMediaKeysOn()
        harness.startAndPush(Fixture.running())
        #expect(harness.store.handleMediaKey(.next) == true)

        harness.store.mediaKeysEnabled = false
        #expect(harness.store.handleMediaKey(.next) == false)
        #expect(harness.mediaKeys.isEnabled == false)
    }
}
