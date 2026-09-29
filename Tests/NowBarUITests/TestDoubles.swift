import CoreGraphics
import Foundation
import ImageIO
import NowBarCore
@testable import NowBarUI

struct TestError: Error {}

/// A clock the test moves by hand. Set `PlayerStore.now` to `{ clock.current }` to control time.
final class TestClock {
    private(set) var current: Date

    init(_ start: Date) { current = start }

    func advance(by seconds: TimeInterval) {
        current = current.addingTimeInterval(seconds)
    }
}

/// A `PlayerController` that records calls and returns whatever the test sets up.
@MainActor
final class FakePlayer: PlayerController {
    var onChange: ((PlayerSnapshot) -> Void)?

    private(set) var calls: [String] = []
    private(set) var refreshCount = 0
    private(set) var artworkRequests: [String] = []

    var refreshResult: PlayerSnapshot = .notRunning
    var artworkByTrackID: [String: Data] = [:]
    var artworkDelays: [String: Duration] = [:]

    /// While true, `refresh()` suspends until `releaseHeldRefresh()`.
    var holdRefresh = false
    private(set) var heldRefresh: CheckedContinuation<Void, Never>?

    func start() { calls.append("start") }
    func stop() { calls.append("stop") }

    func refresh() async -> PlayerSnapshot {
        refreshCount += 1
        if holdRefresh {
            await withCheckedContinuation { heldRefresh = $0 }
        }
        return refreshResult
    }

    func releaseHeldRefresh() {
        heldRefresh?.resume()
        heldRefresh = nil
    }

    func artwork(for track: Track) async -> Data? {
        artworkRequests.append(track.id)
        if let delay = artworkDelays[track.id] {
            try? await Task.sleep(for: delay)
        }
        return artworkByTrackID[track.id]
    }

    func play() async { calls.append("play") }
    func pause() async { calls.append("pause") }
    func nextTrack() async { calls.append("nextTrack") }
    func previousTrack() async { calls.append("previousTrack") }
    func seek(to seconds: TimeInterval) async { calls.append("seek(\(seconds))") }
    func setFavorited(_ favorited: Bool) async { calls.append("setFavorited(\(favorited))") }
    func openApp() { calls.append("openApp") }

    /// What the real controller does after a track or state change: push a snapshot.
    func push(_ snapshot: PlayerSnapshot) { onChange?(snapshot) }
}

@MainActor
final class FakeVolume: SystemVolumeControlling {
    var onChange: ((SystemVolume) -> Void)?
    var current: SystemVolume
    private(set) var started = false
    private(set) var levelCalls: [Float] = []
    private(set) var muteCalls: [Bool] = []

    init(_ current: SystemVolume = SystemVolume(level: 0.5, isMuted: false, isAdjustable: true)) {
        self.current = current
    }

    func start() { started = true }
    func stop() { started = false }

    func setLevel(_ level: Float) {
        levelCalls.append(level)
        current.level = level
        if level > 0 { current.isMuted = false }
    }

    func setMuted(_ muted: Bool) {
        muteCalls.append(muted)
        current.isMuted = muted
    }

    /// A change made outside the app: the keyboard volume keys, Control Center, another output device.
    func simulateSystemChange(_ volume: SystemVolume) {
        current = volume
        onChange?(volume)
    }
}

@MainActor
final class FakeMediaKeys: MediaKeyIntercepting {
    var handler: ((MediaKey) -> Bool)?
    var isTrusted: Bool
    var onTrustChange: ((Bool) -> Void)?
    var isEnabled = false
    private(set) var requestTrustCount = 0

    init(trusted: Bool) { isTrusted = trusted }

    func requestTrust() { requestTrustCount += 1 }

    /// A physical key press: what the event tap would do.
    func press(_ key: MediaKey) -> Bool { handler?(key) ?? false }
}

@MainActor
final class FakeLaunchAtLogin: LaunchAtLoginControlling {
    var isEnabled: Bool
    var error: Error?
    private(set) var attempts: [Bool] = []

    init(isEnabled: Bool = false) { self.isEnabled = isEnabled }

    func setEnabled(_ enabled: Bool) throws {
        attempts.append(enabled)
        if let error { throw error }
        isEnabled = enabled
    }
}

enum Fixture {
    static let track = Track(id: "t1", title: "Midnight Circuit", artist: "Neon Harbor", album: "Afterglow City", duration: 217, isFavorited: false)

    static func running(
        _ state: PlaybackState = .playing,
        track: Track = Fixture.track,
        position: TimeInterval = 84,
        capturedAt: Date = Date()
    ) -> PlayerSnapshot {
        PlayerSnapshot(availability: .running, state: state, track: track, position: position, capturedAt: capturedAt)
    }

    static func track(id: String, title: String = "Title", artist: String = "Artist", favorited: Bool = false) -> Track {
        Track(id: id, title: title, artist: artist, album: "Album", duration: 200, isFavorited: favorited)
    }

    /// A solid PNG of the given pixel size, to tell artwork apart by size.
    static func png(size: Int) -> Data {
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

/// A store wired to fakes, on in-memory settings (so no preference files are created).
@MainActor
final class Harness {
    let player = FakePlayer()
    let volume = FakeVolume()
    let mediaKeys: FakeMediaKeys
    let login: FakeLaunchAtLogin
    let defaults: UserDefaults
    let store: PlayerStore

    init(
        mediaKeysTrusted: Bool = true,
        launchAtLogin: Bool = false,
        defaults existing: UserDefaults? = nil,
        configure: (UserDefaults) -> Void = { _ in }
    ) {
        mediaKeys = FakeMediaKeys(trusted: mediaKeysTrusted)
        login = FakeLaunchAtLogin(isEnabled: launchAtLogin)
        defaults = existing ?? EphemeralDefaults()
        configure(defaults)
        store = PlayerStore(player: player, volume: volume, mediaKeys: mediaKeys, defaults: defaults, launchAtLoginService: login)
    }

    /// A second store on the same settings, as after relaunching the app.
    func relaunch(mediaKeysTrusted: Bool = true) -> Harness {
        Harness(mediaKeysTrusted: mediaKeysTrusted, defaults: defaults)
    }

    /// Starts the store and delivers a snapshot, like the controller's initial push.
    func startAndPush(_ snapshot: PlayerSnapshot) {
        store.start()
        player.push(snapshot)
    }
}

/// Polls `condition` until it holds or the timeout passes. For effects that happen in other tasks.
@MainActor
@discardableResult
func eventually(timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
