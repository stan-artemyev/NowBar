import AppKit
import Foundation
import NowBarCore
import Observation
import os

/// The single source of truth for the panel and the menu bar label.
///
/// It owns the player, volume and media key services, mirrors their state, applies
/// optimistic updates for user actions (the controller's next `onChange` confirms them;
/// a play/pause or favorite request additionally outranks contradicting snapshots for a while, see `RequestHolds`)
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
    /// The play/pause and favorite requests the player hasn't caught up with yet.
    @ObservationIgnored private var holds = RequestHolds()

    /// Seconds between polls while the panel is visible. Tests shorten it.
    @ObservationIgnored var pollInterval: Duration = .seconds(2)
    /// Clock for optimistic updates, the play/pause debounce and the request holds. Tests replace it.
    @ObservationIgnored var now: () -> Date = { Date() }

    /// A play/pause request that comes less than this many seconds after the previous one is ignored:
    /// a double click, a bouncing key. Skipping tracks is never debounced.
    static let playPauseDebounce: TimeInterval = 0.4

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
            holds.holdPlayback(shouldPlay ? .playing : .paused, on: track, from: moment)
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
    /// has moved on by the time it arrives, the next song isn't favorited instead. The star changes at once and
    /// stays that way while Music catches up (see `RequestHolds`). A click while an earlier one is still on hold
    /// reads the star as it is displayed, so it undoes the first, and the hold follows it. The star isn't debounced.
    @discardableResult
    public func toggleFavorite() -> Task<Void, Never> {
        guard snapshot.availability == .running, let track = snapshot.track else { return Task {} }
        let favorited = !track.isFavorited
        mutateSnapshot { $0.track?.isFavorited = favorited }
        holds.holdFavorite(favorited, on: track, from: now())
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
        let new = holds.reconcile(incoming, displayed: snapshot, now: now())
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
