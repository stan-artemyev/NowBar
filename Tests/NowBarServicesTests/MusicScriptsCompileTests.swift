import Foundation
import Testing
@testable import NowBarServices

/// Compiles every script against Music's real scripting dictionary. Compiling reads the dictionary from the app
/// bundle; it never sends Music an Apple Event or launches it. A term Music doesn't know, or a syntax slip, fails
/// here instead of silently breaking every transport button at run time.
@Suite struct MusicScriptsCompileTests {
    @Test func everyScriptCompilesAgainstMusicsDictionary() async {
        // Compiled on the runner's queue: the AppleScript engine is only ever driven from that one queue.
        let runner = AppleScriptRunner()
        let scripts = [("query", MusicScripts.query), ("artwork", MusicScripts.artwork), ("control", MusicScripts.control)]
        for (name, source) in scripts {
            let failure: String? = await runner.perform {
                guard let script = NSAppleScript(source: source) else { return "the script could not be created" }
                var error: NSDictionary?
                return script.compileAndReturnError(&error) ? nil : String(describing: error)
            }
            #expect(failure == nil, "\(name) doesn't compile: \(failure ?? "")")
        }
    }
}
