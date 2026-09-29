import Foundation
import NowBarCore

/// What the query script returned, before it is interpreted. Everything is optional because Music leaves
/// properties out or refuses them for some kinds of track (a radio stream has no duration, for example).
struct MusicRawFields: Sendable, Equatable {
    /// `player state as text`: "playing", "paused", "stopped", "fast forwarding" or "rewinding".
    var state: String?
    /// Music's persistent ID.
    var trackID: String?
    var title: String?
    var artist: String?
    var album: String?
    var duration: Double?
    var position: Double?
    var isFavorited: Bool?

    init(
        state: String? = nil,
        trackID: String? = nil,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        duration: Double? = nil,
        position: Double? = nil,
        isFavorited: Bool? = nil
    ) {
        self.state = state
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.position = position
        self.isFavorited = isFavorited
    }

    /// Reads the list `nb_query` returns: {state, persistent ID, name, artist, album, duration, player
    /// position, favorited}. Returns nil when the script reported that Music isn't running (`missing value`)
    /// or returned anything that isn't a list.
    init?(_ value: ScriptValue) {
        guard case .list(let items) = value, !items.isEmpty else { return nil }
        func text(_ index: Int) -> String? {
            if index < items.count, case .text(let value) = items[index] { return value }
            return nil
        }
        func number(_ index: Int) -> Double? {
            if index < items.count, case .number(let value) = items[index] { return value }
            return nil
        }
        func flag(_ index: Int) -> Bool? {
            if index < items.count, case .bool(let value) = items[index] { return value }
            return nil
        }
        self.init(
            state: text(0),
            trackID: text(1),
            title: text(2),
            artist: text(3),
            album: text(4),
            duration: number(5),
            position: number(6),
            isFavorited: flag(7)
        )
    }
}

/// Turns raw Music readings into the `PlayerSnapshot` the rest of the app uses. Pure, so it is unit tested.
enum MusicSnapshotMapper {
    /// What Music said about the player, after normalising its text.
    enum ReportedState: Equatable {
        case playing
        case paused
        case stopped
        /// Text we don't know. Treated as paused when a track is loaded, so we never claim it's playing.
        case unrecognized
    }

    static func reportedState(_ text: String?) -> ReportedState {
        switch text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        // Fast forwarding and rewinding still mean audio is coming out and the position is moving.
        case "playing", "fast forwarding", "rewinding": return .playing
        case "paused": return .paused
        case "stopped": return .stopped
        default: return reportedState(fromEnumerationCode: text)
        }
    }

    /// `player state as text` gives the name of the state. Should it ever give the enumeration's code instead
    /// (as in "«constant ****kPSP»"), these are Music's codes. Case matters: kPSP is playing, kPSp is paused.
    private static func reportedState(fromEnumerationCode text: String?) -> ReportedState {
        guard let text else { return .unrecognized }
        let codes: [(String, ReportedState)] = [
            ("kPSP", .playing), ("kPSp", .paused), ("kPSS", .stopped), ("kPSF", .playing), ("kPSR", .playing),
        ]
        return codes.first { text.contains($0.0) }?.1 ?? .unrecognized
    }

    /// Stopped, or no current track, gives `.stopped` with a nil track. Missing text becomes "", a missing or
    /// negative duration or position becomes 0, and a missing favorite flag becomes false.
    static func snapshot(from raw: MusicRawFields, capturedAt: Date = Date()) -> PlayerSnapshot {
        let reported = reportedState(raw.state)
        guard reported != .stopped, let track = track(from: raw) else {
            return PlayerSnapshot(availability: .running, state: .stopped, track: nil, position: 0, capturedAt: capturedAt)
        }
        return PlayerSnapshot(
            availability: .running,
            state: reported == .playing ? .playing : .paused,
            track: track,
            position: seconds(raw.position),
            capturedAt: capturedAt
        )
    }

    /// nil when Music reported no track at all. A track without a persistent ID (unusual) still shows, with an
    /// ID built from its text so track changes are still noticed.
    static func track(from raw: MusicRawFields) -> Track? {
        let title = raw.title ?? ""
        let artist = raw.artist ?? ""
        let album = raw.album ?? ""
        let persistentID = raw.trackID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPersistentID = !(persistentID ?? "").isEmpty
        guard hasPersistentID || !title.isEmpty || !artist.isEmpty || !album.isEmpty else { return nil }
        return Track(
            id: hasPersistentID ? persistentID! : [title, artist, album].joined(separator: "\u{1F}"),
            title: title,
            artist: artist,
            album: album,
            duration: seconds(raw.duration),
            isFavorited: raw.isFavorited ?? false
        )
    }

    private static func seconds(_ value: Double?) -> TimeInterval {
        guard let value, value.isFinite, value > 0 else { return 0 }
        return value
    }
}
