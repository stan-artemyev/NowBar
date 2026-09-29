# NowBar

A macOS menu bar mini-player for Apple Music. Click the music note in the menu bar to see what's playing and control it without switching to the Music app.

## Features

- A music-note menu bar icon, optionally with "Title · Artist" beside it.
- A panel with the artwork, title / artist / album, a favorite star, a draggable progress bar, previous / play-pause / next, and a volume row with a mute button for the Mac's output volume.
- Two layouts, Large Artwork or Compact, chosen in the ⋯ menu. The ⋯ menu also holds Open Apple Music, Show Title in Menu Bar, Media Keys Control Apple Music, Launch at Login and Quit.
- Optional media key handling: previous / play-pause / next always go to Apple Music while it is running, even when a browser tab is playing.
- Talks to Apple Music with Apple Events. NowBar never launches Music on its own.
- No Dock icon. Settings are stored in UserDefaults.
- A demo mode with a fake playlist, for trying it without Music.

## Requirements

- macOS 14 or later
- Apple Music (the Music app)
- To build: Xcode, or the Command Line Tools (`xcode-select --install`), with Swift 6

## Build, install and uninstall

```sh
make app       # release build, packaged and signed as build/NowBar.app
make install   # the same, then installs to /Applications/NowBar.app and launches it
```

Both use `scripts/build-app.sh`, which builds the `NowBar` product in release mode (for the architecture of the Mac you build on), assembles `build/NowBar.app` from the binary, `Resources/Info.plist` and `Resources/AppIcon.icns`, signs it and checks the signature with `codesign --verify --strict`. It works from any directory and prints the final app path and the signing identity it used.

| Option or variable | Effect |
| --- | --- |
| `--install` | Also copy the app to `/Applications/NowBar.app`, replacing any earlier copy. If `/Applications` isn't writable for your account (a standard user, say), it goes to `~/Applications/NowBar.app` instead and the script says so. |
| `--open` | Launch the result: the installed copy with `--install`, otherwise `build/NowBar.app`. |
| `--demo` | Launch with `--demo`; implies `--open`. |
| `NOWBAR_BINARY=/path` | Bundle this prebuilt executable instead of running `swift build`. |
| `SIGN_IDENTITY="..."` | Sign with this identity instead of ad-hoc. |
| `NOWBAR_INSTALL_DIR=/path` | Install somewhere other than `/Applications`. The folder is used as given: if it isn't writable, the script stops with an error instead of falling back to `~/Applications`. |

`--install` and `--open` first quit a running NowBar (`pkill -x NowBar`) and wait for it to exit. Otherwise the old build would keep running, and `open` would only bring it to the front and ignore `--demo`.

Earlier versions installed to `~/Applications`. Once the new copy is in place, `--install` moves an old `~/Applications/NowBar.app` to the Trash (it never deletes it) and says so. If the move fails, the script warns and leaves the old copy where it is, so drag it to the Trash yourself. Nothing is moved when `~/Applications` is where the new copy went.

Installing to a new location can make macOS ask for the Accessibility and Automation permissions again, just as a rebuild does: see First run and permissions.

To uninstall:

```sh
pkill -x NowBar                                  # if it is running
rm -rf /Applications/NowBar.app                  # or drag it to the Trash
rm -rf ~/Applications/NowBar.app                 # only if an earlier install or the fallback put it there
defaults delete local.nowbar.NowBar              # saved settings (errors if there are none)
tccutil reset AppleEvents local.nowbar.NowBar    # forget the Automation permission
tccutil reset Accessibility local.nowbar.NowBar  # forget the Accessibility permission
```

Turn off Launch at Login in the ⋯ menu before removing the app.

## First run and permissions

NowBar needs two macOS permissions. It starts without either.

**Automation (Apple Music).** The first time NowBar talks to a running Music app, macOS asks whether "NowBar wants to control Music". Choose OK. NowBar never launches Music itself, so start Music first, or use ⋯ → Open Apple Music. If you deny the request, the panel explains how to fix it: open System Settings → Privacy & Security → Automation and switch Music on under NowBar.

