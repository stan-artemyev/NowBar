import AppKit
import NowBarCore
import SwiftUI

/// Renders the panel to PNGs for visual checks, with demo data only:
/// large playing / paused / favorited, compact playing, not running, not authorized and nothing playing,
/// each in light and dark, plus a few edge cases (long titles, muted volume, live streams).
/// The five demo covers are written too (`demo-cover-1.png` ...).
///
/// The real panel sits on the system material; snapshots use an opaque stand-in for it
/// (#F2F2F5 in light, #2B2B2E in dark, 18 pt corners) and are drawn at 2x.
public enum SnapshotRenderer {
    public enum RenderError: Error, CustomStringConvertible {
        case renderFailed(String)

        public var description: String {
            switch self {
            case .renderFailed(let name): "Could not render \(name)"
            }
        }
    }

    /// Scenario names, e.g. "large-playing". Files are `<name>-light.png` and `<name>-dark.png`.
    public static var scenarioNames: [String] { SnapshotScenario.allCases.map(\.rawValue) }

    /// Renders every scenario in light and dark into `directory` and returns the files written.
    @MainActor
    public static func renderAll(to directory: URL) async throws -> [URL] {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        var written: [URL] = []
        // The demo covers at full size, to judge them without the panel around them.
        for cover in 0..<DemoArtwork.coverCount {
            guard let png = DemoArtwork.pngData(forCover: cover) else { throw RenderError.renderFailed("cover \(cover + 1)") }
            let url = directory.appendingPathComponent("demo-cover-\(cover + 1).png")
            try png.write(to: url)
            written.append(url)
        }
        for scenario in SnapshotScenario.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let name = "\(scenario.rawValue)-\(scheme == .dark ? "dark" : "light")"
                guard let png = await render(scenario, scheme: scheme, now: now) else {
                    throw RenderError.renderFailed(name)
                }
                let url = directory.appendingPathComponent("\(name).png")
                try png.write(to: url)
                written.append(url)
            }
        }
        return written
    }

    @MainActor
    static func render(_ scenario: SnapshotScenario, scheme: ColorScheme, now: Date) async -> Data? {
        // In-memory settings: rendering must not leave preference files behind.
        let store = scenario.makeStore(defaults: EphemeralDefaults(), now: now)
        store.start()
        await store.artworkTask?.value   // wait for the artwork to load and decode
        defer { store.stop() }

        let renderer = ImageRenderer(content: SnapshotFrame(store: store, scheme: scheme, now: now))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

/// The panel on an opaque stand-in for the glass.
private struct SnapshotFrame: View {
    let store: PlayerStore
    let scheme: ColorScheme
    let now: Date

    var body: some View {
        let glass = scheme == .dark
            ? Color(red: 0x2B / 255, green: 0x2B / 255, blue: 0x2E / 255)
            : Color(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF5 / 255)
        PlayerPanel(store: store)
            .environment(\.panelRenderContext, PanelRenderContext(isSnapshot: true, now: now))
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(glass))
            .environment(\.colorScheme, scheme)
    }
}

enum SnapshotScenario: String, CaseIterable {
    case largePlaying = "large-playing"
    case largePaused = "large-paused"
    case largeFavorited = "large-favorited"
    case compactPlaying = "compact-playing"
    case notRunning = "not-running"
    case notAuthorized = "not-authorized"
    case nothingPlaying = "nothing-playing"
    // Edge cases.
    case largeLongTitle = "large-long-title"
    case compactLongTitle = "compact-long-title"
    case largeLive = "large-live"
    case largeMuted = "large-muted"
    case compactNotAuthorized = "compact-not-authorized"
    case compactNothingPlaying = "compact-nothing-playing"

    @MainActor
    func makeStore(defaults: UserDefaults, now: Date) -> PlayerStore {
        var layout = PanelLayout.large
        var volume = DemoSystemVolume(level: 0.6)
        let player: DemoPlayerController

        switch self {
        case .largePlaying:
            player = DemoPlayerController(availability: .running, state: .playing, trackIndex: 0, position: 84, capturedAt: now)
        case .largePaused:
            player = DemoPlayerController(availability: .running, state: .paused, trackIndex: 0, position: 84, capturedAt: now)
        case .largeFavorited:
            player = DemoPlayerController(availability: .running, state: .playing, trackIndex: 2, position: 62, isFavorited: true, capturedAt: now)
        case .compactPlaying:
            layout = .compact
            player = DemoPlayerController(availability: .running, state: .playing, trackIndex: 1, position: 96, capturedAt: now)
        case .notRunning:
            player = DemoPlayerController(availability: .notRunning, state: .stopped, capturedAt: now)
        case .notAuthorized:
            player = DemoPlayerController(availability: .notAuthorized, state: .stopped, capturedAt: now)
        case .nothingPlaying:
            player = DemoPlayerController(availability: .running, state: .stopped, capturedAt: now)
        case .largeLongTitle, .compactLongTitle:
            layout = self == .compactLongTitle ? .compact : .large
            let track = Track(
                id: "demo-long", title: "The Extraordinarily Long and Winding Title of a Very Patient Song",
                artist: "Someone With A Rather Long Name & The Friends Of Somebody Else",
                album: "An Album Whose Name Also Goes On For Quite A While", duration: 3725, isFavorited: true
            )
            player = DemoPlayerController(fixedTrack: track, cover: 3, state: .playing, position: 1234, capturedAt: now)
        case .largeLive:
            let track = Track(id: "demo-live", title: "Neon Harbor Radio", artist: "Live", album: "", duration: 0, isFavorited: false)
            player = DemoPlayerController(fixedTrack: track, cover: 0, state: .playing, position: 0, capturedAt: now)
        case .largeMuted:
            volume = DemoSystemVolume(level: 0.6, isMuted: true)
            player = DemoPlayerController(availability: .running, state: .playing, trackIndex: 3, position: 150, capturedAt: now)
        case .compactNotAuthorized:
            layout = .compact
            player = DemoPlayerController(availability: .notAuthorized, state: .stopped, capturedAt: now)
        case .compactNothingPlaying:
            layout = .compact
            player = DemoPlayerController(availability: .running, state: .stopped, capturedAt: now)
        }

        let store = PlayerStore(player: player, volume: volume, mediaKeys: nil, defaults: defaults, launchAtLoginService: StaticLaunchAtLogin())
        store.layout = layout
        return store
    }
}

/// Snapshots never touch the real login items.
@MainActor
private final class StaticLaunchAtLogin: LaunchAtLoginControlling {
    var isEnabled = false
    func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}
