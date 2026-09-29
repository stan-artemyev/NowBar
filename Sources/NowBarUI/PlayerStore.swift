import AppKit
import Foundation
import ImageIO
import NowBarCore
import Observation
import os

/// The single source of truth for the panel and the menu bar label.
///
/// It owns the player, volume and media key services, mirrors their state, applies
/// optimistic updates for user actions (the controller's next `onChange` confirms them;
/// a play/pause request additionally outranks contradicting snapshots for a moment, see `reconcile(_:)`)
/// and persists the user's settings.
@MainActor
@Observable
public final class PlayerStore {
    // MARK: State

    /// Latest reading of the player, including optimistic edits until the player confirms them.
    public private(set) var snapshot: PlayerSnapshot = .notRunning
    /// Artwork for the current track. nil means "show the placeholder tile".
    public private(set) var artwork: NSImage?
    /// The Mac's output volume, mirrored from `SystemVolumeControlling`.
    public private(set) var volume: SystemVolume
    /// Whether NowBar has Accessibility permission (media keys need it).
    public private(set) var mediaKeysTrusted: Bool

    // MARK: Settings (persisted with `SettingsKey`)

    public var layout: PanelLayout {
        didSet { defaults.set(layout.rawValue, forKey: SettingsKey.panelLayout) }
    }

    public var showTitleInMenuBar: Bool {
        didSet { defaults.set(showTitleInMenuBar, forKey: SettingsKey.showTitleInMenuBar) }
    }

    public var mediaKeysEnabled: Bool {
        didSet {
            defaults.set(mediaKeysEnabled, forKey: SettingsKey.mediaKeysEnabled)
            mediaKeys?.isEnabled = mediaKeysEnabled
            if mediaKeysEnabled { requestMediaKeyAccessIfFirstTime() }
        }
    }

    /// Backed by `SMAppService.mainApp`. When macOS refuses the change the toggle reverts and the error is logged.
    public var launchAtLogin: Bool {
        didSet {
            guard !isSyncingLaunchAtLogin, launchAtLogin != oldValue else { return }
            do {
                try launchAtLoginService.setEnabled(launchAtLogin)
            } catch {
                Self.log.error("Could not \(self.launchAtLogin ? "enable" : "disable") launch at login: \(error.localizedDescription, privacy: .public)")
                isSyncingLaunchAtLogin = true
                launchAtLogin = oldValue
                isSyncingLaunchAtLogin = false
            }
        }
    }

    // MARK: Panel visibility

    /// True while the panel is on screen and key. While true the store polls the player every 2 seconds.
    public var isPanelVisible = false {
        didSet {
            guard isPanelVisible != oldValue else { return }
            if isPanelVisible { panelDidAppear() } else { stopPolling() }
        }
    }

    // MARK: Dependencies and bookkeeping

    @ObservationIgnored private let player: PlayerController
    @ObservationIgnored private let volumeControl: SystemVolumeControlling
    @ObservationIgnored private let mediaKeys: MediaKeyIntercepting?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let launchAtLoginService: LaunchAtLoginControlling
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var isSyncingLaunchAtLogin = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Bumped on every change of `snapshot`, so a poll that was in flight during a newer change is dropped.
    @ObservationIgnored private var stateEpoch = 0
    /// The artwork load in flight, if any (nil once it has finished).
    @ObservationIgnored private(set) var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var artworkLoadID = 0
    /// When the last play/pause request that was acted on came in (see `playPause()`).
    @ObservationIgnored private var lastPlayPauseRequest: Date?
    /// The play/pause request the player hasn't confirmed yet (see `reconcile(_:)`).
    @ObservationIgnored private var playbackHold: PlaybackHold?

    /// Seconds between polls while the panel is visible. Tests shorten it.
    @ObservationIgnored var pollInterval: Duration = .seconds(2)
    /// Clock for optimistic updates, the play/pause debounce and the playback hold. Tests replace it.
    @ObservationIgnored var now: () -> Date = { Date() }

    /// A play/pause request that comes less than this many seconds after the previous one is ignored:
    /// a double click, a bouncing key. Skipping tracks is never debounced.
    static let playPauseDebounce: TimeInterval = 0.4
    /// How many seconds after a play/pause request a snapshot that contradicts it is treated as stale.
    static let playbackHoldDuration: TimeInterval = 1.5