**Accessibility (media keys).** Intercepting the media keys needs Accessibility permission. NowBar asks for it once. If you dismissed the request, open System Settings → Privacy & Security → Accessibility and switch NowBar on (use + to add it if it isn't listed). Without this permission the panel works as usual and the media keys keep going to macOS.

**Rebuilds and moves make macOS forget both grants.** `scripts/build-app.sh` signs ad-hoc by default, and an ad-hoc signature identifies the app only by a hash of its code (`codesign -d -r- build/NowBar.app` prints `designated => cdhash H"..."`). Every rebuild is therefore a different app to macOS, which forgets the Automation and Accessibility grants and can leave stale entries in the lists. Moving the app to a new location can do the same: for example, `make install` puts it in `/Applications`, so after an earlier install in `~/Applications` you grant both again. After rebuilding or moving the app, clear them and grant again when prompted:

```sh
tccutil reset AppleEvents local.nowbar.NowBar
tccutil reset Accessibility local.nowbar.NowBar
```

Signing with a stable certificate (`SIGN_IDENTITY="Name of a code-signing certificate" make app`) should let the grants survive rebuilds. That path is untested: no signing identities were available when this was written.

## Media keys

With Accessibility permission and Media Keys Control Apple Music turned on in the ⋯ menu:

- Previous, play/pause and next always go to Apple Music while it is running, even if a browser tab is playing.
- When Music isn't running, macOS handles those keys as usual.
- Mute and the volume keys keep controlling the Mac's volume, and the panel's volume row mirrors them.

Turn Media Keys Control Apple Music off in the ⋯ menu to stop NowBar intercepting the keys.

## Settings

Everything is stored in UserDefaults under the bundle identifier `local.nowbar.NowBar` (`defaults read local.nowbar.NowBar`).

| Key | Values | Default |
| --- | --- | --- |
| `panelLayout` | `large` or `compact` | `large` |
| `showTitleInMenuBar` | Bool | `false` (icon only) |
| `mediaKeysEnabled` | Bool | `true` |
| `didRequestMediaKeyAccess` | Bool, set once NowBar has asked for Accessibility permission, so it only prompts automatically once | `false` |

## Demo mode and snapshots

`make demo` builds the app and opens it with `--demo`: a fake playlist, so Music isn't needed. To do it by hand, quit NowBar first and run `open build/NowBar.app --args --demo`.

`make snapshots` (`swift run NowBarSnapshots build/snapshots`) renders the panel to PNGs in `build/snapshots`, for checking the layout without running the app.

## Development

```sh
make help        # list the targets
make build       # debug build
make test        # run the tests
make snapshots   # render panel PNGs
make icon        # regenerate Resources/AppIcon.icns
make clean       # remove .build, build and .build-*
```

The tests use Swift Testing. With only the Command Line Tools installed, the compiler needs the Testing macro plugin on its plugin path, which `make test` adds:

```sh
swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

### Project layout

| Path | Contents |
| --- | --- |
| `Package.swift` | Package manifest: macOS 14, Swift 6 tools, Swift 5 language mode. |
| `Sources/NowBarCore` | Shared models and service contracts (Foundation only). |
| `Sources/NowBarServices` | macOS integrations: the Apple Music bridge, system output volume, media keys. |
| `Sources/NowBarUI` | SwiftUI panel, menu bar label, observable store and settings. |
| `Sources/NowBar` | The menu bar app executable: wires the services into the UI. |
| `Tools/NowBarSnapshots` | Executable that renders the panel to PNGs. |
| `Tests/` | Swift Testing suites, one per library target. |
| `Resources/` | `Info.plist` (bundle id, `LSUIElement` for no Dock icon, the Automation usage text) and the generated `AppIcon.icns`. |
| `scripts/build-app.sh` | Builds, bundles, signs and optionally installs and launches the app. |
| `scripts/make-icon.swift` | Draws the icon and writes `Resources/AppIcon.icns` (intermediates go to `.build-pkg/`). |
| `design/prototype.html` | HTML prototype of the panel's look; open it in a browser. |
| `Makefile` | Shortcuts for all of the above. |
| `build/` | Output: `NowBar.app` and `snapshots/`. Not tracked by git. |

## Troubleshooting

**The panel says NowBar can't control Music.** Automation was denied. Switch Music on under NowBar in System Settings → Privacy & Security → Automation. If NowBar isn't listed, or macOS never asks again, run `tccutil reset AppleEvents local.nowbar.NowBar` and relaunch NowBar.

**The media keys still go to the browser or to macOS.** Check that NowBar is switched on under System Settings → Privacy & Security → Accessibility, that Media Keys Control Apple Music is on in the ⋯ menu, and that Music is running (with Music closed, macOS handles the keys). After a rebuild, run `tccutil reset Accessibility local.nowbar.NowBar`, relaunch NowBar and grant the permission again.

**Nothing is playing and Play does nothing.** NowBar never launches Music on its own. Start it, or use ⋯ → Open Apple Music.

**Clicking the star shows "To add songs and playlists to your Library, you must use Cloud Music Library".** That dialog is Apple Music's own, not NowBar's. Favoriting a song adds it to your library, which needs Sync Library to be on (Music → Settings → General), and Music's own star behaves the same way. Choose Merge Library to turn Sync Library on, or Not Now to skip it; the star then turns itself back off within about 10 seconds, because Music didn't favorite the song. Even with Sync Library on, Music takes a few seconds to save a favorite; the star stays on while it does. Sync Library covers your whole music library, not just NowBar, so turn it on only if you want that.

**The artwork is a placeholder.** Apple Music doesn't expose artwork for some streamed tracks, so NowBar shows a placeholder. Known limitation.

**The volume row can't change the volume.** Some outputs, such as certain HDMI or USB devices, have no adjustable volume, so there is nothing for NowBar to change.

**There is no menu bar icon.** Check that NowBar is running (`pgrep -x NowBar`). If it is, the menu bar may be too crowded to show it; free up some space.

**`swift test` can't find the Testing macros.** Use `make test`, which passes the plugin path (see Development).

**`make install` says NowBar is still running.** It waits ten seconds after asking NowBar to quit. Quit it from the ⋯ menu and run it again.
