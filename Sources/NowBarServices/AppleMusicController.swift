import AppKit
import Foundation
import NowBarCore
import os

private let musicLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NowBar", category: "AppleMusic")

/// Controls Apple Music with AppleScript.
///
/// - Never launches Music (except `openApp()`): every script is skipped unless Music is already running, and
///   each script re-checks that itself.
/// - Every script runs on one private serial queue, never on the main thread. Results and `onChange` arrive
///   on the main actor.
/// - The first time NowBar talks to a running Music, macOS shows its one-time "NowBar wants to control Music"
///   prompt. Until it is answered only the script queue waits. A denial produces `.notAuthorized`, and every
///   later `refresh()` asks again, so turning access on in System Settings recovers without a restart.
@MainActor
public final class AppleMusicController: PlayerController {
    public var onChange: ((PlayerSnapshot) -> Void)?

    public init() {}

    // MARK: Private state

    private enum Permission {
        case unknown, granted, denied
    }

    private enum Readiness {
        case ready, notRunning, notAuthorized
    }

    private let runner = AppleScriptRunner()
    private var isStarted = false
    private var permission = Permission.unknown
    /// The last successful reading, shown again if Music fails to answer once (a timeout, say).
    private var lastReading: PlayerSnapshot?
    private var artworkCache = ArtworkCache(capacity: 8)
    /// Music isn't scriptable the instant it launches: no script is sent before this.
    private var scriptableAfter: ContinuousClock.Instant?
    private var debounceTask: Task<Void, Never>?
    private var playerInfoObserver: DistributedNotificationObserver?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lastLoggedError: Int?

    private static let playerInfoNotification = Notification.Name("com.apple.Music.playerInfo")
    private static let refreshDelay = Duration.milliseconds(150)
    /// How long Music gets to apply a transport command before it is read again. It acknowledges a command a
    /// moment before its player state changes, so an immediate read can still return the old state.
    private static let transportSettleTime = Duration.milliseconds(250)
    private static let launchSettleTime = Duration.seconds(1)

    // MARK: PlayerController

    public func start() {
        if !isStarted {
            isStarted = true
            installObservers()
        }
        scheduleRefresh(after: .zero)
    }

    public func stop() {
        isStarted = false
        debounceTask?.cancel()
        debounceTask = nil
        if let playerInfoObserver {
            DistributedNotificationCenter.default().removeObserver(playerInfoObserver)
        }
        playerInfoObserver = nil
        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers { center.removeObserver(token) }
        workspaceObservers = []
    }

    public func refresh() async -> PlayerSnapshot {
        switch await prepare() {
        case .notRunning: return .notRunning
        case .notAuthorized: return .notAuthorized
        case .ready: break
        }
        return interpret(await runner.call("nb_query", in: MusicScripts.query))
    }

    public func artwork(for track: Track) async -> Data? {
        if let cached = artworkCache.data(for: track.id) { return cached }
        guard await prepare() == .ready else { return nil }
        // The script only reads the artwork if the current track's persistent ID still equals `track.id`.
        let result = await runner.call("nb_artwork", in: MusicScripts.artwork, arguments: [.text(track.id)])
        if let error = result.error {
            noteFailure(error, while: "reading artwork")
            return nil
        }
        // No artwork is normal (streamed tracks often have none), and so is data that isn't an image.
        guard case .data(let bytes) = result.value, ArtworkImage.isDecodable(bytes) else { return nil }
        artworkCache.store(bytes, for: track.id)
        return bytes
    }

    /// Sends Music's `play`, not its `playpause` toggle, so a repeated or late command can't flip playback back.
    public func play() async {
        await send("nb_play", settle: Self.transportSettleTime)
    }

    /// Sends Music's `pause`; see `play()`.
    public func pause() async {
        await send("nb_pause", settle: Self.transportSettleTime)
    }

    public func nextTrack() async {
        await send("nb_next", settle: Self.transportSettleTime)
    }

