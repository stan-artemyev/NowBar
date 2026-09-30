import Foundation
import Testing
import NowBarCore
@testable import NowBarServices

/// What `nb_favorite` returns, and what the controller does with it and sends to it. The scripts that run here are
/// plain AppleScript that talks to no other application, so nothing touches Music.
@Suite struct MusicFavoriteResultTests {
    // MARK: Reading the result

    @Test func readsAWriteAndTheFlagReadBackAfterIt() {
        #expect(MusicFavoriteResult(.list([.bool(true), .bool(false)])) == MusicFavoriteResult(matched: true, favoritedAfter: false))
        #expect(MusicFavoriteResult(.list([.bool(true), .bool(true)])) == MusicFavoriteResult(matched: true, favoritedAfter: true))
    }

    @Test func readsAnUnmatchedTrackAsNothingWritten() {
        // {false, missing value}
        let result = MusicFavoriteResult(.list([.bool(false), .null]))
        #expect(result == MusicFavoriteResult(matched: false, favoritedAfter: nil))
        #expect(result?.matched == false)
        #expect(result?.favoritedAfter == nil)
    }

    @Test func aWriteWhoseFlagCouldNotBeReadBackIsStillAWrite() {
        // {true, missing value}
        let result = MusicFavoriteResult(.list([.bool(true), .null]))
        #expect(result == MusicFavoriteResult(matched: true, favoritedAfter: nil))
        #expect(result?.matched == true)
        #expect(MusicFavoriteResult(.list([.bool(true), .text("yes")]))?.favoritedAfter == nil)
    }

    @Test func aFlagIsIgnoredWhenNothingWasWritten() {
        #expect(MusicFavoriteResult(.list([.bool(false), .bool(true)]))?.favoritedAfter == nil)
        #expect(MusicFavoriteResult(matched: false, favoritedAfter: true).favoritedAfter == nil)
    }

    @Test func anythingElseIsNoAnswer() {
        #expect(MusicFavoriteResult(.null) == nil)   // `missing value`: Music wasn't running
        #expect(MusicFavoriteResult(.list([])) == nil)
        #expect(MusicFavoriteResult(.list([.bool(true)])) == nil)
        #expect(MusicFavoriteResult(.list([.bool(true), .bool(true), .bool(true)])) == nil)
        #expect(MusicFavoriteResult(.list([.null, .bool(true)])) == nil)
        #expect(MusicFavoriteResult(.list([.text("true"), .bool(true)])) == nil)
        #expect(MusicFavoriteResult(.list([.number(1), .number(0)])) == nil)
        #expect(MusicFavoriteResult(.bool(true)) == nil)
        #expect(MusicFavoriteResult(.text("true")) == nil)
        #expect(MusicFavoriteResult(.data(Data([1, 0]))) == nil)
    }

    @Test func readsWhatDescriptorsOfBooleansAndMissingValueGive() {
        // How the script's `{true, false}` and `{false, missing value}` arrive.
        let written = NSAppleEventDescriptor.list()
        written.insert(NSAppleEventDescriptor(boolean: true), at: 1)
        written.insert(NSAppleEventDescriptor(boolean: false), at: 2)
        #expect(MusicFavoriteResult(ScriptValue(written)) == MusicFavoriteResult(matched: true, favoritedAfter: false))

        let skipped = NSAppleEventDescriptor.list()
        skipped.insert(NSAppleEventDescriptor(boolean: false), at: 1)
        skipped.insert(NSAppleEventDescriptor(typeCode: fourCharCode("msng")), at: 2)
        #expect(MusicFavoriteResult(ScriptValue(skipped)) == MusicFavoriteResult(matched: false, favoritedAfter: nil))
    }

