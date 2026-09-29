import Foundation

/// The Mac's output volume: the same one the keyboard volume and mute keys change.
public struct SystemVolume: Sendable, Equatable {
    /// 0...1
    public var level: Float
    public var isMuted: Bool
    /// False when the current output device has no adjustable volume (some HDMI or USB outputs).
    public var isAdjustable: Bool

    public init(level: Float, isMuted: Bool, isAdjustable: Bool) {
        self.level = level
        self.isMuted = isMuted
        self.isAdjustable = isAdjustable
    }

    public static let unavailable = SystemVolume(level: 0, isMuted: false, isAdjustable: false)
}

@MainActor
public protocol SystemVolumeControlling: AnyObject {
    /// Called on the main actor whenever the level, mute state or output device changes,
    /// including changes made with the keyboard volume keys or from Control Center.
    var onChange: ((SystemVolume) -> Void)? { get set }
    var current: SystemVolume { get }
    func start()
    func stop()
    /// Sets the level (clamped to 0...1). A level above 0 also unmutes.
    func setLevel(_ level: Float)
    func setMuted(_ muted: Bool)
}

/// The keyboard media keys NowBar can see.
public enum MediaKey: Sendable, Equatable, CaseIterable {
    case playPause
    case next
    case previous
    case mute
    case volumeUp
    case volumeDown
}

/// Intercepts the keyboard media keys system-wide. Needs Accessibility permission.
@MainActor
public protocol MediaKeyIntercepting: AnyObject {
    /// Called on the main thread once per physical key press (not for repeats or key-up).
    /// Return true to consume the press so macOS never sees it (its repeats and key-up are consumed too),
    /// or false to let macOS handle it as usual. Must return quickly; start slow work asynchronously.
    var handler: ((MediaKey) -> Bool)? { get set }
    /// Whether NowBar currently has Accessibility permission.
    var isTrusted: Bool { get }
    /// Called on the main actor when Accessibility permission is granted or revoked.
    var onTrustChange: ((Bool) -> Void)? { get set }
    /// When true, the event tap is installed as soon as permission allows; false removes it.
    var isEnabled: Bool { get set }
    /// Shows the system Accessibility prompt, or opens the right System Settings pane.
    func requestTrust()
}

/// Panel layouts the user can switch between.
public enum PanelLayout: String, Sendable, CaseIterable {
    case large
    case compact
}

/// UserDefaults keys shared by the UI and the app target.
public enum SettingsKey {
    /// `PanelLayout` raw value. Default: "large".
    public static let panelLayout = "panelLayout"
    /// Bool. Default: false (icon only).
    public static let showTitleInMenuBar = "showTitleInMenuBar"
    /// Bool. Default: true.
    public static let mediaKeysEnabled = "mediaKeysEnabled"
    /// Bool. Set once NowBar has asked for Accessibility permission, so it only prompts automatically once.
    public static let didRequestMediaKeyAccess = "didRequestMediaKeyAccess"
}
