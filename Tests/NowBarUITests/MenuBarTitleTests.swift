import NowBarCore
import Testing
@testable import NowBarUI

@MainActor
@Suite("Menu bar title")
struct MenuBarTitleTests {
    func title(_ title: String, artist: String) -> Track {
        Track(id: "t", title: title, artist: artist, album: "Album", duration: 200, isFavorited: false)
    }

    func store(showTitle: Bool, snapshot: PlayerSnapshot) -> (PlayerStore, Harness) {
        let harness = Harness(configure: { $0.set(showTitle, forKey: SettingsKey.showTitleInMenuBar) })
        harness.startAndPush(snapshot)
        return (harness.store, harness)
    }

    @Test func isNilWhenTheSettingIsOff() {
        let (store, _) = store(showTitle: false, snapshot: Fixture.running())
        #expect(store.menuBarTitle == nil)
    }

    @Test func isNilWithoutATrack() {
        let (store, harness) = store(showTitle: true, snapshot: .notRunning)
        #expect(store.menuBarTitle == nil)

        harness.player.push(.notAuthorized)
        #expect(store.menuBarTitle == nil)

        harness.player.push(PlayerSnapshot(availability: .running, state: .stopped, track: nil, position: 0))
        #expect(store.menuBarTitle == nil)
    }

    @Test func joinsTitleAndArtistWithAMiddleDot() {
        let (store, _) = store(showTitle: true, snapshot: Fixture.running())
        #expect(store.menuBarTitle == "Midnight Circuit · Neon Harbor")
    }

    @Test func staysWhilePaused() {
        let (store, _) = store(showTitle: true, snapshot: Fixture.running(.paused))
        #expect(store.menuBarTitle == "Midnight Circuit · Neon Harbor")
    }

    @Test func followsTheSettingAndTheTrack() {
        let (store, harness) = store(showTitle: true, snapshot: Fixture.running())
        store.showTitleInMenuBar = false
        #expect(store.menuBarTitle == nil)
        store.showTitleInMenuBar = true
        harness.player.push(Fixture.running(track: Fixture.track(id: "t2", title: "Glasshouse", artist: "Mara Vey")))
        #expect(store.menuBarTitle == "Glasshouse · Mara Vey")
    }

    @Test func keepsTextOfExactlyTheLimit() {
        // 20 + " · " (3) + 9 = 32 characters.
        let track = title(String(repeating: "T", count: 20), artist: String(repeating: "A", count: 9))
        let text = PlayerStore.menuBarTitle(for: track)
        #expect(text?.count == 32)
        #expect(text?.hasSuffix("…") == false)
    }

    @Test func truncatesLongerTextToTheLimitIncludingTheEllipsis() {
        let track = title(String(repeating: "T", count: 20), artist: String(repeating: "A", count: 10))   // 33 characters
        let text = PlayerStore.menuBarTitle(for: track)
        #expect(text?.count == 32)
        #expect(text == String(repeating: "T", count: 20) + " · " + String(repeating: "A", count: 8) + "…")
    }

    @Test func truncatesVeryLongTitles() {
        let track = title(String(repeating: "x", count: 200), artist: "Artist")
        let text = PlayerStore.menuBarTitle(for: track)
        #expect(text == String(repeating: "x", count: 31) + "…")
    }

    @Test func dropsWhitespaceBeforeTheEllipsis() {
        // The 31st character is the space after the title.
        let track = title(String(repeating: "x", count: 30), artist: "Artist")
        #expect(PlayerStore.menuBarTitle(for: track) == String(repeating: "x", count: 30) + "…")
    }

    @Test func countsCharactersNotBytes() {
        let track = title(String(repeating: "é", count: 20), artist: String(repeating: "日", count: 9))
        #expect(PlayerStore.menuBarTitle(for: track)?.count == 32)
        #expect(PlayerStore.menuBarTitle(for: track)?.hasSuffix("…") == false)
    }

    @Test func fallsBackToWhicheverPartExists() {
        #expect(PlayerStore.menuBarTitle(for: title("Only Title", artist: "")) == "Only Title")
        #expect(PlayerStore.menuBarTitle(for: title("", artist: "Only Artist")) == "Only Artist")
        #expect(PlayerStore.menuBarTitle(for: title("", artist: "")) == nil)
    }
}
