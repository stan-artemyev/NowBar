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
