import Foundation
import ServiceManagement

/// Reads and changes whether NowBar opens when the user logs in.
@MainActor
public protocol LaunchAtLoginControlling: AnyObject {
    var isEnabled: Bool { get }
    /// Throws when macOS refuses (for example when the app isn't running from a proper app bundle).
    func setEnabled(_ enabled: Bool) throws
}

/// Production implementation, backed by `SMAppService.mainApp`.
@MainActor
public final class MainAppLaunchAtLogin: LaunchAtLoginControlling {
    public init() {}

    public var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if service.status != .enabled { try service.register() }
        } else if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        }
    }
}
