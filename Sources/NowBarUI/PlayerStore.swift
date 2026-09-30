import AppKit
import Foundation
import ImageIO
import NowBarCore
import Observation
import os
import UniformTypeIdentifiers

/// The single source of truth for the panel and the menu bar label.
///
/// It owns the player, volume and media key services, mirrors their state, applies
/// optimistic updates for user actions (the controller's next `onChange` confirms them;
/// a play/pause or favorite request additionally outranks contradicting snapshots for a while, see `reconcile(_:)`)
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

    /// Off by default: macOS already sends the media keys to Music while Music was the last thing to play. Turning
    /// this on makes NowBar take them over, which needs Accessibility permission, so that is the only time NowBar
    /// asks for it: every time the option is switched on while NowBar isn't trusted, and never at launch.
    public var mediaKeysEnabled: Bool {
        didSet {
            defaults.set(mediaKeysEnabled, forKey: SettingsKey.mediaKeysEnabled)
            mediaKeys?.isEnabled = mediaKeysEnabled
            if mediaKeysEnabled, !oldValue, let mediaKeys, !mediaKeys.isTrusted { requestMediaKeyAccess() }
        }
    }

    /// Backed by `SMAppService.mainApp`. When macOS refuses the change the toggle reverts and the error is logged.
    public var launchAtLogin: Bool {
        didSet {
            guard !isSyncingLaunchAtLogin, launchAtLogin != oldValue else { return }
            do {
                try launchAtLoginService.setEnabled(launchAtLogin)
            } catch {
                // The words "enable" and "disable" are ours; the system's error text isn't, so it stays private.
                Self.log.error("Could not \(self.launchAtLogin ? "enable" : "disable", privacy: .public) launch at login: \(error.localizedDescription)")
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
    /// The favorite request the player hasn't confirmed yet (see `reconcile(_:)`).
    @ObservationIgnored private var favoriteHold: FavoriteHold?

    /// Seconds between polls while the panel is visible. Tests shorten it.
    @ObservationIgnored var pollInterval: Duration = .seconds(2)
    /// Clock for optimistic updates, the play/pause debounce and the playback and favorite holds. Tests replace it.
    @ObservationIgnored var now: () -> Date = { Date() }

    /// A play/pause request that comes less than this many seconds after the previous one is ignored:
    /// a double click, a bouncing key. Skipping tracks is never debounced.
    static let playPauseDebounce: TimeInterval = 0.4
    /// How many seconds after a play/pause request a snapshot that contradicts it is treated as stale.
    static let playbackHoldDuration: TimeInterval = 1.5
    /// How many seconds after a favorite request a snapshot that contradicts it is treated as stale.
    /// Music makes the change as a cloud edit that takes a few seconds to complete, and says "not favorited"
    /// until it has.
    static let favoriteHoldDuration: TimeInterval = 10

    /// A play/pause request the player hasn't confirmed yet.
    private struct PlaybackHold {
        /// The state the request asked for.
        var target: PlaybackState
        /// The track it was made on.
        var trackID: String
        /// When the request stops outranking snapshots.
        var until: Date
    }

    /// A favorite request the player hasn't confirmed yet.
    private struct FavoriteHold {
        /// The favorite state the request asked for.
        var target: Bool
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
        self.mediaKeysEnabled = defaults.object(forKey: SettingsKey.mediaKeysEnabled) as? Bool ?? false
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

    /// Favorites the track when the panel shows it as not a favorite and unfavorites it otherwise: like play/pause,
    /// what the user sees is what they react to, and the player is told exactly that (`setFavorited(true, …)` or
    /// `(false, …)`, never a toggle). The request carries the track that was on display at the click, so if Music
    /// has moved on by the time it arrives, the next song isn't favorited instead. The player recognises the track
    /// by its ID or, when Music has re-identified it, by its title and artist. The star changes at once and
    /// stays that way while Music catches up (see `reconcile(_:)`). A click while an earlier one is still on hold
    /// reads the star as it is displayed, so it undoes the first, and the hold follows it. The star isn't debounced.
    @discardableResult
    public func toggleFavorite() -> Task<Void, Never> {
        guard snapshot.availability == .running, let track = snapshot.track else { return Task {} }
        let favorited = !track.isFavorited
        mutateSnapshot { $0.track?.isFavorited = favorited }
        favoriteHold = FavoriteHold(
            target: favorited,
            trackID: track.id,
            until: now().addingTimeInterval(Self.favoriteHoldDuration)
        )
        if favorited {
            Self.log.info("favorite requested")
        } else {
            Self.log.info("unfavorite requested")
        }
        return Task { [player] in await player.setFavorited(favorited, track: track) }
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

    /// Shows the Accessibility prompt (or opens the right System Settings pane). Only ever the result of an explicit
    /// action of the user: turning media keys on, or choosing Allow Media Key Access… in the menu.
    public func requestMediaKeyAccess() {
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
    /// the request produced stay, and everything else (metadata, availability, the favorite flag unless that
    /// is on hold too) comes from the snapshot.
    ///
    /// A favorite request is held the same way, for much longer: Music makes the change as a cloud edit that
    /// takes a few seconds to complete, and answers "not favorited" until it has, to the read that follows the
    /// request and to every poll after it. While the request is on hold, a snapshot for the same track that
    /// contradicts it leaves the star as the request set it, and everything else comes from the snapshot.
    ///
    /// A hold ends when a snapshot confirms the request, when the track or the availability changes
    /// (whatever the user asked for no longer applies), and when its duration (`playbackHoldDuration`,
    /// `favoriteHoldDuration`) runs out (Music didn't do it, and the panel goes back to what Music says).
    /// A newer request replaces the hold of the same kind. The two kinds are independent: either can be
    /// active without the other, or both at once, and each only touches its own fields.
    private func reconcile(_ incoming: PlayerSnapshot) -> PlayerSnapshot {
        applyingFavoriteHold(to: applyingPlaybackHold(to: incoming))
    }

    /// The state, position and capture time of `incoming` while a play/pause request is on hold.
    private func applyingPlaybackHold(to incoming: PlayerSnapshot) -> PlayerSnapshot {
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

    /// The track's favorite flag in `incoming` while a favorite request is on hold.
    private func applyingFavoriteHold(to incoming: PlayerSnapshot) -> PlayerSnapshot {
        guard let hold = favoriteHold else { return incoming }
        guard now() < hold.until, incoming.availability == .running,
              let track = incoming.track, track.id == hold.trackID else {
            favoriteHold = nil
            return incoming
        }
        guard track.isFavorited != hold.target else {
            favoriteHold = nil
            return incoming
        }
        var held = incoming
        held.track?.isFavorited = hold.target
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
}

/// Decodes artwork off the main thread and shrinks oversized images to what the panel can show.
///
/// The bytes come from a track's own metadata, so they are untrusted: whatever isn't a readable bitmap image
/// (garbage, a PDF, a picture that claims a huge size) gives nil, and the panel shows its placeholder.
enum ArtworkDecoder {
    /// 272 pt at 2x, with a little headroom.
    static let maxPixelSize = 640
    /// The most pixels a source image may have along either side. A small file can declare a canvas of billions
    /// of pixels, which would expand into gigabytes when decoded.
    static let maxSourceDimension = 10_000

    static func decode(_ data: Data?) async -> NSImage? {
        guard let data, !data.isEmpty else { return nil }
        let cgImage = await Task.detached(priority: .userInitiated) { makeCGImage(from: data) }.value
        guard let cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    nonisolated static func makeCGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), isBitmapImage(source),
              isWithinSizeLimit(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// ImageIO also renders the first page of a PDF, and artwork is never a document: only image types pass.
    private nonisolated static func isBitmapImage(_ source: CGImageSource) -> Bool {
        guard let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String) else { return false }
        return type.conforms(to: .image)
    }

    /// Whether the size that ImageIO's `properties` for an image give, read from its header before any pixels
    /// are decoded, is within `maxSourceDimension` on both sides. Properties without a width and a height can't
    /// be checked, so they don't pass.
    nonisolated static func isWithinSizeLimit(_ properties: [CFString: Any]?) -> Bool {
        guard let properties,
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return width <= maxSourceDimension && height <= maxSourceDimension
    }
}
