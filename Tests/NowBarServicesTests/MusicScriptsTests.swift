import Foundation
import Testing
import NowBarCore
@testable import NowBarServices

/// The scripts are text that gets sent to Music, so these only read that text. Nothing here runs a script or
/// talks to Music.
@Suite struct MusicScriptsTests {
    let musicTarget = "tell application id \"\(MusicApp.bundleIdentifier)\""

    /// The handlers of `script` by name. Each value holds the handler's trimmed lines, from its `on nb_…(` line
    /// up to the next handler.
    func handlers(in script: String) -> [String: String] {
        var result: [String: String] = [:]
        var name: String?
        for line in script.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("on nb_"), let paren = text.firstIndex(of: "(") {
                name = String(text[text.index(text.startIndex, offsetBy: 3)..<paren])
            }
            if let name { result[name, default: ""] += text + "\n" }
        }
        return result
    }

    /// The lines of a handler (as `handlers(in:)` gives it) that are code: no comments and no blank lines.
    func codeLines(of handler: String) -> [String] {
        handler.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("--") && !$0.isEmpty }
    }

    /// Whether `lines` contains `run` as consecutive lines.
    func contains(_ run: [String], in lines: [String]) -> Bool {
        lines.indices.contains { lines[$0...].starts(with: run) }
    }

    @Test func definesEveryHandlerTheControllerCalls() {
        let control = handlers(in: MusicScripts.control)
        for name in ["nb_play", "nb_pause", "nb_next", "nb_previous", "nb_seek", "nb_favorite"] {
            #expect(control[name] != nil, "\(name) is missing from the control script")
        }
        #expect(handlers(in: MusicScripts.query)["nb_query"] != nil)
        #expect(handlers(in: MusicScripts.artwork)["nb_artwork"] != nil)
    }

    @Test func playAndPauseAreSeparateCommandsNotAToggle() {
        let control = handlers(in: MusicScripts.control)
        // `play` is sent only when Music isn't already playing, so it can never restart the track.
        #expect(control["nb_play"]?.contains("if player state is not playing then play\n") == true)
        #expect(control["nb_pause"]?.contains("\(musicTarget) to pause\n") == true)
        // A toggle flips playback back whenever a command is repeated or arrives late.
        #expect(control["nb_playpause"] == nil)
        #expect(!MusicScripts.control.contains("playpause"))
    }

    // MARK: nb_favorite

    /// The lines of code of the favorite handler.
    var favoriteCode: [String] { codeLines(of: handlers(in: MusicScripts.control)["nb_favorite"] ?? "") }

    @Test func favoriteTakesTheFlagAndTheClickedTracksIDNameAndArtist() {
        let favorite = handlers(in: MusicScripts.control)["nb_favorite"] ?? ""
        #expect(favorite.hasPrefix("on nb_favorite(shouldFavorite, expectedID, expectedName, expectedArtist)\n"))
    }

    @Test func favoriteRecognisesTheClickedTrackByItsIDOrByItsNameAndArtist() {
        // Music can give a streamed song a new ID when favoriting adds it to the library. So the current track is
        // the clicked one if its persistent ID is the expected one, or else if its name and its artist both are.
        // Each is read in a `try` of its own, so a track whose ID can't be read can still be recognised by its name.
        let code = favoriteCode
        let byID = code.firstIndex { $0.contains("(persistent ID of current track) is expectedID") && $0.hasSuffix("set isClicked to true") }
        let byName = code.firstIndex {
            $0.contains("(name of current track) is expectedName") && $0.contains(" and ")
                && $0.contains("(artist of current track) is expectedArtist") && $0.hasSuffix("set isClicked to true")
        }
        // A track without a name isn't recognised by name: two nameless tracks would look alike. And once the ID
        // has matched there is nothing left to decide.
        let onlyWhenNamed = code.firstIndex { $0.hasPrefix("if (not isClicked) and (expectedName is not \"\")") }
        guard let byID, let byName, let onlyWhenNamed else {
            Issue.record("the favorite handler lost its match by ID, by name and artist, or the guard in front of the second")
            return
        }
        #expect(byID < onlyWhenNamed)
        #expect(onlyWhenNamed < byName)
    }

    @Test func favoriteWritesOnlyBehindTheMatchAndOnTheCurrentTrackItself() {
        let code = favoriteCode
        let write = "set favorited of current track to shouldFavorite"
        // Exactly one write, in the form that works when typed by hand: not through a reference kept in a variable.
        #expect(code.filter { $0.hasPrefix("set favorited ") } == [write])
        #expect(!code.contains { $0.hasPrefix("set t ") })
        #expect(!code.contains { $0.range(of: #" of t\b"#, options: .regularExpression) != nil })

        // It sits right behind the check that leaves the handler when the track wasn't recognised, and that check
        // comes after the match.
        let leave = "if not isClicked then return {false, missing value}"
        guard let leaveIndex = code.firstIndex(of: leave),
              let matchIndex = code.firstIndex(where: { $0.contains("(persistent ID of current track) is expectedID") }),
              let writeIndex = code.firstIndex(of: write) else {
            Issue.record("the favorite handler lost its match, its exit or its write")
            return
        }
        #expect(matchIndex < leaveIndex)
        #expect(writeIndex == leaveIndex + 1)
    }

    @Test func favoriteReturnsTheMatchAndTheFlagReadBackAfterTheWrite() {
        // {matched, favoritedAfter}: two booleans, or `missing value` for the flag when nothing was written.
        let code = favoriteCode
        #expect(code.contains("if not isClicked then return {false, missing value}"))
        guard let writeIndex = code.firstIndex(of: "set favorited of current track to shouldFavorite"),
              let readIndex = code.firstIndex(of: "set favoritedAfter to favorited of current track"),
              let returnIndex = code.firstIndex(of: "return {true, favoritedAfter}") else {
            Issue.record("the favorite handler doesn't read the flag back after its write and return it")
            return
        }
        #expect(writeIndex < readIndex)
        #expect(readIndex < returnIndex)
        // Like the other handlers, `missing value` alone when Music isn't running.
        #expect(code.suffix(3) == ["end timeout", "return missing value", "end nb_favorite"])
    }

    @Test func favoriteNeverSplicesTextIntoTheScript() {
        let code = favoriteCode
        let text = code.joined(separator: "\n")
        // The four arguments are used as variables: never inside quotes, never joined to text with `&`. The only
        // quoted text is Music's bundle identifier and the empty string.
        let unquoted = text
            .replacingOccurrences(of: "\"\(MusicApp.bundleIdentifier)\"", with: "")
            .replacingOccurrences(of: "\"\"", with: "")
        #expect(!unquoted.contains("\""))
        #expect(!text.contains("&"))
        #expect(!text.contains("run script"))
        #expect(!text.contains("do shell script"))
        for argument in ["shouldFavorite", "expectedID", "expectedName", "expectedArtist"] {
            #expect(code.dropFirst().contains { $0.contains(argument) }, "\(argument) isn't used")
        }
    }

    @Test func favoriteHasNoVariableThatIsATermOfMusicsDictionary() {
        // `matched` is one of Music's cloud status values, so inside `tell application "Music"` it can't serve as a
        // variable name: a script that tries won't work, and the click would do nothing.
        #expect(!favoriteCode.joined(separator: "\n").lowercased().contains("matched"))
    }

    @Test func everyScriptThatRethrowsDefinesTheHelper() {
        // `nb_favorite` rethrows the failures that mean "stop now", so the control script needs the helper too.
        #expect(handlers(in: MusicScripts.control)["nb_rethrow"] != nil)
        for (label, script) in [("query", MusicScripts.query), ("artwork", MusicScripts.artwork), ("control", MusicScripts.control)]
        where script.contains("my nb_rethrow(") {
            #expect(handlers(in: script)["nb_rethrow"] != nil, "\(label) calls nb_rethrow but doesn't define it")
        }
    }

    @Test func artworkChecksTheTrackIDToo() {
        // The pattern favorite follows: the ID is checked in the same script that does the work.
        let artwork = handlers(in: MusicScripts.artwork)["nb_artwork"] ?? ""
        #expect(artwork.hasPrefix("on nb_artwork(expectedID)\n"))
        #expect(artwork.contains("if (persistent ID of t) is not expectedID then return missing value\n"))
    }

    @Test func everyHandlerThatTalksToMusicIsGuarded() {
        let scripts = [("query", MusicScripts.query), ("artwork", MusicScripts.artwork), ("control", MusicScripts.control)]
        var checked = 0
        for (label, script) in scripts {
            for (name, text) in handlers(in: script) where text.contains("tell application id") {
                checked += 1
                #expect(text.contains("with timeout of 3 seconds"), "\(label): \(name) has no timeout")
                #expect(text.contains("if application id \"\(MusicApp.bundleIdentifier)\" is running then"),
                        "\(label): \(name) doesn't check that Music is running")
            }
        }
        // query, artwork and the six control handlers; guards against the parsing above finding nothing.
        #expect(checked >= 8)
    }
}
