import Foundation

/// The music app NowBar controls.
public enum MusicApp {
    public static let bundleIdentifier = "com.apple.Music"
    public static let displayName = "Apple Music"
}

/// Whether NowBar can talk to the music app right now.
public enum PlayerAvailability: Sendable, Equatable {
    /// The music app isn't running. NowBar never launches it on its own.
    case notRunning
    /// The music app is running and answering.
    case running
    /// The music app is running, but macOS denied NowBar permission to control it
    /// (System Settings → Privacy & Security → Automation).
    case notAuthorized
}

/// Playback state as reported by the music app.
public enum PlaybackState: String, Sendable, Equatable {
    case playing
    case paused
    case stopped
}

/// The track the music app is currently on.
public struct Track: Sendable, Equatable {
    /// Stable identifier (Music's persistent ID). Used to detect track changes and cache artwork.
    public var id: String
    public var title: String
    public var artist: String
    public var album: String
    /// Length in seconds; 0 when unknown (e.g. a radio stream).
    public var duration: TimeInterval
    public var isFavorited: Bool

    public init(id: String, title: String, artist: String, album: String, duration: TimeInterval, isFavorited: Bool) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.isFavorited = isFavorited
    }
}

/// A point-in-time reading of the player.
public struct PlayerSnapshot: Sendable, Equatable {
    public var availability: PlayerAvailability
    public var state: PlaybackState
    /// nil when nothing is loaded (stopped, not running or not authorized).
    public var track: Track?
    /// Playback position in seconds, measured at `capturedAt`.
    public var position: TimeInterval
    public var capturedAt: Date

    public init(availability: PlayerAvailability, state: PlaybackState, track: Track?, position: TimeInterval, capturedAt: Date = Date()) {
        self.availability = availability
        self.state = state
        self.track = track
        self.position = position
        self.capturedAt = capturedAt
    }

    public static let notRunning = PlayerSnapshot(availability: .notRunning, state: .stopped, track: nil, position: 0, capturedAt: .distantPast)
    public static let notAuthorized = PlayerSnapshot(availability: .notAuthorized, state: .stopped, track: nil, position: 0, capturedAt: .distantPast)

    /// Position extrapolated to `date`: advances while playing, clamped to the track's duration when known.
    public func position(at date: Date) -> TimeInterval {
        guard state == .playing else { return position }
        let advanced = position + max(0, date.timeIntervalSince(capturedAt))
        guard let duration = track?.duration, duration > 0 else { return advanced }
        return min(advanced, duration)
    }
}

/// Talks to the music app (Apple Music in production, a fake player in demo mode).
///
/// Implementations must never launch the music app, except from `openApp()`.
@MainActor
public protocol PlayerController: AnyObject {
    /// Pushes: called on the main actor when the player may have changed (track change, play/pause,
    /// app launched or quit) and after every action below completes.
    var onChange: ((PlayerSnapshot) -> Void)? { get set }

    /// Begins observing the music app and delivers an initial snapshot through `onChange`.
    func start()
    func stop()

    /// Pull: queries the app now and returns the result without calling `onChange`.
    /// Returns `.notRunning` without sending any Apple Event when the app isn't running.
    func refresh() async -> PlayerSnapshot

    /// Artwork image data (any format NSImage reads) for `track`, or nil when unavailable.
    func artwork(for track: Track) async -> Data?

    /// Starts or resumes playback. Idempotent: a repeat while already playing changes nothing.
    func play() async
    /// Pauses playback. Idempotent: a repeat while already paused changes nothing.
    func pause() async
    func nextTrack() async
    /// Restarts the current track, or goes to the previous one when near its start (Music's "back track").
    func previousTrack() async
    func seek(to seconds: TimeInterval) async
    func setFavorited(_ favorited: Bool) async

    /// Launches the music app if needed and brings it to the front. Only called from an explicit user action.
    func openApp()
}