    /// A play/pause request the player hasn't confirmed yet.
    private struct PlaybackHold {
        /// The state the request asked for.
        var target: PlaybackState
        /// The track it was made on.
        var trackID: String
        /// When the request stops outranking snapshots.
        var until: Date
    }

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NowBar", category: "PlayerStore")

    /// Longest menu bar title, in characters, including the ellipsis.
    public nonisolated static let menuBarTitleLimit = 32

    // MARK: Init

    public init(
        player: PlayerController,
        volume: SystemVolumeControlling,
        mediaKeys: MediaKeyIntercepting?,
        defaults: UserDefaults = .standard,
        launchAtLoginService: LaunchAtLoginControlling? = nil
    ) {
        self.player = player
        self.volumeControl = volume
        self.mediaKeys = mediaKeys
        self.defaults = defaults
        let loginItem = launchAtLoginService ?? MainAppLaunchAtLogin()
        self.launchAtLoginService = loginItem

        self.volume = volume.current
        self.mediaKeysTrusted = mediaKeys?.isTrusted ?? false
        self.layout = PanelLayout(rawValue: defaults.string(forKey: SettingsKey.panelLayout) ?? "") ?? .large
        self.showTitleInMenuBar = defaults.object(forKey: SettingsKey.showTitleInMenuBar) as? Bool ?? false
        self.mediaKeysEnabled = defaults.object(forKey: SettingsKey.mediaKeysEnabled) as? Bool ?? true
        self.launchAtLogin = loginItem.isEnabled
    }

    // MARK: Lifecycle

    /// Wires the services and starts them. Safe to call more than once; only the first call does anything.
    public func start() {
        guard !hasStarted else { return }
        hasStarted = true

        player.onChange = { [weak self] snapshot in self?.apply(snapshot) }
        volumeControl.onChange = { [weak self] volume in self?.volume = volume }
        mediaKeys?.onTrustChange = { [weak self] trusted in self?.mediaKeysTrusted = trusted }

        player.start()
        volumeControl.start()
        volume = volumeControl.current

        if let mediaKeys {
            // The handler goes in first, so an enabled tap never sees a key press without one.
            mediaKeys.handler = { [weak self] key in self?.handleMediaKey(key) ?? false }
            mediaKeys.isEnabled = mediaKeysEnabled
            mediaKeysTrusted = mediaKeys.isTrusted
            requestMediaKeyAccessIfFirstTime()
        }
    }

    /// Stops polling and the services. The store can be started again afterwards.
    public func stop() {
        guard hasStarted else { return }
        hasStarted = false
        stopPolling()
        artworkTask?.cancel()
        player.stop()
        volumeControl.stop()
        mediaKeys?.isEnabled = false
    }

    // MARK: Menu bar

    /// "Title · Artist", cut to `menuBarTitleLimit` characters with an ellipsis.
    /// nil when the setting is off or no track is loaded.
    public var menuBarTitle: String? {
        guard showTitleInMenuBar, snapshot.availability == .running, let track = snapshot.track else { return nil }
        return Self.menuBarTitle(for: track)
    }

    nonisolated static func menuBarTitle(for track: Track, limit: Int = PlayerStore.menuBarTitleLimit) -> String? {
        let text = [track.title, track.artist].filter { !$0.isEmpty }.joined(separator: " · ")
        guard !text.isEmpty else { return nil }
        guard text.count > limit else { return text }
        var head = String(text.prefix(max(limit - 1, 1)))
        while head.last?.isWhitespace == true { head.removeLast() }
        return head + "…"
    }

    // MARK: Media keys

    /// False when there is no key tap (`--demo`), so the menu can leave out the media key items.
    public var hasMediaKeyTap: Bool { mediaKeys != nil }

    /// Decides whether a media key press is consumed. Transport keys start their action and are consumed while
    /// the music app is running; volume keys are left to macOS, whose changes the volume row mirrors.
    public func handleMediaKey(_ key: MediaKey) -> Bool {
        guard mediaKeysEnabled, snapshot.availability == .running else { return false }
        switch key {
        case .playPause:
            playPause()
            return true
        case .next:
            next()
            return true
        case .previous:
            previous()
            return true
        case .mute, .volumeUp, .volumeDown:
            return false
        }
    }

    // MARK: Player actions

