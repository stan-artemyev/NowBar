import Foundation
import Testing
@testable import NowBarCore

@Suite struct TrackTests {
    func track(id: String, title: String = "Title", artist: String = "Artist", album: String = "Album") -> Track {
        Track(id: id, title: title, artist: artist, album: album, duration: 200, isFavorited: false)
    }

    @Test func theSameIDIsTheSameSongWhateverElseDiffers() {
        #expect(track(id: "a").isSameSong(as: track(id: "a", title: "Renamed", artist: "Someone Else")))
    }

    @Test func aNewIDWithTheSameTitleAndArtistIsTheSameSong() {
        // Favoriting a streamed song adds it to the library, and Music can give it a new ID then.
        #expect(track(id: "a").isSameSong(as: track(id: "b")))
        #expect(track(id: "a", album: "Single").isSameSong(as: track(id: "b", album: "Deluxe Edition")))
    }

    @Test func aDifferentTitleOrArtistIsAnotherSong() {
        #expect(!track(id: "a").isSameSong(as: track(id: "b", title: "Another Song")))
        #expect(!track(id: "a").isSameSong(as: track(id: "b", artist: "Another Artist")))
    }

    @Test func aTrackWithoutATitleIsOnlyRecognisedByItsID() {
        let untitled = track(id: "a", title: "")
        #expect(!untitled.isSameSong(as: track(id: "b", title: "")))
        #expect(untitled.isSameSong(as: track(id: "a", title: "")))
    }

    @Test func theRuleIsSymmetric() {
        let pairs = [(track(id: "a"), track(id: "b")), (track(id: "a"), track(id: "b", title: "Another Song")),
                     (track(id: "a", title: ""), track(id: "b", title: ""))]
        for (one, other) in pairs {
            #expect(one.isSameSong(as: other) == other.isSameSong(as: one))
        }
    }
}

@Suite struct FavoriteSyncTests {
    @Test func theFirstLookComesAfterMusicsTenSecondSync() {
        #expect(FavoriteSync.recheckDelay > 10)
    }

    @Test func theStarStaysOffPastBothLooks() {
        #expect(FavoriteSync.unfavoriteHold > FavoriteSync.recheckDelay + FavoriteSync.secondLookDelay)
    }
}