    @Test func readsWhatAppleScriptReturnsForThePair() async {
        // The same four shapes, straight from AppleScript's own literals through the runner.
        let source = """
        on nb_pair(caseNumber)
            if caseNumber is 1 then return {true, false}
            if caseNumber is 2 then return {true, true}
            if caseNumber is 3 then return {false, missing value}
            if caseNumber is 4 then return {true, missing value}
            return missing value
        end nb_pair
        """
        let runner = AppleScriptRunner()
        var results: [MusicFavoriteResult?] = []
        for caseNumber in 1...5 {
            let result = await runner.call("nb_pair", in: source, arguments: [.number(Double(caseNumber))])
            #expect(result.error == nil, "\(String(describing: result.error))")
            results.append(MusicFavoriteResult(result.value))
        }
        #expect(results == [
            MusicFavoriteResult(matched: true, favoritedAfter: false),
            MusicFavoriteResult(matched: true, favoritedAfter: true),
            MusicFavoriteResult(matched: false, favoritedAfter: nil),
            MusicFavoriteResult(matched: true, favoritedAfter: nil),
            nil,   // `missing value` alone: Music wasn't running
        ])
    }

    // MARK: What is logged

    @Test func logsTheBooleansOfAWrite() {
        #expect(MusicFavoriteResult(matched: true, favoritedAfter: false).logLine == "favorite write: matched=true favoritedAfter=false")
        #expect(MusicFavoriteResult(matched: true, favoritedAfter: true).logLine == "favorite write: matched=true favoritedAfter=true")
        #expect(MusicFavoriteResult(matched: true, favoritedAfter: nil).logLine == "favorite write: matched=true favoritedAfter=unknown")
    }

    @Test func logsASkippedWrite() {
        #expect(MusicFavoriteResult(matched: false, favoritedAfter: nil).logLine == "favorite skipped: the current track isn't the one clicked")
    }

    @Test func logsWhateverTheScriptReturned() {
        #expect(MusicFavoriteResult.logLine(for: .list([.bool(true), .bool(false)])) == "favorite write: matched=true favoritedAfter=false")
        #expect(MusicFavoriteResult.logLine(for: .list([.bool(false), .null])) == "favorite skipped: the current track isn't the one clicked")
        #expect(MusicFavoriteResult.logLine(for: .null) == "favorite write: no usable answer from Music")
        #expect(MusicFavoriteResult.logLine(for: .list([.text("x")])) == "favorite write: no usable answer from Music")
    }

    // MARK: What is sent

    let track = Track(id: "A1B2C3D4E5F60708", title: "Midnight Circuit", artist: "Neon Harbor", album: "Afterglow City", duration: 217, isFavorited: false)

    @Test func theFlagAndTheClickedTracksIDTitleAndArtistAreTypedArguments() {
        #expect(AppleMusicController.favoriteArguments(true, track: track)
                == [.bool(true), .text("A1B2C3D4E5F60708"), .text("Midnight Circuit"), .text("Neon Harbor")])
        #expect(AppleMusicController.favoriteArguments(false, track: track)
                == [.bool(false), .text("A1B2C3D4E5F60708"), .text("Midnight Circuit"), .text("Neon Harbor")])
    }

    @Test func onlyTheIDTitleAndArtistIdentifyTheClickedTrack() {
        // The rest of what a `Track` holds (album, duration, the star) isn't sent and plays no part in the match.
        var other = track
        other.album = "A Different Album"
        other.duration = 1
        other.isFavorited = true
        #expect(AppleMusicController.favoriteArguments(true, track: other) == AppleMusicController.favoriteArguments(true, track: track))
    }

    @Test func textInATrackReachesTheScriptAsDataNotAsScript() async {
        // A title or artist comes from the music library, so it can hold anything: quotes, line breaks, backslashes,
        // even AppleScript. It travels as a typed argument, so all of it arrives as the value it is.
        let hostile = Track(
            id: "\" & (do shell script \"echo pwned\") & \"",
            title: "Say \"hi\"\nend tell\ntell application \"Finder\" to quit \\ done",
            artist: "\u{201C}Curly\u{201D} \u{1F3B5}",
            album: "",
            duration: 0,
            isFavorited: false
        )
        let source = """
        on nb_echo(flag, idText, titleText, artistText)
            return {flag, idText, titleText, artistText}
        end nb_echo
        """
        let result = await AppleScriptRunner().call("nb_echo", in: source, arguments: AppleMusicController.favoriteArguments(false, track: hostile))
        #expect(result.error == nil, "\(String(describing: result.error))")
        #expect(result.value == .list([.bool(false), .text(hostile.id), .text(hostile.title), .text(hostile.artist)]))
    }

    @Test func aMissingTitleAndArtistArriveAsEmptyText() async {
        // The script doesn't recognise a track by an empty name (`expectedName is not ""`), which only works if
        // an empty title really arrives as empty text.
        let nameless = Track(id: "A1B2", title: "", artist: "", album: "", duration: 0, isFavorited: false)
        let source = """
        on nb_check(flag, idText, titleText, artistText)
            return {flag, idText, titleText is "", artistText is ""}
        end nb_check
        """
        let result = await AppleScriptRunner().call("nb_check", in: source, arguments: AppleMusicController.favoriteArguments(true, track: nameless))
        #expect(result.error == nil, "\(String(describing: result.error))")
        #expect(result.value == .list([.bool(true), .text("A1B2"), .bool(true), .bool(true)]))
    }
}
