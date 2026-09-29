import NowBarCore
import Testing
@testable import NowBarUI

@MainActor
@Suite("Media key routing")
struct MediaKeyRoutingTests {
    @Test func returnsFalseForEveryKeyWhenMediaKeysAreDisabled() {
        let harness = Harness(configure: { $0.set(false, forKey: SettingsKey.mediaKeysEnabled) })
        harness.startAndPush(Fixture.running())

        for key in MediaKey.allCases {
            #expect(harness.store.handleMediaKey(key) == false, "\(key) must pass through when the setting is off")
        }
        #expect(harness.player.calls == ["start"])
    }

    @Test func returnsFalseWhenTheMusicAppIsNotRunning() {
        let harness = Harness()
        harness.startAndPush(.notRunning)

        for key in MediaKey.allCases {
            #expect(harness.store.handleMediaKey(key) == false, "\(key) must pass through while Music is closed")
        }
        #expect(harness.player.calls == ["start"])
    }

    @Test func returnsFalseWhenAutomationIsNotAuthorized() {
        let harness = Harness()
        harness.startAndPush(.notAuthorized)

        for key in MediaKey.allCases {
            #expect(harness.store.handleMediaKey(key) == false)
        }
    }

    @Test func leavesTheVolumeKeysToMacOS() async {
        let harness = Harness()
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
        let harness = Harness()
        harness.startAndPush(Fixture.running())

        #expect(harness.store.handleMediaKey(.playPause) == true)
        #expect(harness.store.handleMediaKey(.next) == true)
        #expect(harness.store.handleMediaKey(.previous) == true)

        await eventually { harness.player.calls.count == 4 }
        #expect(harness.player.calls == ["start", "playPause", "nextTrack", "previousTrack"])
    }

    @Test func transportKeysAreNotConsumedUntilThePlayerIsRunning() async {
        let harness = Harness()
        harness.startAndPush(.notRunning)
        #expect(harness.store.handleMediaKey(.playPause) == false)

        harness.player.push(Fixture.running(.paused))
        #expect(harness.store.handleMediaKey(.playPause) == true)
        await eventually { harness.player.calls.contains("playPause") }
    }

    @Test func theInstalledHandlerRoutesThroughTheStore() async {
        let harness = Harness()
        harness.startAndPush(Fixture.running())

        #expect(harness.mediaKeys.press(.next) == true)
        #expect(harness.mediaKeys.press(.volumeUp) == false)
        await eventually { harness.player.calls.contains("nextTrack") }
    }

    @Test func turningTheSettingOffStopsConsumingKeys() {
        let harness = Harness()
        harness.startAndPush(Fixture.running())
        #expect(harness.store.handleMediaKey(.next) == true)

        harness.store.mediaKeysEnabled = false
        #expect(harness.store.handleMediaKey(.next) == false)
        #expect(harness.mediaKeys.isEnabled == false)
    }
}
