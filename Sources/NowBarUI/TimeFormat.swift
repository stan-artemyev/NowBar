import Foundation

/// Formats playback times the way the panel shows them: "3:37", "0:05", "1:02:03".
public enum TimeFormat {
    /// Whole seconds (fractions are dropped, not rounded) as `m:ss`, or `h:mm:ss` from one hour.
    /// Negative and non-finite values read as `0:00`.
    public static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(min(seconds, 359_999))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// Time left as `-m:ss`, measured from the whole second the elapsed label shows,
    /// so that elapsed and remaining always add up to the duration.
    public static func remaining(position: TimeInterval, duration: TimeInterval) -> String {
        let shown = position.isFinite ? max(0, position.rounded(.down)) : 0
        return "-" + clock(duration - shown)
    }
}