    /// The actions below apply their optimistic change immediately and return the task that talks to the player,
    /// which callers can ignore (or await, as the tests do).

    /// Pauses when the panel shows "playing" and plays otherwise: what the user sees is what they react to.
    /// The player is told exactly that (`pause()` or `play()`, never a toggle), so a repeated request can't
    /// flip playback back. A request that comes within `playPauseDebounce` of the previous one is ignored.
    /// The button, the space bar and the media key all come through here.
    @discardableResult
    public func playPause() -> Task<Void, Never> {
        guard snapshot.availability == .running else { return Task {} }
        let moment = now()
        if let last = lastPlayPauseRequest, moment.timeIntervalSince(last) < Self.playPauseDebounce {
            Self.log.debug("Ignored a play/pause request that came right after the previous one")
            return Task {}
        }
        lastPlayPauseRequest = moment

        let shouldPlay = snapshot.state != .playing
        if let track = snapshot.track {
            mutateSnapshot { snap in
                if shouldPlay {
                    snap.state = .playing
                } else {
                    // Freeze the bar where it is.
                    snap.position = snap.position(at: moment)
                    snap.state = .paused
                }
                snap.capturedAt = moment
            }
            playbackHold = PlaybackHold(
                target: shouldPlay ? .playing : .paused,
                trackID: track.id,
                until: moment.addingTimeInterval(Self.playbackHoldDuration)
            )
        }

        if shouldPlay {
            Self.log.info("play requested")
            return Task { [player] in await player.play() }
        }
        Self.log.info("pause requested")
        return Task { [player] in await player.pause() }
    }

    @discardableResult
    public func next() -> Task<Void, Never> {
        guard snapshot.availability == .running else { return Task {} }
        return Task { [player] in await player.nextTrack() }
    }

    @discardableResult
    public func previous() -> Task<Void, Never> {
        guard snapshot.availability == .running else { return Task {} }
        return Task { [player] in await player.previousTrack() }
    }

    /// Moves the playhead. The position is re-anchored at once so the progress bar doesn't jump back.
    @discardableResult
    public func seek(to seconds: TimeInterval) -> Task<Void, Never> {
        guard snapshot.availability == .running, let track = snapshot.track, seconds.isFinite else { return Task {} }
        var target = max(0, seconds)
        if track.duration > 0 { target = min(target, track.duration) }
        let moment = now()
        mutateSnapshot { snap in
            snap.position = target
            snap.capturedAt = moment
        }
        return Task { [player] in await player.seek(to: target) }
    }

    @discardableResult
    public func toggleFavorite() -> Task<Void, Never> {
        guard snapshot.availability == .running, let track = snapshot.track else { return Task {} }
        let favorited = !track.isFavorited
        mutateSnapshot { $0.track?.isFavorited = favorited }
        return Task { [player] in await player.setFavorited(favorited) }
    }

    public func openMusic() {
        player.openApp()
    }

    // MARK: Volume actions

    /// Sets the Mac's output volume (0...1). A level above 0 also unmutes.
    public func setVolume(_ level: Float) {
        guard volume.isAdjustable, level.isFinite else { return }
        let clamped = min(max(level, 0), 1)
        var updated = volume
        updated.level = clamped
        if clamped > 0 { updated.isMuted = false }
        volume = updated
        volumeControl.setLevel(clamped)
    }

    public func toggleMute() {
        guard volume.isAdjustable else { return }
        let muted = !volume.isMuted
        volume.isMuted = muted
        volumeControl.setMuted(muted)
    }

    // MARK: System actions

    public func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Shows the Accessibility prompt (or opens the right System Settings pane).
    public func requestMediaKeyAccess() {
        defaults.set(true, forKey: SettingsKey.didRequestMediaKeyAccess)
        mediaKeys?.requestTrust()
    }

    public func quit() {
        stop()
        NSApplication.shared.terminate(nil)
    }

    // MARK: Snapshot handling

    private func apply(_ incoming: PlayerSnapshot) {
        stateEpoch &+= 1
        let previousID = snapshot.track?.id
        let new = reconcile(incoming)
        if new != snapshot { snapshot = new }
        guard new.track?.id != previousID else { return }
        // The track changed: drop any load for the old one, then fetch the new artwork.
        artworkTask?.cancel()
        artworkTask = nil
        if let track = new.track {
            loadArtwork(for: track)
        } else {
            artwork = nil
        }
    }

