import Foundation
import NowBarCore

/// A stand-in for Apple Music: a fictional playlist with generated artwork that plays, pauses,
/// seeks, skips and favorites. Used by `--demo` and by the snapshot renderer; it never touches Music.
@MainActor
public final class DemoPlayerController: PlayerController {
    /// The prototype's fictional playlist. Cover `n` is drawn for track `n`.
    public static let playlist: [Track] = [
        Track(id: "demo-midnight-circuit", title: "Midnight Circuit", artist: "Neon Harbor", album: "Afterglow City", duration: 217, isFavorited: false),
        Track(id: "demo-paper-satellites", title: "Paper Satellites", artist: "The Quiet Radios", album: "Low Orbit", duration: 252, isFavorited: false),
        Track(id: "demo-glasshouse", title: "Glasshouse", artist: "Mara Vey", album: "Soft Machines", duration: 185, isFavorited: false),
        Track(id: "demo-northbound", title: "Northbound", artist: "Lumen Drive", album: "Coastlines", duration: 301, isFavorited: false),
        Track(id: "demo-honey-and-static", title: "Honey & Static", artist: "Velvet Tides", album: "Honey & Static", duration: 168, isFavorited: false),
    ]

    public var onChange: ((PlayerSnapshot) -> Void)?

    private var availability: PlayerAvailability
    private var state: PlaybackState
    private var index: Int
    /// Playback position at `anchor`; while playing, the live position is this plus the time since `anchor`.
    private var basePosition: TimeInterval
    private var anchor: Date
    private var favorites: Set<String>
    /// Tracks outside the playlist (snapshot scenarios) and the cover they borrow.
    private var extraTrack: Track?
    private var extraTrackCover = 0
    private let simulatesPlayback: Bool
    private var ticker: Task<Void, Never>?
    private var artworkCache: [Int: Data] = [:]

    /// A live simulation: Music is running and playing the first track, 1:24 in.
    public init() {
        availability = .running
        state = .playing
        index = 0
        basePosition = 84
        anchor = Date()
        favorites = []
        simulatesPlayback = true
    }

    /// A frozen state for snapshots: nothing advances and no timer runs.
    /// `.notRunning` and `.notAuthorized` have no track; `state == .stopped` with `.running` is "nothing playing".
    public init(
        availability: PlayerAvailability,
        state: PlaybackState,
        trackIndex: Int = 0,
        position: TimeInterval = 84,
        isFavorited: Bool = false,
        capturedAt: Date = Date()
    ) {
        let count = Self.playlist.count
        let wrapped = ((trackIndex % count) + count) % count
        self.availability = availability
        self.state = state
        index = wrapped
        basePosition = position
        anchor = capturedAt
        favorites = isFavorited ? [Self.playlist[wrapped].id] : []
        simulatesPlayback = false
    }

    /// A frozen "running" state showing an arbitrary track (a long title, a live stream) with one of the covers.
    init(fixedTrack track: Track, cover: Int, state: PlaybackState, position: TimeInterval, capturedAt: Date) {
        availability = .running
        self.state = state
        index = 0
        basePosition = position
        anchor = capturedAt
        favorites = track.isFavorited ? [track.id] : []
        extraTrack = track
        extraTrackCover = cover
        simulatesPlayback = false
    }

    // MARK: PlayerController

    public func start() {
        emit()
        guard simulatesPlayback, ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.tick()
            }
        }
    }

    public func stop() {
        ticker?.cancel()
        ticker = nil
    }

    public func refresh() async -> PlayerSnapshot {
        makeSnapshot()
    }

    public func artwork(for track: Track) async -> Data? {
        guard let cover = coverIndex(for: track) else { return nil }
        if let cached = artworkCache[cover] { return cached }
        let data = DemoArtwork.pngData(forCover: cover)
        artworkCache[cover] = data
        return data
    }

    /// Idempotent: while already playing it changes nothing (but still reports, like the real controller).
    public func play() async {
        guard availability == .running else { return }
        let now = Date()
        switch state {
        case .playing:
            break
        case .paused:
            anchor = now
            state = .playing
        case .stopped:
            index = 0
            basePosition = 0
            anchor = now
            state = .playing
        }
        emit()
    }

    /// Idempotent: while paused (or stopped) it changes nothing (but still reports, like the real controller).
    public func pause() async {
        guard availability == .running else { return }
        if state == .playing {
            let now = Date()
            basePosition = position(at: now)
            anchor = now
            state = .paused
        }
        emit()
    }

    public func nextTrack() async {
        guard availability == .running, state != .stopped else { return }
        go(to: index + 1)
        emit()
    }

    public func previousTrack() async {
        guard availability == .running, state != .stopped else { return }
        // Like Music's "back track": restart the current track unless it has only just begun.
        if position(at: Date()) > 3 {
            basePosition = 0
            anchor = Date()
        } else {
            go(to: index - 1)
        }
        emit()
    }

    public func seek(to seconds: TimeInterval) async {
        guard availability == .running, let track = currentTrack else { return }
        basePosition = min(max(seconds, 0), track.duration)
        anchor = Date()
        emit()
    }

    public func setFavorited(_ favorited: Bool) async {
        guard availability == .running, let track = currentTrack else { return }
        if favorited { favorites.insert(track.id) } else { favorites.remove(track.id) }
        emit()
    }

    /// Pretends to launch the music app: it appears, paused on the first track.
    public func openApp() {
        if availability != .running {
            availability = .running
            state = .paused
            index = 0
            basePosition = 0
            anchor = Date()
        }
        emit()
    }

    // MARK: Simulation

    private var currentTrack: Track? {
        guard availability == .running, state != .stopped else { return nil }
        var track = extraTrack ?? Self.playlist[index]
        track.isFavorited = favorites.contains(track.id)
        return track
    }

    private func coverIndex(for track: Track) -> Int? {
        if track.id == extraTrack?.id { return extraTrackCover }
        return Self.playlist.firstIndex { $0.id == track.id }
    }

    private func position(at date: Date) -> TimeInterval {
        guard state == .playing, let duration = currentTrack?.duration else { return basePosition }
        return min(basePosition + max(0, date.timeIntervalSince(anchor)), duration)
    }

    private func go(to newIndex: Int) {
        let count = Self.playlist.count
        index = ((newIndex % count) + count) % count
        extraTrack = nil
        basePosition = 0
        anchor = Date()
    }

    private func tick() {
        guard state == .playing, let track = currentTrack else { return }
        if position(at: Date()) >= track.duration {
            go(to: index + 1)
            emit()
        }
    }

    private func makeSnapshot() -> PlayerSnapshot {
        switch availability {
        case .notRunning:
            return .notRunning
        case .notAuthorized:
            return .notAuthorized
        case .running:
            guard let track = currentTrack else {
                return PlayerSnapshot(availability: .running, state: .stopped, track: nil, position: 0)
            }
            return PlayerSnapshot(availability: .running, state: state, track: track, position: basePosition, capturedAt: anchor)
        }
    }

    private func emit() {
        onChange?(makeSnapshot())
    }
}