    public func previousTrack() async {
        await send("nb_previous", settle: Self.transportSettleTime)
    }

    public func seek(to seconds: TimeInterval) async {
        guard seconds.isFinite else { return }
        await send("nb_seek", arguments: [.number(max(0, seconds))])
    }

    public func setFavorited(_ favorited: Bool) async {
        await send("nb_favorite", arguments: [.bool(favorited)])
    }

    public func openApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MusicApp.bundleIdentifier) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                musicLog.error("Could not open Music: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Actions

    /// Runs a control handler, then reads the player again and pushes the result through `onChange`.
    /// After a command that Music accepted, waits `settle` before that read, so it doesn't see the old state.
    private func send(_ handler: String, arguments: [ScriptArgument] = [], settle: Duration = .zero) async {
        if await prepare() == .ready {
            let result = await runner.call(handler, in: MusicScripts.control, arguments: arguments)
            if let error = result.error {
                noteFailure(error, while: handler)
            } else if settle > .zero {
                // A cancelled wait just ends early; the read below still happens.
                try? await Task.sleep(for: settle)
            }
        }
        onChange?(await refresh())
    }

    // MARK: Readiness

    /// Music must be running (checked before every script) and NowBar must be allowed to control it.
    private func prepare() async -> Readiness {
        guard Self.isMusicRunning() else {
            resetRunState()
            return .notRunning
        }
        await waitUntilScriptable()
        guard Self.isMusicRunning() else {
            resetRunState()
            return .notRunning
        }
        if permission == .granted { return .ready }

        // Asks macOS whether we may control Music, showing its prompt the first time. Blocks until the user
        // answers, so it runs on the script queue.
        let status = await runner.perform { Self.automationPermissionStatus(askUser: true) }
        guard Self.isMusicRunning() else {
            resetRunState()
            return .notRunning
        }
        switch status {
        case noErr:
            permission = .granted
            return .ready
        case AppleEventStatus.notPermitted, AppleEventStatus.wouldRequireUserConsent:
            permission = .denied
            return .notAuthorized
        case AppleEventStatus.targetNotRunning:
            resetRunState()
            return .notRunning
        default:
            // Unexpected: leave the decision to the script, and ask again next time.
            permission = .unknown
            return .ready
        }
    }

    private func waitUntilScriptable() async {
        guard let deadline = scriptableAfter else { return }
        if ContinuousClock.now < deadline {
            try? await Task.sleep(until: deadline, clock: .continuous)
        }
        if scriptableAfter == deadline { scriptableAfter = nil }
    }

    private func resetRunState() {
        permission = .unknown
        lastReading = nil
        scriptableAfter = nil
    }

    // MARK: Results

    private func interpret(_ result: ScriptResult) -> PlayerSnapshot {
        if let error = result.error {
            return snapshot(afterFailure: error)
        }
        guard Self.isMusicRunning() else {
            // Music quit while the script was in flight; don't report what it said.
            resetRunState()
            return .notRunning
        }
        guard let raw = MusicRawFields(result.value) else {
            // The script found Music not running, yet it is now: it is launching or quitting.
            return fallbackSnapshot()
        }
        lastLoggedError = nil
        let snapshot = MusicSnapshotMapper.snapshot(from: raw, capturedAt: result.finishedAt)
        lastReading = snapshot
        return snapshot
    }

    private func snapshot(afterFailure error: ScriptError) -> PlayerSnapshot {
        noteFailure(error, while: "reading the player")
        switch error.number {
        case Int(AppleEventStatus.notPermitted):
            permission = .denied
            lastReading = nil
            return .notAuthorized
        case Int(AppleEventStatus.targetNotRunning), Int(AppleEventStatus.connectionInvalid):
            guard Self.isMusicRunning() else {
                resetRunState()
                return .notRunning
            }
            return fallbackSnapshot()
        default:
            // A timeout or another hiccup: keep showing what we last knew rather than flashing "nothing playing".
            return fallbackSnapshot()
        }
    }

    private func fallbackSnapshot() -> PlayerSnapshot {
        lastReading ?? PlayerSnapshot(availability: .running, state: .stopped, track: nil, position: 0)
    }

    private func noteFailure(_ error: ScriptError, while activity: String) {
        // The same failure repeats on every refresh; log it once.
        guard lastLoggedError != error.number else { return }
        lastLoggedError = error.number
        musicLog.error("Music script failed while \(activity, privacy: .public): \(error.message, privacy: .public) (\(error.number))")
    }

    // MARK: Observers

    private func installObservers() {
        // Music posts this on every play, pause and track change. `.deliverImmediately` keeps it coming while
        // NowBar is in the background, which for a menu bar app is always.
        let observer = DistributedNotificationObserver { [weak self] in
            Task { @MainActor in self?.scheduleRefresh(after: Self.refreshDelay) }
        }
        DistributedNotificationCenter.default().addObserver(
            observer,
            selector: #selector(DistributedNotificationObserver.notified(_:)),
            name: Self.playerInfoNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        playerInfoObserver = observer

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard isMusicApplication(note) else { return }
                Task { @MainActor in self?.musicDidLaunch() }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard isMusicApplication(note) else { return }
                Task { @MainActor in self?.musicDidTerminate() }
            },
        ]
    }

    /// Coalesces bursts of notifications into one refresh. Only the wait is cancellable: once a refresh has
    /// started it always finishes and pushes.
    private func scheduleRefresh(after delay: Duration) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            self?.refreshAndPush()
        }
    }

    private func refreshAndPush() {
        guard isStarted else { return }
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.refresh()
            if self.isStarted { self.onChange?(snapshot) }
        }
    }

    private func musicDidLaunch() {
        // Give Music a moment to become scriptable, then check permission, read and push (see `prepare()`).
        resetRunState()
        scriptableAfter = .now + Self.launchSettleTime
        scheduleRefresh(after: .zero)
    }

    private func musicDidTerminate() {
        debounceTask?.cancel()
        debounceTask = nil
        resetRunState()
        if isStarted { onChange?(.notRunning) }
    }

    // MARK: Helpers

    private nonisolated static func isMusicRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: MusicApp.bundleIdentifier).contains { !$0.isTerminated }
    }

    /// `AEDeterminePermissionToAutomateTarget` for Music. With `askUser`, the first call shows the system prompt
    /// and blocks until it is answered; later calls return the saved decision immediately.
    private nonisolated static func automationPermissionStatus(askUser: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: MusicApp.bundleIdentifier)
        return withExtendedLifetime(target) {
            guard let address = target.aeDesc else { return AppleEventStatus.targetNotRunning }
            return AEDeterminePermissionToAutomateTarget(address, AEEventClass(typeWildCard), AEEventID(typeWildCard), askUser)
        }
    }
}

/// Apple event result codes this file reacts to.
private enum AppleEventStatus {
    /// errAEEventNotPermitted: the user (or MDM) denied NowBar control of Music.
    static let notPermitted: OSStatus = -1743
    /// errAEEventWouldRequireUserConsent: permission is still undecided and we didn't ask.
    static let wouldRequireUserConsent: OSStatus = -1744
    /// procNotFound: the target isn't running.
    static let targetNotRunning: OSStatus = -600
    /// The connection to a target that quit while a script was running.
    static let connectionInvalid: OSStatus = -609
}

private func isMusicApplication(_ notification: Notification) -> Bool {
    let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    return application?.bundleIdentifier == MusicApp.bundleIdentifier
}

/// Target for the distributed notification, whose observer API takes a selector.
private final class DistributedNotificationObserver: NSObject, @unchecked Sendable {
    private let action: @Sendable () -> Void

    init(action: @escaping @Sendable () -> Void) {
        self.action = action
    }

    @objc func notified(_ notification: Notification) {
        action()
    }
}