    /// Music can still answer "playing" for a moment after it was told to pause (and the other way round),
    /// and the panel would flip back. So while a play/pause request is on hold, a snapshot for the same track
    /// that contradicts it (a push or a poll alike) is treated as stale: the state, position and capture time
    /// the request produced stay, and everything else (metadata, favorite, availability) comes from the snapshot.
    ///
    /// The hold ends when a snapshot confirms the request, when the track or the availability changes
    /// (whatever the user asked for no longer applies), and when `playbackHoldDuration` runs out (Music
    /// didn't do it, and the panel goes back to what Music says).
    private func reconcile(_ incoming: PlayerSnapshot) -> PlayerSnapshot {
        guard let hold = playbackHold else { return incoming }
        guard now() < hold.until, incoming.availability == .running, incoming.track?.id == hold.trackID else {
            playbackHold = nil
            return incoming
        }
        guard incoming.state != hold.target else {
            playbackHold = nil
            return incoming
        }
        var held = incoming
        held.state = snapshot.state
        held.position = snapshot.position
        held.capturedAt = snapshot.capturedAt
        return held
    }

    private func mutateSnapshot(_ change: (inout PlayerSnapshot) -> Void) {
        var copy = snapshot
        change(&copy)
        stateEpoch &+= 1
        snapshot = copy
    }

    // MARK: Artwork

    /// The previous artwork stays on screen until the new one arrives (the view cross-fades),
    /// and disappears when the new track has none.
    private func loadArtwork(for track: Track) {
        artworkTask?.cancel()
        artworkLoadID &+= 1
        let loadID = artworkLoadID
        artworkTask = Task { [weak self] in
            guard let self else { return }
            // A newer load may have taken over; only the latest one clears the slot.
            defer { if self.artworkLoadID == loadID { self.artworkTask = nil } }
            let data = await self.player.artwork(for: track)
            guard !Task.isCancelled else { return }
            let image = await ArtworkDecoder.decode(data)
            guard !Task.isCancelled, self.snapshot.track?.id == track.id else { return }
            self.artwork = image
        }
    }

    /// Streamed tracks can announce themselves before their artwork is ready; try again when the panel opens.
    private func retryMissingArtwork() {
        guard artwork == nil, let track = snapshot.track, artworkTask == nil else { return }
        loadArtwork(for: track)
    }

    // MARK: Polling

    private func panelDidAppear() {
        syncLaunchAtLogin()
        if let mediaKeys { mediaKeysTrusted = mediaKeys.isTrusted }
        retryMissingArtwork()
        startPolling()
    }

    private func startPolling() {
        pollTask?.cancel()
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func pollOnce() async {
        let epoch = stateEpoch
        let fresh = await player.refresh()
        // A push or a local change landed while the query was in flight: it is at least as new, so keep it.
        guard !Task.isCancelled, epoch == stateEpoch else { return }
        apply(fresh)
    }

    // MARK: Launch at login

    /// The user can change the login item in System Settings, so re-read it when the panel opens.
    private func syncLaunchAtLogin() {
        let actual = launchAtLoginService.isEnabled
        guard actual != launchAtLogin else { return }
        isSyncingLaunchAtLogin = true
        launchAtLogin = actual
        isSyncingLaunchAtLogin = false
    }

    // MARK: Media key access

    /// Prompts for Accessibility once, the first time media keys are on without permission.
    private func requestMediaKeyAccessIfFirstTime() {
        guard let mediaKeys, mediaKeysEnabled, !mediaKeys.isTrusted,
              !defaults.bool(forKey: SettingsKey.didRequestMediaKeyAccess) else { return }
        defaults.set(true, forKey: SettingsKey.didRequestMediaKeyAccess)
        mediaKeys.requestTrust()
    }
}

/// Decodes artwork off the main thread and shrinks oversized images to what the panel can show.
enum ArtworkDecoder {
    /// 272 pt at 2x, with a little headroom.
    static let maxPixelSize = 640

    static func decode(_ data: Data?) async -> NSImage? {
        guard let data, !data.isEmpty else { return nil }
        let cgImage = await Task.detached(priority: .userInitiated) { makeCGImage(from: data) }.value
        guard let cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    nonisolated static func makeCGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
