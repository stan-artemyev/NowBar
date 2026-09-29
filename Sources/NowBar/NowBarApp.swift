import AppKit
import NowBarCore
import NowBarServices
import NowBarUI
import SwiftUI

/// NowBar: a menu bar mini-player for Apple Music.
///
/// `NowBar --demo` runs against a fictional playlist and a fake volume, without touching Music,
/// the media keys or the Mac's real volume.
@main
struct NowBarApp: App {
    /// Created and started once, when the app launches.
    private let store: PlayerStore

    init() {
        // A menu bar app has no Dock icon. The app bundle says so too (LSUIElement);
        // this also covers running the bare executable.
        NSApplication.shared.setActivationPolicy(.accessory)

        let store = Self.makeStore()
        store.start()
        self.store = store
    }

    var body: some Scene {
        MenuBarExtra {
            PlayerPanel(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }

    private static func makeStore() -> PlayerStore {
        if CommandLine.arguments.contains("--demo") {
            return PlayerStore(player: DemoPlayerController(), volume: DemoSystemVolume(), mediaKeys: nil)
        }
        return PlayerStore(player: AppleMusicController(), volume: SystemVolumeController(), mediaKeys: MediaKeyTap())
    }
}
