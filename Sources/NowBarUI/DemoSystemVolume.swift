import Foundation
import NowBarCore

/// A stand-in for the Mac's output volume, used by `--demo` and the snapshot renderer.
/// It never touches the real system volume.
@MainActor
public final class DemoSystemVolume: SystemVolumeControlling {
    public var onChange: ((SystemVolume) -> Void)?
    public private(set) var current: SystemVolume

    public init(level: Float = 0.6, isMuted: Bool = false, isAdjustable: Bool = true) {
        current = SystemVolume(level: level, isMuted: isMuted, isAdjustable: isAdjustable)
    }

    public func start() {
        onChange?(current)
    }

    public func stop() {}

    public func setLevel(_ level: Float) {
        guard current.isAdjustable else { return }
        let clamped = min(max(level, 0), 1)
        current.level = clamped
        if clamped > 0 { current.isMuted = false }
        onChange?(current)
    }

    public func setMuted(_ muted: Bool) {
        guard current.isAdjustable else { return }
        current.isMuted = muted
        onChange?(current)
    }
}
